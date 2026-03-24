# 002: Streaming Sync Architecture — Design Proposal

## Vision

Replace the current phase-based, batch-oriented sync with a **pure stream-composition pipeline** where data flows through composed stream transforms, with I/O overlapped naturally across stages.

**Target**: Sync 15,000 resources in under 3 seconds — in **either direction**:
- Empty local ← full remote (initial pull)
- Full local → empty remote (initial push, e.g., after Matrix import)

## Core Insight

Syncing a single resource is independent of syncing another (modulo shard metadata, which is a finalization concern). We can pipeline resources through sync stages without waiting for all resources to complete a phase. The pipeline is a **composition of stream transforms** — no external coordinator, no phase barriers.

The backend is a stream transform, not a service the pipeline calls into. The pipeline never sees `GraphSyncStorage` — it works with typed events that flow through composed transforms. Each backend implementation translates between its storage format and the pipeline's event types internally.

## Design Principles

1. **Stream across stages, batch within stages**: Resources flow continuously from stage to stage — no phase barriers that collect *all* items before the next stage begins. Within a single stage, I/O operations are batched for efficiency (e.g., a single DB query for all shard entries, commit transactions of 500–2000 resources, 10 concurrent downloads).
2. **Backend as stream transform**: The backend is a function `Stream<Request> → Stream<Result>` — not a service the pipeline calls. All backend-specific complexity (file-per-resource vs. file-per-shard vs. aggregated storage) is encapsulated inside the transform.
3. **Boundary elements for coordination**: Typed sentinel events (`ShardComplete`, `LevelComplete`) flow inline with data, enabling downstream stages to detect level transitions and trigger aggregation — no external coordinator needed.
4. **CPU work stays in CPU stages; I/O stages only do I/O**: No parsing or encoding in I/O stages. I/O stages pass `EncodedRdfGraphSource` (raw bytes/text) through without transformation. All decoding and encoding happens in the Merge stage (CPU-bound). Merge decodes where needed (metadata extraction, CRDT merge) and ensures data is available in the DB's storage format (typically Jelly) so Commit can write raw bytes without CPU work. Backends that need CPU-intensive format transformation (e.g., aggregate-file backends parsing/rebuilding TriG) compose their own internal sub-stages to keep CPU and I/O separated.
5. **Only sync what changed**: Both remote and local changes are gated by "has changed" checks — ETags for remote, `updatedAt > lastSyncTimestamp` for local. Unchanged items are never processed.
6. **Fast paths for common cases**: Initial sync and no-conflict sync skip expensive merge logic. **Important**: Fast paths must not change sync semantics — they optimize *execution*, not *protocol*. Existing behaviors like adding the current installation to the readers list of a remote-only shard (triggering a remote update of that shard) must be preserved. Protocol optimizations that reduce unnecessary remote writes are a separate future concern.
7. **Backend persists its own remote knowledge**: Each backend maintains its own view of the remote state, tailored to its sync strategy (file-per-resource, file-per-shard-dataset, single-file). What the backend needs to store varies — from minimal index metadata to full resource content. Core provides convenience services and a transactional callback mechanism but never accesses mirror data directly.

## Pipeline Trigger

The pipeline is triggered by the sync manager (manual, timer, or reconnect). Two values seed it:

- **`lastSyncTimestamp`**: Read from DB — the timestamp of the last successful sync completion. Passed to the Diff stage for identifying locally-changed items (`updatedAt > lastSyncTimestamp`).
- **Entry point**: The Index-of-Indices (IoI) IRI per remote backend. Discovery uses this as the root for hierarchy traversal, combining it with locally-known indices from the DB.

## Architecture Overview

```
┌───────────────────────────────────────────────────────────────────────────────────────────┐ 
│                        Pure Stream-Composition Pipeline                                   │
│                                                                                           │
│  Hierarchical  Diff          Resource    CRDT        Upload        DB          Shard      │
│  Discovery ──▶ Transform ──▶ Fetch ────▶ Merge  ───▶ Transform ──▶ Commit ───▶ Finalize   │
│  (recursive    (DB + mirror  (batched    (pure CPU,  (Remote       (atomic     (boundary- │
│   4-level       lookup,       I/O via     decode +    I/O only      DB write    triggered │
│   traversal,    remaining-    backend     encode to   uploads       + backend   IoI + data│
│   ETag-gated)   items query)  transform)  DB format)  for push)     callback)   shard     │
│                                                                                 upload)   │
│                                                                                           │
│  Boundaries:  ──────── flow inline with data ──────────────────────────▶                  │
│  ShardComplete, LevelComplete                                                             │
└───────────────────────────────────────────────────────────────────────────────────────────┘
```

### I/O Type Breakdown per Stage

