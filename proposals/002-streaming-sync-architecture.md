# 002: Streaming Sync Architecture — Design Proposal

## Vision

Replace the current phase-based, batch-oriented sync with a **streaming pipeline** where resources flow continuously through direction-aware stages, with I/O overlapped at every stage.

**Target**: Sync 15,000 resources in under 3 seconds — in **either direction**:
- Empty local ← full remote (initial pull)
- Full local → empty remote (initial push, e.g., after Matrix import)

## Core Insight

The current architecture treats sync as a series of bulk operations separated by phase boundaries. But syncing a single resource is independent of syncing another (modulo shard metadata, which is a finalization concern). We can pipeline individual resources through the sync stages without waiting for all resources in a phase to complete.

Additionally, the current architecture conflates **discovery** (what exists where?) with **diffing** (what needs sync?). Separating these concerns — and persisting a minimal mirror of known remote state — enables truly incremental sync and cleaner architecture.

## Design Principles

1. **Stream across stages, batch within stages**: Resources flow continuously from stage to stage — no phase barriers that collect *all* items before the next stage begins. Within a single stage, I/O operations are batched for efficiency (e.g., a single DB query for all shard entries, commit transactions of 500–2000 resources, 10 concurrent downloads).
2. **Overlap I/O**: While one resource is being written to DB, the next is being downloaded, and another is being CRDT-merged
3. **Fast Paths for Common Cases**: Initial sync and no-conflict sync skip expensive merge logic
4. **Bytes When Possible**: Pass raw bytes through stages that don't need to inspect content
5. **Parallelize I/O**: Multiple concurrent reads/writes to remote storage
6. **Minimize Allocations**: Reduce intermediate RdfGraph objects and per-resource overhead
7. **Persist Remote Knowledge**: Store the minimal known remote state (resource IRI + clock hash per shard) so that subsequent syncs only process actual changes
8. **Separate Discovery from Diffing**: Remote discovery (what exists on the remote?) and local discovery (what exists locally?) are independent concerns that feed into a unified diff

## Architecture Overview

```
┌──────────────────────────────────────────────────────────────────────────┐
│                      Streaming Sync Pipeline                              │
│                                                                           │
│  ┌────────────┐   ┌─────────┐   ┌──────────┐   ┌──────────┐            │
│  │  Discovery  │──▶│  Merge  │──▶│  Commit  │──▶│ Finalize │            │
│  │  & Diff     │   │  Stage  │   │  Stage   │   │  Stage   │            │
│  │  Stage      │   │         │   │          │   │          │            │
│  └────────────┘   └─────────┘   └──────────┘   └──────────┘            │
│       │                │              │              │                    │
│   Remote discovery  CRDT merge     DB write +      Shard doc             │
│   + local lookup    per resource   remote upload   generation +          │
│   + diff/join       (fast path     (batched,       upload                │
│   + mirror update   for trivial    pipelined)                            │
│                     merges)                                               │
└──────────────────────────────────────────────────────────────────────────┘
```

## Remote Index Mirror

### Motivation

The current architecture downloads shard documents, parses entry metadata (resource IRIs, clock hashes), uses them for comparison — and then **discards** this information. Only the ETag is persisted. The ETag tells us *whether* a shard changed, but not *what* changed within it.

**Note**: The current ETag-based conditional download is correct and effective — unchanged shards return 304 Not Modified, avoiding redundant downloads and parsing. The mirror does not replace ETags; it complements them by persisting the *parsed content* of changed shards.

When a shard *has* changed (new ETag), the current code must:
1. Download and parse the full shard document
2. Compare every entry against local index entries
3. Determine which individual resources changed

With a remote index mirror, step 2 becomes a **two-level diff**:
1. **What changed remotely?** — Diff downloaded shard entries against the mirror (what we last saw)
2. **What needs CRDT merge?** — Diff mirror (updated) against local index entries

This separation is cleaner and enables future optimizations (e.g., backends that can report per-entry deltas).

### Data Model

Minimal mirror per remote, per shard:

```
remote_index_entries:
  ┌─────────────┬──────────────┬───────────┐
  │ resourceIri  │ shardIri     │ clockHash │
  ├─────────────┼──────────────┼───────────┤
  │ note:1       │ shard-0-of-4 │ abc123    │
  │ note:2       │ shard-1-of-4 │ def456    │
  └─────────────┴──────────────┴───────────┘
```

