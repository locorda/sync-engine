# 002: Streaming Sync Architecture — Design Proposal

## Vision

Replace the current phase-based, batch-oriented sync with a **streaming pipeline** where resources flow continuously through direction-aware stages, with I/O overlapped at every stage.

**Target**: Sync 15,000 resources in under 3 seconds — in **either direction**:
- Empty local ← full remote (initial pull)
- Full local → empty remote (initial push, e.g., after Matrix import)

## Core Insight

The current architecture treats sync as a series of bulk operations separated by phase boundaries. But syncing a single resource is independent of syncing another (modulo shard metadata, which is a finalization concern). We can pipeline individual resources through the sync stages without waiting for all resources in a phase to complete.

## Design Principles

1. **Stream, Don't Batch**: Resources flow through the pipeline as a continuous stream, not as collected batches
2. **Overlap I/O**: While one resource is being written to DB, the next is being downloaded, and another is being CRDT-merged
3. **Fast Paths for Common Cases**: Initial sync and no-conflict sync skip expensive merge logic
4. **Bytes When Possible**: Pass raw bytes through stages that don't need to inspect content
5. **Parallelize I/O**: Multiple concurrent reads/writes to remote storage
6. **Minimize Allocations**: Reduce intermediate RdfGraph objects and per-resource overhead

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                      Streaming Sync Pipeline                         │
│                                                                      │
│  ┌──────────┐   ┌──────────┐   ┌──────────┐   ┌──────────┐        │
│  │  Source   │──▶│  Merge   │──▶│  Commit  │──▶│ Finalize │        │
│  │  Stage    │   │  Stage   │   │  Stage   │   │  Stage   │        │
│  └──────────┘   └──────────┘   └──────────┘   └──────────┘        │
│       │              │              │              │                 │
│   Download       CRDT merge     DB write +      Shard doc          │
│   shard docs     per resource   remote upload   generation +       │
│   + extract      (fast path     (batched,       upload             │
│   entries        for trivial    pipelined)                         │
│                  merges)                                            │
└─────────────────────────────────────────────────────────────────────┘
```

## Pipeline Stages

### Stage 1: Source (Shard Download + Entry Extraction)

**Input**: List of shards to sync
**Output**: Stream of `SyncCandidate` records

```dart
/// A single resource that needs syncing
class SyncCandidate {
  final IriTerm documentIri;
  final IriTerm resourceIri;
  final String? remoteClockHash;
  final String? localClockHash;

  /// Raw remote content — either extracted from dataset or to be fetched
  final RdfGraph? remoteGraph;  // non-null if from dataset mode
  final String? remoteEtag;
}
```

**Behavior**:
- Download shard documents (parallel across shards)
- Extract entries from each shard
- Compare clock hashes with local index entries (pre-fetched in batch)
- Emit only entries that need sync (different clock hashes or missing on one side)
- **Propagate shard-level knowledge**: If a shard document is 404 (empty remote), mark all local resources in that shard as `LocalOnlyCandidate` — no per-resource download needed
- **Propagate shard-level knowledge**: If a shard has remote entries but no local entries, mark all remote resources as `RemoteOnlyCandidate`
- For dataset mode: extract and attach individual resource graphs from dataset
- For file-per-resource mode: emit candidate without remote graph (fetched in merge stage)

**Parallelism**: Multiple shards downloaded concurrently.

### Stage 2: Merge (CRDT Merge with Fast Paths)

**Input**: Stream of `SyncCandidate`
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
}
```

**Fast Paths**:

```
┌─────────────────────────────────────────────────────────────┐
│                     Merge Decision Tree                      │
│                                                              │
│  Is local null? ──yes──▶ Accept Remote (no merge needed)    │
│       │                  Skip: download, merge contract,     │
│      no                  shard reconciliation                │
│       │                  Action: store to DB only             │
│       │                                                      │
│  Is remote null? ──yes──▶ Keep Local (upload only)          │
│       │                   Skip: download, merge contract,    │
│      no                   shard reconciliation               │
│       │                   Action: upload + update ETags only  │
│       │                                                      │
│  Same clock hash? ──yes──▶ Skip (already in sync)           │
│       │                                                      │
│      no                                                      │
│       │                                                      │
│  Full CRDT merge (only reached for actual conflicts)         │
└─────────────────────────────────────────────────────────────┘
```

**Initial sync fast paths — both directions:**
- **Empty local** (pull): 100% of resources take the "Accept Remote" fast path — skip download-to-remote (already has it), skip merge, just store to DB
- **Empty remote** (push): 100% of resources take the "Keep Local" fast path — skip download-from-remote (guaranteed 404), skip merge contract loading, just upload + update ETags

**Critical optimization for empty remote**: The Source stage already knows the remote is empty from shard document 404s. It emits `LocalOnlyCandidate` records, and the Merge stage **skips the download entirely** — no 15K wasted 404 requests.

**Parallelism**: For file-per-resource mode, multiple concurrent downloads/uploads while merge processes received resources. Merge computation itself is CPU-bound (single thread in Dart).

### Stage 3: Commit (Batched DB Write + Remote Upload)

**Input**: Stream of `MergedResource`
**Output**: Stream of committed resources (for shard finalization)

**Behavior**:
- Collect merged resources into chunks (configurable, e.g. 500-2000)
- For each chunk, **direction-aware processing**:

**Empty local (pull) chunks** — `needsUpload: false`:
  1. Pre-encode documents (Jelly binary serialization)
  2. Commit to DB in transaction — **no upload needed** (remote already has the data)
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
  3. Commit to DB in transaction (saveDocuments + saveIndexEntries + setRemoteETags)
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

  /// Execute streaming sync for given shard specs
  Future<SyncResult> sync(
    List<ShardSyncSpec> shards,
    DateTime syncTime,
    int lastSyncTimestamp,
  ) async {
    // Stage 1: Download shards, extract candidates
    final candidates = _sourceStage(shards, lastSyncTimestamp);

    // Stage 2: Merge (with fast paths)
    final merged = _mergeStage(candidates, lastSyncTimestamp);

    // Stage 3: Commit (batched, pipelined)
    final committed = _commitStage(merged, syncTime);

    // Stage 4: Finalize shards
    await _finalizeStage(committed, syncTime);
  }
}
```

## Fast Paths: Initial Sync (Both Directions)

### Fast Path A: Empty Local (Accept Remote)

For the common case of syncing to an empty local:

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
        // No download needed (remote is empty/404)
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
        if (candidate.localClockHash == candidate.remoteClockHash) {
          // Already in sync, skip
          continue;
        }
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

## Risks and Mitigations

| Risk | Mitigation |
|------|-----------|
| Streaming complexity | Start with simple async generators, not complex stream transformers |
| Backpressure bugs | Use bounded buffers with explicit capacity |
| Partial failure | Each batch commit is atomic; failed resources retry in next sync |
| Shard consistency | Shard finalization waits for all resources, same as current |
| Test coverage | Run both old and new sync, diff results |
| Concurrency bugs | All I/O concurrency is within single isolate (no shared state) |