| Stage | DB I/O | Remote I/O | CPU | Notes |
|-------|--------|------------|-----|-------|
| 1. Hierarchical Discovery | ETag reads (all levels); `index_shards` queries (304 cases); GroupIndex subscription queries | Conditional GETs: IoI, IoI-Shards, Index docs, Data Shards | Shard entry parsing; index doc parsing (200 only) | 4-level hierarchy + GroupIndex subscription path; emits hierarchy docs + shard entries |
| 2. Diff Transform | Local index reads, mirror reads (via backend) | — | Hash comparison | Handles hierarchy docs (IoI, Index) and shard entries (resources) |
| 3. Resource Fetch | Content reads (LocalOnly) | Content downloads (RemoteOnly, Conflict) | — | Backend as stream transform |
| 4. CRDT Merge | — | — | Decode, CRDT merge, encode to DB format | **Pure CPU — no I/O** |
| 5. Upload Transform | — | HTTP uploads (needsUpload) | — | **Pure Remote I/O** |
| 6. DB Commit | Atomic write: docs + index + ETags; Backend mirror callback | — | — | **Pure DB I/O** |
| 7. Shard Finalize | Shard doc reads | Shard uploads | Shard doc generation | Aggregates per shard (both IoI-Shards and Data Shards) |

**Key separation**: Stages 4, 5, 6 form a strict CPU → Remote I/O → DB I/O pipeline. This enables natural stream pipelining: while batch N's DB commit runs, batch N+1's uploads run concurrently, and batch N+2 is being merged.

No orchestrator class — the pipeline is the composition of these transforms:

```dart
final pipeline = hierarchicalDiscovery(        // Stream<DiscoveryEvent>
        backend, db)
    .transform(diffTransform(                  // Stream<DiffEvent>
        db, backend, lastSyncTimestamp))
    .transform(fetchTransform(backend))        // Stream<FetchEvent>
    .transform(mergeTransform(merger))         // Stream<MergeEvent>
    .transform(uploadTransform(backend))       // Stream<UploadEvent>
    .transform(dbCommitTransform(db, backend)) // Stream<CommitEvent>
    .transform(finalizeTransform(backend));    // Stream<FinalizeEvent>
```

## Boundary Elements (Punctuation Pattern)

Boundaries are typed inline sentinel events that signal structural transitions in the stream. Inspired by the "punctuation" pattern from stream processing (cf. Apache Flink watermarks).

### Shared Boundary Types

```dart
/// Structural markers that flow inline with data events.
/// Each stage wraps these in its own event type for type safety.
sealed class Boundary {
  const Boundary();
}

/// All resources in this shard have been emitted.
class ShardComplete extends Boundary {
  final IriTerm shardIri;
  const ShardComplete(this.shardIri);
}

/// All shards at this hierarchy level have been emitted.
class LevelComplete extends Boundary {
  final HierarchyLevel level;
  const LevelComplete(this.level);
}
```

### Per-Stage Event Types

Each stage defines its own event sealed class that embeds the shared `Boundary`:

```dart
// Discovery stage events — two kinds of discovered items
sealed class DiscoveryEvent {
  const DiscoveryEvent();
}

/// A hierarchy document (IoI, Index) downloaded via conditional GET.
/// Flows through Diff → Fetch → Merge → Upload → Commit as a sync candidate.
class DiscoveredDocument extends DiscoveryEvent {
  final IriTerm documentIri;
  final EncodedRdfGraphSource? remoteSource; // null if 304
  final HierarchyDocumentType type; // ioI, fullIndex, groupIndex
  // ...
}

/// Entries from a shard document (IoI-Shard or Data Shard).
/// Each entry has (childIri, clockHash) for fine-grained change detection.
class DiscoveredShardEntries extends DiscoveryEvent {
  final IriTerm shardIri;
  final List<RemoteShardEntry> entries;
  final String etag;
  // ...
}

/// Shard returned 304 — mirror has correct entries.
class ShardUnchanged extends DiscoveryEvent {
  final IriTerm shardIri;
  const ShardUnchanged(this.shardIri);
}

/// Shard or hierarchy document returned 404.
class DiscoveredEmpty extends DiscoveryEvent {
  final IriTerm iri;
  const DiscoveredEmpty(this.iri);
}

class DiscoveryBoundary extends DiscoveryEvent {
  final Boundary boundary;
  const DiscoveryBoundary(this.boundary);
}

// Example: Diff stage events
sealed class DiffEvent {
  const DiffEvent();
}
class SyncCandidateEvent extends DiffEvent {
  final SyncCandidate candidate;
  // ...
}
class DiffBoundary extends DiffEvent {
  final Boundary boundary;
  const DiffBoundary(this.boundary);
}
```

The `Boundary` object itself is reused (same instance forwarded between stages), but each stage wraps it in its own event type. This ensures type safety — a `DiscoveryEvent` cannot be accidentally inserted into a `Stream<DiffEvent>`.

### What Boundaries Enable

- **Diff Transform**: At `ShardComplete` → query local DB for items in this shard that changed since last sync but weren't seen in the remote stream → emit `LocalOnlyCandidate`s. At `LevelComplete` → same logic at level granularity.
- **Shard Finalizer**: At `ShardComplete` → all resources for this shard are through → can generate and upload shard document without waiting for the entire pipeline.
- **Batching**: Any stage can flush its internal batch buffer when a boundary arrives, instead of relying on timeouts or fixed sizes.
- **Backpressure**: Boundaries flow with the data — no separate coordination channel needed.

## RdfGraphSource: Data Flows in Its Natural Format

The core principle: **no stage decodes or encodes preemptively**. Data flows through the pipeline in whatever format it naturally arrives in, and is only decoded where the decoded form is actually needed.