**What we store**: Only `(resourceIri, shardIri, clockHash)` — the minimum needed to know what exists remotely and at what CRDT version.

**What we don't store**: No document content, no header properties, no ETags (those live in the existing ETag table).

**Storage cost**: ~50 bytes per entry × 15,000 resources ≈ 750 KB — negligible.

### Crash Safety

The mirror is updated **atomically in the same DB transaction as the commit** (Stage 3). This guarantees:

- If the process crashes before commit: mirror still reflects the previous successful sync. Next sync re-downloads and re-processes the changed shard — identical to current behavior.
- If the process crashes after commit: mirror correctly reflects the committed state. Next sync sees the mirror matches remote (via ETag 304) — no redundant work.

The mirror is never ahead of the committed local state.

### Symmetry with Local Index Entries

The mirror creates a natural symmetry:

```
local_index_entries:     resourceIri + shardIri + clockHash  (existing)
remote_index_entries:    resourceIri + shardIri + clockHash  (new mirror)
```

The diff between these two tables directly produces `SyncCandidate` records — a pure set operation, no network required.

## Pipeline Stages

### Stage 1: Discovery & Diff

The Source stage is split into two parallel concerns — **Remote Discovery** (network) and **Local Discovery** (DB-only) — joined by a **Diff** step.

```
┌──────────────────────────────────────────────────────────────────┐
│                    Stage 1: Discovery & Diff                      │
│                                                                   │
│  ┌───────────────────┐      ┌───────────────────┐               │
│  │  Remote Discovery  │      │  Local Discovery   │              │
│  │                    │      │                    │               │
│  │ 1. Fetch index-of- │      │ 1. Query local     │              │
│  │    indices (with   │      │    index entries   │               │
│  │    ETag conditio-  │      │    from DB         │               │
│  │    nal download)   │      │ 2. Query remote    │               │
│  │ 2. Hierarchical    │      │    mirror table    │               │
│  │    stream unfold:  │      │                    │               │
│  │    Index → Shard   │      │                    │               │
│  │    docs            │      │                    │               │
│  │ 3. Parse entries   │      │                    │               │
│  │    from changed    │      │                    │               │
│  │    shards          │      │                    │               │
│  └────────┬───────────┘      └────────┬───────────┘              │
│           │                           │                           │
│           ▼                           ▼                           │
│  Stream<RemoteShardEntries>    LocalState snapshot                │
│           │                           │                           │
│           └───────────┬───────────────┘                           │
│                       ▼                                           │
│               ┌──────────────┐                                   │
│               │  Diff / Join │                                   │
│               └──────┬───────┘                                   │
│                      ▼                                           │
│            Stream<SyncCandidate>                                  │
│            (RemoteOnly | LocalOnly | Conflict)                   │
└──────────────────────────────────────────────────────────────────┘
```

**Output**: Stream of `SyncCandidate` records (sealed class with `RemoteOnlyCandidate`, `LocalOnlyCandidate`, `ConflictCandidate` subtypes — see 004 for exact types).

#### Remote Discovery (network, async)

Remote Discovery traverses the index hierarchy top-down, using **hierarchical stream unfolding** — each level's results trigger the next level, with no artificial phase barriers:

```
Fetch Index-of-Indices (FullIndex + GroupIndexTemplate)
  ├─ FullIndex doc ready  ──→ immediately fetch its shard docs
  ├─ GroupIndexTemplate ready ──→ fetch GroupIndex docs
  │   ├─ GroupIndex-A ready ──→ fetch its shard docs
  │   ├─ GroupIndex-B ready ──→ fetch its shard docs (parallel)
  │   └─ ...
  └─ FullIndex-2 ready ──→ fetch its shards (parallel with above)
```