```dart
/// A reference to RDF graph content in any representation.
///
/// Hierarchy:
///   RdfGraphSource
///   ├── EncodedRdfGraphSource (not yet decoded — carries raw content)
///   │   ├── TextGraphSource (Turtle, JSON-LD, N-Triples, etc.)
///   │   └── BinaryGraphSource (Jelly, etc.)
///   └── DecodedGraphSource (already decoded — optionally preserves original)
sealed class RdfGraphSource {
  const RdfGraphSource();

  /// Decode to an RdfGraph. For DecodedGraphSource, returns immediately.
  Future<RdfGraph> decode();
}

/// Not-yet-decoded content with a known content type.
/// I/O stages produce and pass these through without parsing.
sealed class EncodedRdfGraphSource extends RdfGraphSource {
  ContentType get contentType;
}

class TextGraphSource extends EncodedRdfGraphSource { ... }
class BinaryGraphSource extends EncodedRdfGraphSource { ... }

/// Already-decoded graph. Preserves the original encoded source
/// so downstream I/O stages can use raw bytes directly.
class DecodedGraphSource extends RdfGraphSource {
  final RdfGraph graph;
  /// The encoded form this was decoded from — enables pass-through
  /// to downstream I/O stages without re-encoding.
  final EncodedRdfGraphSource? originalSource;
  const DecodedGraphSource(this.graph, {this.originalSource});
}
```

**How data flows through stages:**

| Source | Format entering pipeline | Who decodes? |
|---|---|---|
| Remote (HTTP response) | `BinaryGraphSource` / `TextGraphSource` | Merge — always, for metadata extraction |
| Local DB (Jelly bytes) | `BinaryGraphSource` | Nobody, if fast-path upload only |
| Local DB (already in RAM) | `DecodedGraphSource` | Nobody — already decoded |

**Key behaviors:**
- **Remote data must always be decoded** by the Merge stage — it needs typeIri, clock, shard assignments to process and store the resource. Merge always produces a `DecodedGraphSource` with `originalSource` in the DB's storage format (e.g., Jelly). If the remote already provided Jelly, the original bytes are reused as `originalSource`; otherwise Merge re-encodes the decoded graph to Jelly. Commit writes `originalSource` bytes directly — no CPU.
- **Local data for upload** (LocalOnly fast path): The Fetch stage loads raw bytes from DB as `BinaryGraphSource`. If Merge can determine metadata from index entries alone (typeIri, clock, knownShardIris), it can pass the `BinaryGraphSource` through without decoding — Upload sends the original bytes directly.
- **Conflict data**: Both sides fully decoded for CRDT merge. Merge encodes the result to the DB format.
- **DB storage strategy**: Commit writes data in the DB's preferred encoding (e.g., Jelly). On subsequent syncs, loading from DB yields `BinaryGraphSource` — no decode needed for upload.

**Prerequisite**: All relevant codecs (especially Jelly) must be registered with `rdf_core` at `SyncEngine` initialization. This was previously missing and must be done explicitly.

## Remote Index Mirror