This replaces the current rigid "sync ALL meta-types → then ALL GroupIndex docs → then ALL shards" phase boundaries. The causal dependencies are preserved (can't fetch shards before knowing the index), but there's no unnecessary waiting.

**ETag-conditional downloads**: All downloads use the existing ETag cache. Unchanged shards return 304 and are skipped — no parsing needed. Only changed shards produce new entry data.

For each **changed** shard document:
1. Parse entries (resource IRIs + clock hashes)
2. Yield as `RemoteShardEntries(shardIri, entries)`

For each **unchanged** shard (304):
- No entries yielded — the mirror already has the correct state from a previous sync

For each **missing** shard (404, empty remote):
- Yield `RemoteShardEmpty(shardIri)` — signals that the entire shard has no remote data

**Parallelism**: Multiple shards downloaded concurrently, bounded by `maxConcurrentDownloads`. The hierarchical unfolding means shard downloads can start as soon as their parent index is known, without waiting for sibling indices.

#### Local Discovery (DB-only, fast)

A single batch query produces the complete local picture:

1. **Local index entries**: `getActiveIndexEntriesForShards(allShardIris)` → `Map<shardIri, List<(resourceIri, clockHash)>>`
2. **Remote mirror entries**: `getRemoteIndexEntries(remoteId, allShardIris)` → `Map<shardIri, List<(resourceIri, clockHash)>>`

Both are pure DB reads, parallelizable, and fast (~ms for 15K entries).

**Bootstrapping**: For the very first sync (no mirror data yet), the remote mirror is empty. This is fine — every entry from Remote Discovery will be "new" in the diff, producing `RemoteOnlyCandidate` for all. The mirror builds up organically across syncs.

#### Diff / Join

The diff operates per-shard and produces sync candidates:

```dart
// For each shard where remote discovery yielded new entries:
for (final remoteEntry in remoteShardEntries) {
  final localEntry = localEntriesByResource[remoteEntry.resourceIri];
  final mirrorEntry = mirrorEntriesByResource[remoteEntry.resourceIri];

  if (localEntry == null) {
    yield RemoteOnlyCandidate(resourceIri: remoteEntry.resourceIri, ...);
  } else if (localEntry.clockHash != remoteEntry.clockHash) {
    yield ConflictCandidate(resourceIri: remoteEntry.resourceIri, ...);
  }
  // else: same clock hash → already in sync, skip
}

// Local entries with no remote counterpart → LocalOnlyCandidate
for (final localEntry in localShardEntries) {
  if (!remoteResourceIris.contains(localEntry.resourceIri)) {
    yield LocalOnlyCandidate(resourceIri: localEntry.resourceIri, ...);
  }
}
```

**For shards with 304 (unchanged remote)**: The mirror already matches remote, so we only need to check for local-only changes (resources added locally since last sync).

**For shards with 404 (empty remote)**: All local entries become `LocalOnlyCandidate` — no per-resource download needed.

**Deduplication**: A resource may appear in multiple shards (FullIndex + GroupIndex). First occurrence wins; subsequent appearances for the same `documentIri` are skipped.

### Stage 2: Merge (CRDT Merge with Fast Paths)

**Input**: Stream of `SyncCandidate` from Stage 1
**Output**: Stream of `MergedResource`

```dart
class MergedResource {
  final IriTerm documentIri;
  final IriTerm typeIri;
  final RdfGraph mergedGraph;
  final CurrentCrdtClock clock;
  final List<IriTerm> shardIris;
  final String? remoteEtag;
  final int? localUpdatedAt;
  final bool needsUpload;
}
```

**Fast Paths** (determined by `SyncCandidate` subtype from Stage 1):

```
┌─────────────────────────────────────────────────────────────┐
│                     Merge Decision Tree                      │
│                                                              │
│  RemoteOnlyCandidate? ──▶ Accept Remote (no merge needed)   │
│       │                   Skip: merge contract, shard recon  │
│      no                   Action: store to DB only           │
│       │                   needsUpload: false                 │
│       │                                                      │
│  LocalOnlyCandidate? ──▶ Keep Local (upload only)           │
│       │                  Skip: download, merge contract      │
│      no                  Action: upload + update ETags       │
│       │                  needsUpload: true                   │
│       │                                                      │
│  ConflictCandidate ──▶ Full CRDT merge                      │
│                        (only for actual divergence)          │
└─────────────────────────────────────────────────────────────┘
```

**Initial sync fast paths — both directions:**
- **Empty local** (pull): 100% of resources are `RemoteOnlyCandidate` — no merge contract loading, no shard reconciliation, just store to DB. Download of the full resource content (not just the shard entry) happens here.
- **Empty remote** (push): 100% of resources are `LocalOnlyCandidate` — no download from remote (Stage 1 already confirmed remote is empty via 404 shards), no merge contract loading, just upload + update ETags.

**For file-per-resource mode**: The Merge stage fetches the full resource content from remote (for `RemoteOnlyCandidate` and `ConflictCandidate`) or from local DB (for `LocalOnlyCandidate`). Multiple concurrent downloads are used.

**For dataset mode**: The full resource graph may already be attached to the `SyncCandidate` (extracted from the shard dataset in Stage 1), avoiding a per-resource download.

**Parallelism**: Multiple concurrent remote downloads for resources that need content. Merge computation itself is CPU-bound (single thread in Dart), but overlaps with I/O.

### Stage 3: Commit (Batched DB Write + Remote Upload + Mirror Update)

**Input**: Stream of `MergedResource`
**Output**: Stream of committed resources (for shard finalization)

**Behavior**:
- Collect merged resources into chunks (configurable, e.g. 500-2000)
- For each chunk, **direction-aware processing**:
- **Atomically** update local documents, index entries, ETags, **and remote index mirror** in a single DB transaction

**Empty local (pull) chunks** — `needsUpload: false`:
  1. Pre-encode documents (Jelly binary serialization)
  2. Commit to DB in transaction: save documents + save index entries + update ETags + **update remote mirror entries**
  3. Pipeline: encode chunk N+1 while committing chunk N

```
Time ─────────────────────────────────────────────────────▶

Chunk 1:  [encode]──[DB commit]
Chunk 2:           [encode]──[DB commit]
Chunk 3:                    [encode]──[DB commit]
```

**Empty remote (push) chunks** — `needsUpload: true`:
  1. Pre-encode documents for DB
  2. Upload to remote storage (parallel within chunk)
  3. Commit to DB in transaction: save documents + save index entries + set ETags + **update remote mirror entries**
  4. Pipeline: encode+upload chunk N+1 while committing chunk N

```
Time ─────────────────────────────────────────────────────▶

Chunk 1:  [encode]──[upload]──[DB commit]
Chunk 2:           [encode]──[upload]──[DB commit]
Chunk 3:                    [encode]──[upload]──[DB commit]
```

**Mixed chunks** (incremental sync): Upload only the subset with `needsUpload: true`, commit all.

**Key optimization**: For initial pull, eliminating the upload step saves ~5-8s (15K sequential file writes). For initial push, eliminating the download step saves ~3-5s (15K wasted 404s).

### Stage 4: Finalize (Shard Document Update)

**Input**: All committed resources (by shard)
**Output**: Updated shard documents uploaded to remote

**Behavior**:
- Wait for all resources in a shard to be committed
- Generate shard document from DB state (index entries already updated in Stage 3)
- Upload shard documents (parallel across shards)
- Commit shard metadata to DB

This is the only truly sequential dependency: shard documents can only be finalized after all their resources are committed. But this represents a tiny fraction of total work (a few shard docs vs. 15,000 resource docs).

## New Interfaces

### Remote Index Mirror (Storage Extension)

```dart
/// Extension to Storage for the remote index mirror.
///
/// Stores the minimal known remote state per shard: which resources
/// exist and at what clock hash. Updated atomically with the commit
/// to ensure crash safety.
abstract class RemoteIndexMirror {
  /// Get mirror entries for multiple shards in a single query.
  ///
  /// Returns: Map from shard IRI to list of (resourceIri, clockHash).
  Future<Map<IriTerm, List<RemoteMirrorEntry>>> getRemoteIndexEntries(
    RemoteId remoteId,
    Iterable<IriTerm> shardIris,
  );

  /// Bulk upsert mirror entries. Called within the commit transaction.
  Future<void> saveRemoteIndexEntries(
    RemoteId remoteId,
    List<SaveRemoteMirrorEntryRequest> entries,
  );

  /// Remove mirror entries for resources deleted from the remote.
  Future<void> deleteRemoteIndexEntries(
    RemoteId remoteId,
    List<({IriTerm resourceIri, IriTerm shardIri})> entries,
  );
}

class RemoteMirrorEntry {
  final IriTerm resourceIri;
  final IriTerm shardIri;
  final String clockHash;
}

class SaveRemoteMirrorEntryRequest {
  final IriTerm resourceIri;
  final IriTerm shardIri;
  final String clockHash;
}
```

### StreamingRemoteStorage

Extend the existing `RemoteSyncStorage` with streaming-aware operations:

```dart
/// Extension of RemoteSyncStorage for streaming operations
abstract class StreamingRemoteSyncStorage extends RemoteSyncStorage {
  /// Download multiple resources concurrently as a stream.
  ///
  /// Returns results as they complete (not in order).
  /// Respects maxConcurrentDownloads for backpressure.
  Stream<(RemoteDownloadRequest, RemoteDownloadResult<RdfGraph>)>
    downloadStream(Iterable<RemoteDownloadRequest> requests);

  /// Upload multiple resources concurrently as a stream.
  Stream<(RemoteUploadRequest<RdfGraph>, RemoteUploadResult)>
    uploadStream(Iterable<RemoteUploadRequest<RdfGraph>> requests);

  /// Maximum concurrent download operations
  int get maxConcurrentDownloads => 10;

  /// Maximum concurrent upload operations
  int get maxConcurrentUploads => 10;
}
```

### StreamingStorage (Local)

```dart
/// Extension for batch-optimized local storage writes
abstract class StreamingStorage extends Storage {
  /// Write a batch of documents with pre-encoded contents.
  ///
  /// Optimized for throughput: accepts pre-encoded bytes to allow
  /// encode-ahead pipelining.
  Future<void> saveBatch(SaveBatch batch);

  /// Get all index entries for multiple shards in a single query.
  /// (Already exists as getActiveIndexEntriesForShards, kept for clarity)
  Future<Map<IriTerm, List<IndexEntryWithIri>>>
    getActiveIndexEntriesForShards(Iterable<IriTerm> shardIris);
}

class SaveBatch {
  final List<SaveDocumentRequest> documents;
  final List<SaveIndexEntryRequest> indexEntries;
  final Map<IriTerm, String> etagUpdates;
  final List<Uint8List>? preEncodedContents;
}
```

### SyncPipeline (Orchestrator)

```dart
/// Main streaming sync pipeline
class SyncPipeline {
  final StreamingRemoteSyncStorage remote;
  final StreamingStorage local;
  final RemoteDocumentMerger merger;
  final MergeContractLoader mergeContractLoader;

  /// Execute streaming sync
  ///
  /// Note: No explicit "list of shards" input — the pipeline discovers
  /// what to sync by traversing the index hierarchy from the top.
  Future<SyncResult> sync(
    DateTime syncTime,
    int lastSyncTimestamp,
    RemoteId remoteId,
  ) async {
    // Stage 1: Discovery & Diff
    //   Remote: hierarchical index traversal (Index-of-Indices → Indices → Shards → Entries)
    //   Local: batch query of local index entries + remote mirror
    //   Diff: produces SyncCandidate stream
    final candidates = _discoveryAndDiffStage(lastSyncTimestamp, remoteId);

    // Stage 2: Merge (with fast paths)
    final merged = _mergeStage(candidates, lastSyncTimestamp);

    // Stage 3: Commit (batched, pipelined, mirror update)
    final committed = _commitStage(merged, syncTime, remoteId);

    // Stage 4: Finalize shards
    await _finalizeStage(committed, syncTime);
  }
}
```

## Fast Paths: Initial Sync (Both Directions)

### Fast Path A: Empty Local (Pull — Accept Remote)

For the common case of syncing to an empty local:

- Stage 1 (Discovery): Remote mirror is empty → every remote entry is "new" → 100% `RemoteOnlyCandidate`
- Stage 2 (Merge): Fast path for all — fetch full resource from remote, accept as-is, `needsUpload: false`
- Stage 3 (Commit): DB write only, no uploads. Mirror gets populated for the first time.

### Fast Path B: Empty Remote (Push — Keep Local)

For pushing local data to an empty remote (e.g., after Matrix import):

- Stage 1 (Discovery): All shard downloads return 404 → `RemoteShardEmpty` for every shard → all local entries become `LocalOnlyCandidate`
- Stage 2 (Merge): Fast path for all — read local doc from DB, `needsUpload: true`
- Stage 3 (Commit): Upload to remote + DB write. Mirror gets populated for the first time.

### Fast Path C: Incremental Sync (No Changes)

Most common steady-state case (nothing changed on either side):

- Stage 1 (Discovery): All shard ETags match → 304 for all → mirror unchanged → diff against local entries shows no differences → zero candidates emitted
- Stages 2-4: Not reached

### Fast Path D: Incremental Sync (Few Changes)

Typical case: 5 resources changed remotely, 3 locally:

- Stage 1 (Discovery): Most shards return 304. Changed shards are parsed. Mirror diff identifies exactly 5 changed remote entries. Local diff identifies 3 local-only changes. → 5 `ConflictCandidate` + 3 `LocalOnlyCandidate` emitted.
- Stage 2 (Merge): 5 full CRDT merges + 3 fast-path local-only
- Stage 3 (Commit): 8 resources committed (5 with upload, 3 without)

```dart
Stream<MergedResource> _mergeStage(
  Stream<SyncCandidate> candidates,
  int lastSyncTimestamp,
) async* {
  await for (final candidate in candidates) {
    switch (candidate) {
      case RemoteOnlyCandidate():
        // FAST PATH: No local state, accept remote directly
        // No merge contract loading, no shard reconciliation needed
        final remoteGraph = candidate.remoteGraph
          ?? await _fetchRemoteGraph(candidate.documentIri);

        final typeIri = _extractTypeIri(remoteGraph, candidate.documentIri);
        final clock = _hlcService.getCurrentClock(remoteGraph, candidate.documentIri);
        final shards = await _shardDeterminer.determineShards(
          typeIri, candidate.resourceIri, remoteGraph,
          mode: ShardDeterminationMode.strict,
        );

        yield MergedResource(
          documentIri: candidate.documentIri,
          typeIri: typeIri,
          mergedGraph: remoteGraph,
          clock: clock,
          shardIris: shards.shards,
          remoteEtag: candidate.remoteEtag,
          localUpdatedAt: null,
          needsUpload: false,  // Remote already has it
        );

      case LocalOnlyCandidate():
        // FAST PATH: No remote state, keep local and upload
        // No download needed (Source stage already confirmed remote is empty)
        // No merge contract loading needed
        final localDoc = await _storage.getDocument(candidate.documentIri);
        if (localDoc == null) continue;

        final typeIri = _extractTypeIri(localDoc, candidate.documentIri);
        final clock = _hlcService.getCurrentClock(localDoc, candidate.documentIri);
        // Shard assignments already known from index entries
        final shards = candidate.knownShardIris
          ?? (await _shardDeterminer.determineShards(
               typeIri, candidate.resourceIri, localDoc,
               mode: ShardDeterminationMode.strict,
             )).shards;

        yield MergedResource(
          documentIri: candidate.documentIri,
          typeIri: typeIri,
          mergedGraph: localDoc,
          clock: clock,
          shardIris: shards,
          remoteEtag: null,  // Nothing on remote
          localUpdatedAt: null,
          needsUpload: true,  // Must push to remote
        );

      case ConflictCandidate():
        // SLOW PATH: Full CRDT merge (actual conflict)
        yield await _fullMerge(candidate);
    }
  }
}
```

## Backpressure and Flow Control

The pipeline uses Dart's Stream mechanics for natural backpressure:

```
Source ──── merge buffer (bounded) ──── Merge ──── commit buffer ──── Commit
  │                                       │                            │
  ├─ pauses when merge buffer full       ├─ pauses when commit        ├─ processes chunks
  │                                      │  buffer full                │  of 500-2000
  └─ resumes when space available        └─ resumes when drained      └─ pipelining
```

If the DB write is the bottleneck, the merge stage naturally slows down, which back-pressures the source stage, preventing memory from growing unboundedly.

## Concurrency Model

Dart is single-threaded but async. We use async concurrency (overlapped I/O) rather than true parallelism:

```dart
/// Download N files concurrently
Stream<RemoteDownloadResult<RdfGraph>> _concurrentDownload(
  Iterable<RemoteDownloadRequest> requests,
  {int concurrency = 10}
) async* {
  final pending = <Future<RemoteDownloadResult<RdfGraph>>>[];
  final iterator = requests.iterator;

  // Fill initial window
  while (pending.length < concurrency && iterator.moveNext()) {
    pending.add(remote.download(iterator.current.documentIri,
      ifNoneMatch: iterator.current.ifNoneMatch));
  }

  // Process results, refill window
  while (pending.isNotEmpty) {
    final result = await Future.any(pending);
    yield result;
    pending.remove(result); // simplified
    if (iterator.moveNext()) {
      pending.add(remote.download(iterator.current.documentIri,
        ifNoneMatch: iterator.current.ifNoneMatch));
    }
  }
}
```

## Expected Performance Improvement

### Current (Sequential) — Both Directions
```
Empty local:  15,000 × (download + decode + merge + encode + upload + DB) = ~18s
Empty remote: 15,000 × (download-404 + load-local + merge-noop + encode + upload + DB) = ~18s
```

### Streaming Pipeline — Empty Local (Pull)
```
Source:  15,000 downloads @ 10 concurrent = ~1.5s (I/O bound)
Merge:  15,000 fast-path accepts = ~0.3s (CPU bound, overlapped with I/O)
Commit: 15,000 DB inserts @ 2000/batch = ~1.5s (pipelined with encode)
Upload: SKIPPED (needsUpload: false — remote already has data)
Finalize: ~4 shard docs = ~0.1s

Effective time (pipelined): ~2-3s
```

### Streaming Pipeline — Empty Remote (Push)
```
Source:  Shard doc downloads (all 404) = ~0.1s
         + emit 15K LocalOnlyCandidates from local index
Merge:  15,000 local reads from DB @ batch = ~0.5s
         No downloads, no merge contracts
Commit: Upload 15K @ 10 concurrent = ~1.5s (pipelined)
         + DB update 15K @ 2000/batch = ~1.5s (pipelined with upload)
Finalize: ~4 shard docs = ~0.1s

Effective time (pipelined): ~2-3s
```

Key improvements:
- **10× I/O speedup** from concurrent file operations
- **Near-zero merge time** from fast path (initial sync, either direction)
- **Eliminated wasted I/O**: No 15K redundant 404s (push) or redundant uploads (pull)
- **50% commit speedup** from encode/commit pipelining
- **I/O/CPU overlap** from streaming architecture

## Migration Strategy

The streaming pipeline should be implemented as an **alternative sync function**, not a replacement:

1. Create `StreamingSyncFunction` alongside existing `SyncFunction`
2. Both implement the same public interface (`Future<void> call(DateTime syncTime)`)
3. Configuration flag to choose between them
4. Run both in tests, compare results for correctness verification
5. Gradually migrate as streaming version proves stable

The remote index mirror can be introduced incrementally:
- First: populate mirror during existing sync (write-only, unused for reads)
- Verify mirror consistency by comparing mirror state with actual remote shard contents
- Then: switch to mirror-based diffing in the streaming pipeline

## Comparison with Current Architecture

| Aspect | Current (Three-Phase) | Streaming Pipeline |
|--------|----------------------|-------------------|
| **Discovery** | Rigid phases: meta-types → GroupIndex docs → shards | Hierarchical stream unfolding: each level triggers the next |
| **Diffing** | Compare remote shard entries vs. local index entries, discard remote entries after | Persist remote entries in mirror; diff is a DB-only set operation |
| **ETag handling** | Correct: conditional downloads, 304 for unchanged | Same — unchanged. ETags still used for conditional downloads |
| **Shard doc download** | Download → parse → extract entries → compare → **discard entries** | Download → parse → extract entries → compare → **persist in mirror** |
| **Phase boundaries** | Strict: download ALL → merge ALL → upload ALL | Streaming: download-merge-commit per resource, pipelined |
| **Empty-remote detection** | Phase 1 sees shard 404, but Phase 2 still calls download per resource | Shard 404 → `RemoteShardEmpty` → all local entries become `LocalOnlyCandidate` — zero per-resource downloads |
| **Crash safety** | ETags + index entries consistent after commit | Same + mirror consistent after commit |
| **Incremental sync (no changes)** | Download all shard docs (304s) + compare | Same (304s), but **mirror already has complete remote state** for any future DB-only diff needs |

## Risks and Mitigations

| Risk | Mitigation |
|------|-----------|
| Streaming complexity | Start with simple async generators, not complex stream transformers |
| Backpressure bugs | Use bounded buffers with explicit capacity |
| Partial failure | Each batch commit is atomic; failed resources retry in next sync |
| Shard consistency | Shard finalization waits for all resources, same as current |
| Test coverage | Run both old and new sync, diff results |
| Concurrency bugs | All I/O concurrency is within single isolate (no shared state) |
| Mirror inconsistency | Mirror updated atomically in commit transaction; on crash, mirror = last successful state |
| Mirror bootstrapping | First sync without mirror = current behavior (all entries are "new"). Mirror builds up organically |
| Hierarchical stream complexity | Implement as sequential fallback first, then optimize to hierarchical unfolding |