The Remote Index Mirror stores the known remote state per shard — enabling diff-by-DB instead of diff-by-download. The mirror is **owned by the Remote Backend** (not Core) — see [Ownership](#ownership-backend-not-core) below.

### Motivation

The current architecture downloads shard documents, parses entries (resource IRIs, clock hashes), uses them for comparison — and then **discards** this information. Only the ETag is persisted. ETags tell us *whether* a shard changed, but not *what* changed within it.

**The mirror complements ETags** — it persists the *parsed content* of changed shards. The existing ETag-based conditional download (304 Not Modified for unchanged shards) remains unchanged.

When a shard *has* changed (new ETag), the current code must:
1. Download and parse the full shard document
2. Compare every entry against local index entries
3. Determine which individual resources changed

With a mirror, we can diff the **new** shard entries against the **stored** mirror (what we last saw) to identify exactly what changed remotely.

### Ownership: Backend, Not Core

The mirror is **owned by the Remote Backend**, not by Core. Core has no knowledge of mirror tables, mirror schemas, or mirror content. This separation exists because:

1. **Different backends need different mirror strategies**: A file-per-resource backend (Solid) may only need `(resourceIri, shardIri, clockHash)` — 50 bytes per entry. An aggregate-file backend (GDrive) may need to store the complete resource content to avoid re-downloading the entire aggregate file for single-resource changes.
2. **Mirror schema is backend-specific**: Core cannot anticipate what data each backend needs to persist.
3. **Clean separation of concerns**: Core manages CRDT sync state; the backend manages its own knowledge of the remote.

### Callback Mechanism for Crash Safety

Although the mirror is owned by the backend, it must be updated **atomically in the same DB transaction as the commit** — otherwise a crash between Core's commit and the backend's mirror update would leave them inconsistent.

Solution: Core's DB Commit stage calls a **backend-provided callback** within the commit transaction:

```dart
// Inside DB Commit transaction:
await db.inTransaction(() async {
  // Core writes its own state:
  await saveDocuments(batch);
  await saveIndexEntries(batch);
  await setRemoteETags(batch);

  // Backend writes its mirror data (whatever it needs):
  await backend.onCommit(batch);
});
```

**Key properties:**
- Core passes the committed batch to the backend callback
- The backend decides what to persist — from minimal metadata to full resource content
- Everything runs in one atomic transaction: if anything fails, both Core state and mirror roll back together
- The callback uses the same DB connection (same Drift transaction context)

### Convenient Mirror Services

Core provides **three convenience services** that backends can optionally use within their `onCommit` callback:

1. **`RemoteIndexMirrorService`**: Standard `(resourceIri, shardIri, clockHash)` mirror — sufficient for backends that only need to track what exists remotely and at what version.
2. **`RemoteContentMirrorService`**: Stores full resource content per shard — for backends like GDrive that benefit from having the complete data locally to avoid re-downloading aggregated files.
3. **`RemoteShardMirrorService`**: Stores the complete parsed shard document — for backends that want to reconstruct shard state without re-downloading.

Backends compose these services as needed, or implement completely custom mirror logic. A Solid backend might use only service 1; a GDrive backend might use services 1 + 2.

**Future direction**: A future concept might reduce or eliminate the need for separate mirror tables by reusing the normal sync tables, but for now we design this as a full-blown import tables database.

### Crash Safety

Because the mirror update runs inside the same DB transaction as the commit:

- **Crash before commit**: Mirror reflects previous successful sync. Next sync re-downloads and re-processes — CRDT idempotency means redundant work, not corruption.
- **Crash after commit**: Mirror correctly reflects committed state.

The mirror is never ahead of or behind the committed local state.

## Pipeline Stages

### Stage 1: Hierarchical Discovery

Discovery traverses the full index hierarchy top-down via conditional GETs (ETag-gated), flattening it into a single output stream. Children at each level are determined by the **union of remote + local**: remote children from the downloaded parent document, plus locally-known children from the DB.

**Hierarchy structure:**

The hierarchy alternates between index documents (list child IRIs — existence only) and shard documents (entries with clockHash — existence + change info):

```
IoI-Index (index doc)           ──lists──▶  IoI-Shard IRIs (existence only)
  └─ IoI-Shards (shard docs)    ──entries──▶ (indexIri, clockHash) per index
       └─ Indices (index docs)  ──lists──▶  Data-Shard IRIs (existence only)
            └─ Data Shards (shard docs) ──entries──▶ (resourceIri, clockHash) per resource
```

**This hierarchy covers FullIndex instances** (including the Index-of-GroupIndex-Templates / IoGIT, which is structurally a FullIndex). GroupIndexTemplates are just documents (not indices, no shards) — they require no special sync treatment. **GroupIndex instances** are not part of this hierarchy — they are discovered via the `group_index_subscriptions` DB table (see [GroupIndex Discovery](#groupindex-discovery) below).

**`index_shards` table**: An `(index_iri, shard_iri)` DB table tracks which shards belong to each index. This avoids loading and parsing index documents from the DB in the 304 case — a simple `SELECT shard_iri FROM index_shards WHERE index_iri = ?` replaces RDF parsing. The table is populated in Stage 6 (DB Commit) when index documents are committed.

**Key distinction**: Index documents only tell us their children **exist** — not whether they changed. Each child needs an individual ETag check. Shard documents provide per-entry `clockHash`es, enabling fine-grained change detection via mirror comparison without downloading each child.

**Per-level behavior:**

**Level 0: IoI-Index** (single document per backend)
- Entry point: configured IoI IRI
- Conditional GET → Changed (200): emit `DiscoveredDocument(ioI)`, parse for IoI-Shard IRIs
- Unchanged (304): emit `DiscoveredDocument(ioI, null, ioI)` — Diff checks for local changes; still ETag-check each IoI-Shard (no change propagation)
- Missing (404): remote has no index structure → all local indices are LocalOnly candidates
- Union IoI-Shard IRIs: from downloaded content (200) or `index_shards` table (304) + locally-known from `index_shards`

**Level 1: IoI-Shards** (shard documents with per-index entries)
- For each IoI-Shard IRI from Level 0:
  Conditional GET → Changed (200): emit `DiscoveredShardEntries(shardIri, entries)` where entries contain `(indexIri, clockHash)` per index
- Unchanged (304): emit `ShardUnchanged(shardIri)` — mirror has correct entries for index-level diffing
- Missing (404): emit `DiscoveredEmpty(shardIri)` — all indices in this shard are LocalOnly candidates
- `ShardComplete(shardIri)` after each; `LevelComplete(ioiShard)` after all

The Diff stage uses these entries to identify which **index documents** have changed (clockHash comparison against mirror), analogous to how it identifies changed resources from data shard entries.

**Level 2: Indices** (FullIndex documents — including the IoGIT)
- For each index IRI identified in Level 1 (union of remote entry IRIs + locally-known):
  Conditional GET on index document
- Changed (200): emit `DiscoveredDocument(index)`, parse downloaded content for Data-Shard IRIs
- Unchanged (304): emit `DiscoveredDocument(index, null, type)` — Diff checks for local changes; query `index_shards` table for Data-Shard IRIs (no RDF parsing needed)
- Missing (404): emit `DiscoveredEmpty(indexIri)` — all local shards of this index are local-only
- Union Data-Shard IRIs: from downloaded content (200) or `index_shards` table (304) + locally-known from `index_shards`
- `LevelComplete(index)` after all indices and their shards are identified

**Important**: Discovery downloads index documents itself (conditional GET) rather than waiting for Fetch (Stage 3). The download serves dual purpose: (1) extract child shard IRIs for continued discovery, (2) provide content attached to `DiscoveredDocument` for CRDT sync downstream.

**Level 3: Data Shards** (shard documents with per-resource entries)
- For each Data-Shard IRI from Level 2:
  Conditional GET → Changed (200): emit `DiscoveredShardEntries(shardIri, entries)` where entries contain `(resourceIri, clockHash)` per resource
- Unchanged (304): emit `ShardUnchanged(shardIri)` — mirror has correct entries for resource-level diffing
- Missing (404): emit `DiscoveredEmpty(shardIri)` — all local resources in this shard are LocalOnly candidates
- `ShardComplete(shardIri)` after each; `LevelComplete(shard)` after all

**Level 4: Resources** — Not handled by Discovery. Resources are identified by Data-Shard entries and fetched in Stage 3 (Resource Fetch).

#### GroupIndex Discovery

GroupIndex instances are **not** discovered via the IoI hierarchy. Instead, after the hierarchy traversal completes, Discovery queries the `group_index_subscriptions` DB table via `getSubscribedGroupIndices()` to find all subscribed GroupIndex instances.

Each subscribed GroupIndex then enters the same pipeline at Level 2: conditional GET on the GroupIndex document, extract Data-Shard IRIs (from download or `index_shards` table), then process Data Shards at Level 3. The downstream stages (Diff, Fetch, Merge, Upload, Commit, Finalize) handle them identically to FullIndex data.

This decoupling is intentional: GroupIndex instances are created dynamically (e.g., when a note is saved to a new month-group), and only subscribed instances are synced. The IoGIT syncs the template *configurations* as ordinary documents — but the concrete GroupIndex instances that these templates produce are managed entirely through the subscription table.

**Output stream** — a flat `Stream<DiscoveryEvent>` containing:
- `DiscoveredDocument(iri, remoteSource, type)` — hierarchy documents (IoI, Index) needing CRDT sync
- `DiscoveredShardEntries(shardIri, entries, etag)` — per-child entries from shard documents (both IoI-Shards and Data Shards)
- `ShardUnchanged(shardIri)` — shard ETag matched (304)
- `DiscoveredEmpty(iri)` — document/shard returned 404
- `DiscoveryBoundary(boundary)` — structural markers (`ShardComplete`, `LevelComplete`)

**Shard documents are NOT sync candidates** — they are regenerated from committed state in Finalize (Stage 7). Discovery downloads them only to extract their entries.

**Parallelism**: Multiple concurrent downloads within and across levels, bounded by `maxConcurrentDownloads`. IoI and index documents (few, small) complete quickly; data shard downloads (many) dominate elapsed time.

### Stage 2: Diff Transform

Transforms `Stream<DiscoveryEvent>` → `Stream<DiffEvent>` by comparing discovered items against local state. Handles two kinds of discovery events with different diffing strategies.

**Hierarchy documents** (`DiscoveredDocument` — IoI, Index):
- Compare remote document against local version in DB
- Remote changed (200) + no local → `RemoteOnlyCandidate`
- Remote changed (200) + local exists → `ConflictCandidate` (both sides available — CRDT merge)
- Remote unchanged (304) + local changed → `ConflictCandidate` (safe default — Fetch downloads remote content; see optimization note below)
- Remote unchanged (304) + local unchanged → skip
- Remote missing (404) + local exists → `LocalOnlyCandidate`
- These flow through Fetch → Merge → Upload → Commit like any document

**Shard entries** (`DiscoveredShardEntries` — from IoI-Shards and Data Shards):

The same logic applies at both shard levels. IoI-Shard entries identify index documents; Data Shard entries identify resource documents. The diffing pattern is identical:

1. Load local index entries for this shard from DB
2. Load mirror entries for this shard via backend (backend exposes its mirror data for diffing)
3. Per remote entry:
   - No local match → `RemoteOnlyCandidate`
   - Local match, remote clockHash ≠ mirror clockHash (remote changed) → `ConflictCandidate`
   - Local match, remote clockHash = mirror clockHash, but local `updatedAt > lastSyncTimestamp` (local changed) → `ConflictCandidate`
   - Local match, neither side changed → skip
4. Track seen child IRIs (per shard)

**At ShardComplete boundary**:
1. Query local entries for this shard that are **not** in the seen-set **and** changed since last sync (`updatedAt > lastSyncTimestamp`)
2. Emit `LocalOnlyCandidate` for each
3. Forward `ShardComplete` boundary as `DiffBoundary`
4. Clear seen-set for this shard

**At LevelComplete boundary**:
Forward as `DiffBoundary`.

**For ShardUnchanged (304)**:
Mirror has correct entries — only the boundary-triggered remaining-items query runs → only locally-changed items that don't exist remotely are emitted.

**For DiscoveredEmpty (404)**:
All local entries for this shard/document that changed since last sync → `LocalOnlyCandidate`.

**Deduplication**: A resource may appear in multiple shards (FullIndex + GroupIndex). First occurrence wins; subsequent appearances for the same IRI are skipped. Note: the *same* shard IRI does not appear in multiple indices — deduplication operates at the child level, not the shard level.

**Optimization potential**: The current approach always loads both sides and performs CRDT merge whenever either side has changed. This is the safe default — it makes no assumptions about whether the unchanged side's state is already incorporated in the changed side's version. A future optimization could verify this via clock comparison: if the changed side's clock strictly subsumes the unchanged side's clock, a one-sided accept (`RemoteOnlyCandidate` / `LocalOnlyCandidate`) is sufficient, avoiding the redundant load and merge overhead.

### Stage 3: Resource Fetch

Transforms `Stream<DiffEvent>` → `Stream<FetchEvent>` — the last I/O stage before pure CPU.

**Per SyncCandidate**:
- `RemoteOnlyCandidate`: Fetch remote content via backend transform → `EncodedRdfGraphSource` (raw bytes, not decoded)
- `LocalOnlyCandidate`: Load raw bytes from DB → `BinaryGraphSource` (Jelly bytes — not decoded)
- `ConflictCandidate`: Fetch remote (from backend) **and** load local (from DB) — both as `EncodedRdfGraphSource`

**Batching**: Collects candidates into bounded batches and sends them through the backend transform for concurrent I/O. The backend decides how to fulfill them:
- **File-per-Resource** (Solid): Individual HTTP requests per resource
- **File-per-Shard** (Dir): Content already downloaded during Discovery — returns from internal cache
- **Aggregated** (GDrive): Same as File-per-Shard

**Backend-internal sub-stages**: Backends with complex format needs (e.g., GDrive must parse/rebuild aggregate files, Solid may need Turtle↔Jelly conversion for uploads) compose their own internal I/O → CPU → I/O stages. This is invisible to the pipeline — the backend transform signature is simply `Stream<FetchRequest> → Stream<FetchResult>`.

**Backend as stream transform**: The backend receives `Stream<FetchRequest>` and returns `Stream<FetchResult>` — the pipeline never calls download/upload methods directly:

```dart
// Backend transform signature (conceptual)
Stream<FetchResult> backendFetch(Stream<FetchRequest> requests);
```

**Boundaries**: Forwarded through as `FetchBoundary`.

### Stage 4: CRDT Merge (Pure CPU)

Transforms `Stream<FetchEvent>` → `Stream<MergeEvent>` — **no I/O, pure computation**.

The Merge stage receives `FetchedResource` events containing `RdfGraphSource` instances. It decodes only where necessary — preserving `originalSource` for downstream pass-through.

**Fast Paths** (determined by `SyncCandidate` subtype):

| Candidate Type | Action | Decodes? | Output |
|---|---|---|---|
| `RemoteOnlyCandidate` | Accept remote | Yes — must extract typeIri, clock, shards | `DecodedGraphSource(graph, originalSource: dbFormatBytes)` — originalSource is remote bytes if already in DB format, otherwise Merge re-encodes |
| `LocalOnlyCandidate` | Keep local, upload | No — metadata from index entry | `BinaryGraphSource` passed through as-is (already in DB format) |
| `ConflictCandidate` | Full CRDT merge | Yes — both sides | `DecodedGraphSource(mergedGraph, originalSource: dbFormatBytes)` — Merge encodes to DB format |

**Remote-only decode is unavoidable** — we need typeIri, clock, and shard assignments to store the resource in the local DB. Merge ensures `originalSource` is in the DB's storage format: if the remote already provided Jelly, the original bytes are reused; otherwise Merge encodes the decoded graph to Jelly. Commit writes `originalSource` bytes directly — no CPU.

**Local-only pass-through** — the Fetch stage provides `BinaryGraphSource` (raw Jelly from DB). Merge reads metadata (typeIri, clock, knownShardIris) from the index entry, not from the graph. The `BinaryGraphSource` flows through to Commit unchanged, which uploads the original bytes directly.

**Conflict merge produces DB-ready output** — Merge decodes both sides, performs CRDT merge, encodes the result to the DB format → `DecodedGraphSource(mergedGraph, originalSource: jellyBytes)`. Commit writes the Jelly bytes.

**Output**: `MergedResource` with `RdfGraphSource` (decoded or pass-through), clock, shard assignments, `needsUpload` flag.

**Boundaries**: Forwarded through as `MergeBoundary`.

### Stage 5: Upload Transform (Remote I/O Only)

Transforms `Stream<MergeEvent>` → `Stream<UploadEvent>`. **Pure Remote I/O — no DB access, no decoding or encoding.**

**Behavior**:
- Resources with `needsUpload: true`: upload content to remote backend, receive ETag
- Resources with `needsUpload: false`: pass through unchanged (wrapped in `UploadEvent`)
- Content for upload: reads raw bytes from `MergedResource.graphSource` — already in the correct format

**Why a separate stage**: Splitting upload from DB commit enables natural stream pipelining — while batch N is being committed to DB (Stage 6), batch N+1's uploads run concurrently.

**Batching**: Collects into bounded batches for concurrent uploads (e.g., 10 concurrent).

**ETag preservation**: The upload response ETag flows as part of the `UploadedResource` event payload — DB Commit writes it atomically with everything else.

**Boundaries**: Trigger batch flush. Forward as `UploadBoundary`.

**Backends with complex upload formats**: Backends that need CPU-intensive format transformation for upload (e.g., GDrive rebuilding aggregate files) compose their own internal sub-stages. The Upload Transform simply calls `backend.upload()` — it doesn't know about internal complexity.

### Stage 6: DB Commit (Atomic DB Write + Backend Mirror Callback)

Transforms `Stream<UploadEvent>` → `Stream<CommitEvent>`. **Pure DB I/O — no remote calls, no decoding or encoding.**

**Behavior**:
- Collect uploaded resources into batches (configurable, e.g., 500–2000)
- For each batch, run a **single atomic DB transaction** that:
  1. Writes documents (raw bytes from `graphSource` — Merge guaranteed DB format)
  2. Writes index entries
  3. Writes ETags (including upload ETags from Stage 5)
  4. Updates `index_shards` table for any committed index documents (records which shard IRIs each index lists via `hasShard`)
  5. Calls **`backend.onCommit(batch)`** — the backend mirror callback

**Backend Mirror Callback**: Core calls the backend-provided callback *within* the transaction. The backend can persist whatever mirror data it needs — from minimal `(resourceIri, clockHash)` tuples to full resource content. This runs in the same Drift transaction context, so it's atomic with Core's writes. Core has no knowledge of what the backend persists.

**Pipeline overlap diagram**:

```
Time ─────────────────────────────────────────────────────▶

Pull:   [fetch batch 1]──[merge batch 1]──[DB commit batch 1]
              [fetch batch 2]──[merge batch 2]──[DB commit batch 2]

Push:   [merge 1]──[upload 1]──[DB commit 1]
              [merge 2]──[upload 2]──[DB commit 2]

Mixed:  [merge 1]──[upload 1]──[DB commit 1]
              [merge 2]──[upload 2]──[DB commit 2]
```

Each row shows natural pipelining: while DB commit runs for batch N, merge and upload stages process batch N+1 concurrently.

**Boundaries**: Trigger batch flush (commit whatever is buffered so far). Forward as `CommitBoundary`.

### Stage 7: Shard Finalize

Consumes `Stream<CommitEvent>` — the terminal stage.

**ShardAggregator pattern**: Collects committed items per shard. At each `ShardComplete` boundary, all items for that shard are through → generate shard document from DB state → upload → commit shard metadata. This applies at **both shard levels**: IoI-Shards (listing index entries) and Data Shards (listing resource entries).

This replaces the previous `expectedResourceCount` approach — boundaries make completion detection trivial.

**Items are uploaded before shards (push scenarios)**: For backends that upload individual documents (e.g., File-per-Resource / Solid), the Upload Transform (Stage 5) uploads documents before Finalize generates and uploads shard documents. Shard documents are only generated after all their constituent items are committed. This ensures shard documents always reflect actually-committed state.

## Fast Paths: Initial Sync (Both Directions)

### Fast Path A: Empty Local (Pull)

- **Discovery**: Remote mirror is empty → every remote entry is "new"
- **Diff**: 100% `RemoteOnlyCandidate`
- **Merge**: Fast path — accept remote, `needsUpload: false`
- **Upload**: All items pass through (no uploads needed)
- **DB Commit**: DB write only. Backend mirror callback populates mirror for the first time.

### Fast Path B: Empty Remote (Push)

- **Discovery**: All shard downloads return 404 → `DiscoveredEmpty` for each
- **Diff**: 100% `LocalOnlyCandidate` (all local entries that changed since last sync)
- **Merge**: Fast path — keep local, `needsUpload: true`
- **Upload**: All items uploaded to remote
- **DB Commit**: DB write + backend mirror callback populates mirror for the first time.

### Fast Path C: Incremental Sync (No Changes)

- **Discovery**: All shard ETags match → 304 for all → only boundaries emitted
- **Diff**: Boundary remaining-items queries find no changed local items → zero candidates
- **Stages 3–7**: Not reached

### Fast Path D: Incremental Sync (Few Changes)

- **Discovery**: Most shards return 304. Changed shards parsed.
- **Diff**: Mirror diff (via backend) identifies changed remote entries + boundary remaining-items query finds changed local entries
- **Merge**: CRDT merge for all changed resources (safe default — loads both sides; see optimization note in Stage 2)
- **Upload**: Only resources with `needsUpload: true` uploaded
- **DB Commit**: Only affected resources committed; backend mirror callback updates mirror entries

## Backpressure and Flow Control

The pipeline uses Dart's Stream mechanics for natural backpressure:

```
Discovery ──── Diff ──── Fetch ──── Merge ──── Upload ──── DB Commit ── Finalize
    │            │          │          │          │            │           │
    ├─ pauses    ├─ pauses  ├─ pauses  ├─ pauses  ├─ batch     ├─ batch    ├─ aggregates
    │  when Diff │  when    │  when    │  when    │  flush on  │  flush    │  until
    │  buffer    │  Fetch   │  Merge   │  Upload  │  boundary  │  on       │  ShardComplete
    │  full      │  buffer  │  buffer  │  buffer  │            │  boundary │  boundary
    │            │  full    │  full    │  full    │            │           │
```

If any stage is the bottleneck, upstream stages naturally slow down via Stream subscription pause/resume. Boundaries ensure buffers flush at structural points.

## Concurrency Model

Dart is single-threaded but async. We use async concurrency (overlapped I/O) rather than true parallelism.

### I/O Overlap Across Stages

The key insight: while the DB Commit stage writes to DB, the Upload stage uploads the next batch, the Fetch stage downloads further resources, and Discovery continues traversing the hierarchy. Stages never block each other — they just slow down via backpressure.

### Bounded Batching Within Stages

Each stage has its own batch size tuned to its bottleneck:
- **Discovery**: `maxConcurrentDownloads` (e.g., 10) concurrent shard fetches
- **Fetch**: Bounded batch of resource content downloads (e.g., 10 concurrent)
- **Upload**: Bounded concurrent resource uploads (e.g., 10 concurrent)
- **DB Commit**: Batch size for DB transactions (e.g., 500–2000 resources)
- **Finalize**: Bounded concurrent shard uploads

### Drift DB Concurrency

Locorda uses Drift (SQLite) with all operations serialized through a background isolate:

- **No parallel DB writes**: Drift queues operations sequentially
- **Interleaving, not parallelism**: Network I/O overlaps with DB writes, but DB operations themselves are serial
- **WAL mode**: Available for concurrent reads during writes, but single-writer constraint remains
- **Implication**: DB Commit stage naturally suited for batched transactions; Upload and Fetch stages overlap remote I/O during DB waits

## Expected Performance Improvement

### Current (Sequential)
```
15,000 × (download + decode + merge + encode + upload + DB) = ~18s
```

### Streaming Pipeline — Empty Local (Pull)
```
Discovery:  Shard downloads @ 10 concurrent ≈ 0.5s
Fetch:      15K resource downloads @ 10 concurrent ≈ 1.5s (overlapped with Discovery)
Merge:      15K fast-path accepts ≈ 0.3s (pure CPU, overlapped with Fetch)
Upload:     No uploads (pass-through)
DB Commit:  15K DB inserts @ 2000/batch ≈ 1.5s (pipelined with Merge)
Finalize:   ~4 shard docs ≈ 0.1s

Effective time (pipelined): ~2–3s
```

### Streaming Pipeline — Empty Remote (Push)
```
Discovery:  All 404s ≈ 0.1s
Diff:       Emit 15K LocalOnlyCandidates from local index ≈ 0.1s
Merge:      15K local pass-through ≈ 0.1s
Upload:     15K uploads @ 10 concurrent ≈ 1.5s (pipelined with Merge)
DB Commit:  15K DB updates @ 2000/batch ≈ 1.0s (pipelined with Upload)
Finalize:   ~4 shard docs ≈ 0.1s

Effective time (pipelined): ~2–3s
```

## Migration Strategy

1. Create `StreamingSyncFunction` alongside existing `SyncFunction`
2. Both implement the same public interface
3. Configuration flag to choose between them
4. Run both in tests, compare results for correctness
5. Gradually migrate as streaming version proves stable

The remote index mirror introduced incrementally:
- First: populate mirror during existing sync (write-only)
- Verify mirror consistency against actual remote shard contents
- Then: switch to mirror-based diffing in the streaming pipeline

## Comparison with Current Architecture

| Aspect | Current (Three-Phase) | Streaming Pipeline |
|--------|----------------------|-------------------|
| **Pipeline model** | Orchestrator calls methods on services | Pure stream composition — no orchestrator |
| **Backend interface** | `GraphSyncStorage.download()/upload()` called by pipeline | Backend as stream transform `Stream<Req> → Stream<Res>` |
| **Discovery** | Rigid phases: meta-types → GroupIndex → shards | Single stream traversing hierarchy internally |
| **Diffing** | Downloads shard, compares entries, discards | Backend-owned mirror; subsequent diffs are DB-only |
| **Change detection** | ETags for remote; no "changed since" filter for local | ETags for remote; `updatedAt > lastSyncTimestamp` for local |
| **Graph decoding** | Immediate — every stage works with RdfGraph | CPU in CPU stages only — Merge decodes/encodes, I/O stages handle raw bytes |
| **Upload/Commit** | Mixed in single phase | Separated: Upload Transform (Remote I/O) → DB Commit (DB I/O) for pipelining |
| **Mirror ownership** | N/A | Backend-owned; Core calls backend callback within DB transaction |
| **Coordination** | Phase barriers (download ALL → merge ALL → upload ALL) | Boundary elements flow inline with data |
| **Empty-remote** | Shard 404, but still downloads per resource | Shard 404 → `LocalOnlyCandidate` — zero per-resource downloads |
| **Shard finalization** | Wait for all resources, then finalize all shards | `ShardComplete` boundary triggers per-shard finalization |
| **Crash safety** | ETags + index entries | Same + mirror consistent in same transaction |

## Risks and Mitigations

| Risk | Mitigation |
|------|-----------|
| Stream composition complexity | Start with simple async generators; add stream transforms incrementally |
| Backpressure bugs | Bounded buffers with explicit capacity; boundaries trigger flush |
| Boundary ordering | Pipeline is in-order; no stage reorders events |
| Partial failure | Each batch commit is atomic; failed resources retry in next sync |
| Shard consistency | `ShardComplete` boundary ensures completeness before finalization |
| Concurrency bugs | All I/O within single isolate (no shared state) |
| Mirror inconsistency | Backend mirror callback runs inside Core's DB transaction — atomic |
| Mirror bootstrapping | First sync without mirror = current behavior; mirror builds organically |
| Mirror ownership boundary | Core provides callback mechanism + convenience services; backend decides what to persist |
| Codec registration | Jelly + all codecs registered at `SyncEngine` init (explicit requirement) |
| RdfGraphSource overhead | Minimal: sealed class hierarchy is zero-cost abstraction; `originalSource` preservation avoids decode→re-encode roundtrips |
| Drift serialization | Batch commits amortize transaction overhead; other stages overlap with DB waits |
