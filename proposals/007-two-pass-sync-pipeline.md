# 007: Feedback-Loop Sync Pipeline — Clean Stage Decomposition

## Goal

A **maximally decomposed streaming sync pipeline** where each stage has exactly one I/O type. Data flows through composed stream transforms — no external coordinator, no phase barriers. Stages can be merged later once the conceptual model is proven.

**Design maxims**: KISS, YAGNI, clarity over cleverness.

**Target**: Sync 15,000 resources in under 3 seconds — in either direction (empty local ← full remote, or full local → empty remote).

## Core Model: Single Pipeline with Feedback Loop

A single pipeline processes all sync work. A **Feedback Stage** at the end injects new items into the input stream based on what was discovered. Meta-sync (index of indices (aka IoI) → index documents) and content-sync (indices → data resources) are distinguished by *what gets injected*, not by separate pipeline instances.

```
inputController ──▶ [Pipeline Stages 1–10] ──▶ Feedback Stage ──┐
      ▲                                                          │
      └──────────────────────────────────────────────────────────┘
      (re-inject IoI or inject discovered indices)
```

### Pipeline Trigger

The sync manager (manual, timer, or reconnect) triggers the pipeline with two values:
- **`lastSyncTimestamp`** — from DB, passed to Stage 4 for identifying locally-changed items (`updatedAt > lastSyncTimestamp`).
- **`ioiIri`** — the Index-of-Indices IRI, used as the initial seed.

### Sync Flow

1. **Seed**: read IoI clock hash from `documents` table → `inputController.add(SyncInput([ioiIri], ioiClockHashSnapshot: currentHash))`
2. Stage 1 resolves all shards for the batch (here: just the IoI). Shards flow through Stages 2–10. Resources discovered are FullIndex index documents (indices for application specific types, but also indices of ClientInstallation, FullIndex (this is the IoI acctually itself), GroupIndexTemplate, etc.)
3. Stage 9 commits index documents → extracts `idx:hasShard` → populates `index_shards` table
4. `PhaseComplete` arrives at Feedback Stage (after all shards have been processed through Stages 2–10):
   - **IoI changed** (current clock hash ≠ `ioiClockHashSnapshot`) → re-inject IoI with new snapshot: `inputController.add(SyncInput([ioiIri], retryCount: retryCount + 1, ioiClockHashSnapshot: currentHash))`
   - **IoI stable** → query all content index IRIs from DB (FullIndex + subscribed GroupIndex) → inject as **one** batch: `inputController.add(SyncInput(allContentIndices))`
5. Stage 1 resolves all shards for all content indices in two bulk DB queries. Resources are now data (notes, tags, etc.)
6. `PhaseComplete` arrives → Feedback Stage detects content phase completion
7. `inputController.close()` → pipeline ends

### Loop Detection

Every `SyncInput` carries a `retryCount`. The Feedback Stage increments it on re-injection. If `retryCount > 4`, the pipeline aborts with an error — the IoI is oscillating and something is fundamentally wrong.

```dart
class SyncInput {
  final List<IriTerm> indexIris;
  final int retryCount;
  /// Clock hash of the IoI document at the moment this IoI-phase input was
  /// injected. Feedback Stage compares this against the DB value after the
  /// iteration to detect whether the IoI changed (OQ3 resolved).
  final String? ioiClockHashSnapshot;
  const SyncInput(this.indexIris, {this.retryCount = 0, this.ioiClockHashSnapshot});
}
```

Each `SyncInput` is a **batch**: all index IRIs that should be processed together. The Feedback Stage always injects exactly **one** `SyncInput` per phase — never multiple individual items. This guarantees that Stage 1 can resolve all shards for the entire batch in two bulk DB queries.

### Shard List Availability

Each installation creates its own IoI and at least one IoI-Shard on startup, populating the `index_shards` table. Stage 1 always finds at least the local shard. After the IoI's shards are synced and index documents are committed (Stage 9), the `index_shards` table is populated for all discovered indices *before* the Feedback Stage injects them. There is never a moment where Stage 1 encounters an index with unknown shards under normal operation.

**Safety net**: If Stage 1 finds 0 shards for any index within the batch (e.g. corrupted DB), it records those IRIs in the `PhaseComplete`'s `zeroShardIndices` list. The Feedback Stage detects this, fetches the affected index documents via conditional GET, parses `idx:hasShard`, populates `index_shards`, and re-injects those indices as a new `SyncInput` with `retryCount + 1`. Convergence is guaranteed by the retry limit.

## Design Principles

1. **Stream across stages, batch within stages**: Resources flow continuously from stage to stage — no phase barriers. Within a single stage, I/O operations are batched/chunked for efficiency (e.g. 10 concurrent downloads, 500–2000 items per DB transaction).
2. **Backend as stream transform**: The backend is a function `Stream<Request> → Stream<Result>`. All backend-specific complexity (file-per-resource vs. file-per-shard vs. aggregated storage) is encapsulated inside the transform.
3. **Boundary elements for coordination**: Typed sentinel events (`ShardComplete`, `PhaseComplete`) flow inline with data — no external coordinator needed.
4. **CPU stages only do CPU; I/O stages only do I/O**: No parsing in I/O stages. `EncodedRdfGraphSource` (raw bytes/text) flows through I/O stages untouched. All decoding/encoding happens in CPU stages (3, 7).
5. **Only sync what changed**: ETags for remote shards, `updatedAt > lastSyncTimestamp` for local. Unchanged items are never processed.
6. **Backend persists its own remote knowledge**: Each backend maintains its own view of the remote state via a transactional callback within Core's DB commit. Core never accesses mirror data directly.

## Implementation Scope

**First implementation target: file-per-resource backend.**

This pipeline is initially designed and implemented for the **file-per-resource** storage model, where each synced resource maps 1:1 to a remote file and shard documents are the only aggregated uploads (Stage 10).

**Shard-dataset and single-file backends** are expected to be implemented self-contained within each backend (with helper services — including DB storage — provided by Core). Their approach:
- Duplicate incoming remote data into backend-managed **import tables**.
- Build full shard documents / single aggregated files from that import data before upload.

Core's pipeline stages remain unchanged; all backend-specific aggregation complexity stays inside the backend's stream transforms.

---

## Pipeline Stages

**Input**: `Stream<SyncInput>` — each element is a batch of index IRIs (with retry counter), fed by `inputController`. The Feedback Stage injects exactly one `SyncInput` per phase.
**Shared context**: `lastSyncTimestamp`

Two boundary types flow inline with data events: `ShardComplete` and `PhaseComplete`. Stages that react to a boundary type wrap it in their own typed event; stages that don't care simply pass it through.

---

### Stage 1: Shard Resolution (core, DB read)

For each `SyncInput` (a batch of index IRIs), issues two bulk DB queries within a single read-only transaction: one to resolve all shard IRIs, one to fetch all stored ETags for those shards.

| | |
|---|---|
| **Owner** | Core |
| **I/O** | DB read (single read-only transaction, two queries) |
| **Input** | `Stream<SyncInput>` — each element contains `List<IriTerm>` |
| **Operation** | Per `SyncInput`: (1) `SELECT index_iri, shard_iri FROM index_shards WHERE index_iri IN (…)` for **all** index IRIs in the batch — chunked at SQLite's 999-variable limit if needed. (2) `SELECT shard_iri, etag FROM remote_sync_state WHERE shard_iri IN (…)` for **all** shard IRIs from step (1). Emit one `ShardRef` per shard, then one `PhaseComplete` at the end. |
| **Output** | `Stream<ShardRef(indexIri, shardIri, storedEtag?) + PhaseComplete>` |
| **Batching** | 2 DB queries total per `SyncInput` (with SQLite chunking at >999 IRIs) |

Index IRIs with no rows in the result are collected in `PhaseComplete.zeroShardIndices`. The Feedback Stage handles these as a safety net (see [Feedback Stage](#stage-14-feedback-stage-orchestration)).

---

### Stage 2: Shard Fetch (backend, remote I/O)

Batched/chunked conditional GETs for shard documents.

| | |
|---|---|
| **Owner** | Backend |
| **I/O** | Remote HTTP |
| **Input** | `Stream<ShardRef>` |
| **Operation** | Conditional GET (`If-None-Match: storedEtag`). No ETag → unconditional GET. |
| **Output** | `Stream<FetchedShard>` |
| **Batching** | Chunked: max N concurrent HTTP requests (e.g. 10) |

`FetchedShard` variants:
- **`ShardContent(shardIri, source: RdfGraphSource, newEtag)`** — 200: raw bytes, no parsing. Backend-specific format (Turtle, Jelly, …). Dataset/single-file backends may emit `DecodedGraphSource` (without encoded original).
- **`ShardNotModified(shardIri)`** — 304: shard unchanged.
- **`ShardGone(shardIri)`** — 404/410: shard removed.

---

### Stage 3: Shard Parse (core, CPU)

Decode fetched shard documents and extract resource entries.

| | |
|---|---|
| **Owner** | Core |
| **I/O** | None — pure CPU |
| **Input** | `Stream<FetchedShard>` |
| **Operation** | Decode `RdfGraphSource` → extract entries. 304/404 → pass through. |
| **Output** | `Stream<ShardResult>` |

One `ShardResult` per shard — no `ShardComplete` here. Stage 4 introduces `ShardComplete` after the entry fan-out.

`ShardResult` variants:
- **`ParsedShard(shardIri, entries: List<ShardEntry>, decodedGraph: DecodedGraphSource, newEtag)`** — decoded entries + full parsed graph from 200 response. The `decodedGraph` is carried through to Stage 11 for CRDT-correct shard rebuild.
- **`ShardNotModified(shardIri)`** — pass-through from Stage 2.
- **`ShardGone(shardIri)`** — pass-through, shard removed remotely.

Each `ShardEntry` carries at minimum `(resourceIri, clockHash)`.

---

### Stage 4: Change Detection (core, DB read)

Compare remote shard entries against local `index_entries` to classify each resource for sync. This stage performs the 1:N fan-out (one `ShardResult` → N `SyncCandidate` events) and introduces `ShardComplete` at the end of each shard.

| | |
|---|---|
| **Owner** | Core |
| **I/O** | DB read (`index_entries` table) |
| **Input** | `Stream<ShardResult>` |
| **Operation** | Per `ParsedShard`: (1) load local entries from `index_entries WHERE shard_iri = ?`, (2) in-memory diff of local vs. remote entries by `clockHash`, (3) emit N `SyncCandidate` events, (4) remaining-items query for locally-changed resources not in remote, (5) emit `ShardComplete`. `ShardNotModified` → emit `ShardComplete` only. `ShardGone` → all local entries for this shard become `remoteRemoved` → `ShardComplete`. |
| **Output** | `Stream<SyncCandidate + ShardComplete>` |
| **Batching** | One DB query per shard (all local entries for this shard) |

`ShardComplete` is introduced here because this is the fan-out point: one `ShardResult` expands into N individual `SyncCandidate` events. Downstream stages need the boundary to know when all candidates for a shard have been emitted. `ShardComplete` carries the remote shard graph for Stage 11's shard RDF assembly.

**Classification logic** (in-memory diff, no intermediate `ResourceDelta` type):

| Local entry | Remote entry | → Direction |
|---|---|---|
| absent | present | `remoteOnly` (new from remote) |
| present, same clockHash | present, same clockHash | *skip* (no change) |
| present, different clockHash | present, different clockHash | `conflictCandidate` (needs merge) |
| present | absent | `localOnly` (exists locally, not in remote) |
| changed locally (`updatedAt > lastSyncTimestamp`) | absent | `localOnly` (remaining item, needs upload) |

> **⚠️ Implementation note**: The actual `SyncCandidate` classification in the current codebase is more complex than the table above. In particular it incorporates the configured **fetch strategy** (prefetch vs. on-request) for each resource type, which determines whether a `remoteOnly` candidate is fetched eagerly or deferred. This nuance must be preserved when porting the existing classification logic into this stage.

**Remaining items**: `localOnly` candidates emerge naturally from the diff itself: `getActiveIndexEntriesForShard` loads all active local entries for the shard; any resource with a local entry but no matching remote entry is classified as `localOnly`. No separate query is needed — shard membership is stored explicitly in `index_entries.shard_iri`.

**Resources in multiple shards**: A resource can appear in more than one shard. In the streaming pipeline there is **no guarantee** that one shard's resources are committed (Stage 9) before the next shard reaches Stage 4 — the pipeline is concurrent. Consequently the same resource may be classified as a sync candidate by multiple shards and processed (merged, uploaded, committed) more than once. This is **harmless**: CRDT merge is idempotent, and uploading the same merged result twice is a no-op from a correctness standpoint.

The critical invariant is: **a resource must be uploaded to remote (Stage 8) before any shard containing it is finalized and uploaded (Stage 10)**. This is guaranteed by the pipeline order — Stage 8 always completes before Stage 10 processes the `ShardComplete` boundary. After shard finalize, the shard's index on remote reflects the post-merge clockHash for this resource. Other shards that also contain this resource but were finalized *before* the merge may have a stale clockHash in their remote index entry — this is acceptable because the resource itself is the source of truth and the shard index is only used for change detection. The discrepancy self-corrects in the next sync cycle.

---

### Stage 5: Remote Resource Fetch (backend, remote I/O)

Download resource content for candidates that need remote data.

| | |
|---|---|
| **Owner** | Backend |
| **I/O** | Remote HTTP |
| **Input** | `Stream<SyncCandidate + ShardComplete>` |
| **Operation** | `remoteOnly` / `conflictCandidate` → batched download. `localOnly` / `remoteRemoved` → pass through. |
| **Output** | `Stream<FetchedCandidate(candidate, remoteSource: RdfGraphSource?) + ShardComplete>` |
| **Batching** | Chunked: max N concurrent downloads |

The downloaded content is delivered as `RdfGraphSource` — typically `EncodedRdfGraphSource` (raw bytes), but backends may also provide a `DecodedGraphSource` directly (e.g. a shard-dataset backend that extracts individual resource graphs from a downloaded TRiG file). **This stage does not decode unless it needs decoded itself.** Decoding is deferred to Stage 7 (CRDT Merge), which is the first stage that requires the parsed graph. Stage 7 handles both cases transparently via `RdfGraphSource.decode()`.

---

### Stage 6: Local Content Load (core, DB read)

Load local graph content for candidates that need the local version.

| | |
|---|---|
| **Owner** | Core |
| **I/O** | DB read |
| **Input** | `Stream<FetchedCandidate + ShardComplete>` |
| **Operation** | `conflictCandidate` / `localOnly` → load local content from DB. `remoteOnly` → pass through. |
| **Output** | `Stream<LoadedCandidate(candidate, remoteSource?, localSource?) + ShardComplete>` |
| **Batching** | Chunked DB reads |

Local content is loaded as `RdfGraphSource` (typically `BinaryGraphSource` — Jelly bytes from DB). **This stage does not decode.** Both `remoteSource` and `localSource` remain undecoded `RdfGraphSource` values; decoding is deferred to Stage 7.

---

### Stage 7: CRDT Merge (core, CPU)

Decode on demand, merge, encode for DB, pre-encode for upload. **Pure CPU — no I/O.**

| | |
|---|---|
| **Owner** | Core |
| **I/O** | None — pure CPU |
| **Input** | `Stream<LoadedCandidate + ShardComplete>` |
| **Output** | `Stream<MergeResult + ShardComplete>` |

**Per-direction logic**:

| Direction | Operation |
|---|---|
| `remoteOnly` | Decode `remoteSource` on demand → accept as merged graph → encode to Jelly for DB → pre-encode for upload |
| `localOnly` | Decode `localSource` on demand if needed → retain as merged graph; already Jelly for DB → pre-encode for upload |
| `conflictCandidate` | Decode both sides on demand → CRDT merge → encode merged graph to Jelly for DB → pre-encode for upload |
| `remoteRemoved` | Apply deletion semantics (tombstone / remove) |

**Decoding is on-demand**: `RdfGraphSource.decode()` is called only when the decoded graph is actually required. If an `RdfGraphSource` already is a `DecodedGraphSource`, no work is done.

**Upload pre-encoding** (OQ5 resolved): After producing `encodedForDb`, Stage 7 checks `backend.preferredUploadContentType`:
- `null` → `encodedForUpload = null`; the backend's Stage 8 `StreamTransformer` will handle encoding internally (e.g. single-file or shard-dataset backends that compose multiple resources into one file).
- `"application/x-jelly-rdf"` (same as DB format) → `encodedForUpload = encodedForDb`; zero extra CPU, same bytes reused.
- other content-type → encode `mergedGraph` into that format → `encodedForUpload = <encoded bytes>`.

`MergeResult` carries:
- `resourceIri`
- `mergedGraph: DecodedGraphSource` — the decoded merged result (always available at this point)
- `encodedForDb: BinaryGraphSource` — Jelly-encoded bytes for DB commit (no further CPU in Stage 9)
- `encodedForUpload: RdfGraphSource?` — pre-encoded bytes in the backend's preferred upload format, or `null` if the backend handles encoding itself
- `needsUpload`, `needsDbWrite` — flags
- `resourceEtag?` — from remote fetch, for upload conflict detection

---

### Stage 8: Upload (backend, remote I/O)

Push resources to remote where local state must be propagated.

| | |
|---|---|
| **Owner** | Backend |
| **I/O** | Remote HTTP |
| **Input** | `Stream<MergeResult + ShardComplete>` |
| **Operation** | `needsUpload == true` → upload to remote using `encodedForUpload` (pre-encoded by Stage 7) if non-null, otherwise encode from `mergedGraph` internally. Otherwise → pass through. |
| **Output** | `Stream<UploadResult(mergeResult, newRemoteEtag?) + ShardComplete>` |
| **Batching** | Chunked: max N concurrent uploads |

Stage 8 is a backend-owned `StreamTransformer`. The backend implementation decides how to use the `MergeResult` fields — simple file-per-resource backends stream `encodedForUpload` bytes directly; single-file or shard-dataset backends may buffer multiple `mergedGraph` values and compose one combined upload.

---

### Stage 9: DB Commit (core + backend, DB write)

Persist merge results to local DB. Backend state update happens atomically in the same transaction (crash safety).

| | |
|---|---|
| **Owner** | Core (with backend callback) |
| **I/O** | DB write (transaction) |
| **Input** | `Stream<UploadResult + ShardComplete>` |
| **Operation** | Chunked transaction: write documents + metadata + backend mirror callback. |
| **Output** | `Stream<CommitResult + ShardComplete>` |
| **Batching** | Chunked: 500–2000 items per transaction |

**Transaction contents** (per chunk):
1. Write/update resource document (raw bytes from `encodedForDb`)
2. Update resource-level sync metadata (clock, ETag, …)
3. **Backend callback**: `backend.onCommit(batch)` — backend updates mirror within the same transaction
4. **Index document handling**: If the committed resource is an index document → parse `idx:hasShard` → update `index_shards` table. This is how the Feedback Stage can later inject content indices with a pre-populated shard list.

---

### Stage 10: Shard Entry Load (core, DB read)

Triggered by `ShardComplete` boundary. Reads active index entries **and** the locally-stored shard document from the DB. Both are required as inputs to the CRDT merge in Stage 11. **Pure DB read — no CPU.**

| | |
|---|---|
| **Owner** | Core |
| **I/O** | DB read |
| **Input** | `ShardComplete` boundaries (pass all other events through) |
| **Operation** | Per `ShardComplete`: (1) `getActiveIndexEntriesForShard` — canonical local entry set; (2) `getDocument(shardDocumentIri)` — existing local shard graph (may be absent for new shards). Emit `LoadedShardEntries`. All other events pass through. |
| **Output** | `Stream<LoadedShardEntries + (other events pass-through)>` |
| **Batching** | Two DB queries per `ShardComplete` (entries + document) |

`LoadedShardEntries` carries `(shardIri, entries: List<IndexEntryWithIri>, localSource: BinaryGraphSource?, remoteShardGraph: DecodedGraphSource?, newEtag: String?)`. Parallel to `LoadedCandidate` from Stage 6.

---

### Stage 11: Shard CRDT Merge (core, CPU)

Assembles the new shard graph from local entries, then CRDT-merges with the remote shard, encodes for DB and pre-encodes for upload. **Exact parallel to Stage 7 (CRDT Merge) for resources. Pure CPU — no I/O.**

| | |
|---|---|
| **Owner** | Core |
| **I/O** | None — pure CPU |
| **Input** | `Stream<LoadedShardEntries + (other events pass-through)>` |
| **Operation** | Per `LoadedShardEntries`: (1) Build candidate shard `RdfGraph` from `entries` (OR-Set of `idx:containsEntry` triples + metadata). (2) Decode `localSource` on demand. (3) CRDT-merge candidate with `localSource` (to pick up HLC/clock state) and then with `remoteShardGraph` (OR-Set merge: entry sets unioned, LWW for metadata). (4) Encode merged result to Jelly for DB. (5) Pre-encode for upload per `backend.preferredUploadContentType` (same logic as Stage 7). All other events pass through. |
| **Output** | `Stream<MergedShard + (other events pass-through)>` |
| **Batching** | — |

`MergedShard` carries:
- `shardIri`
- `mergedGraph: DecodedGraphSource` — decoded merged shard (OR-Set of all surviving entries)
- `encodedForDb: BinaryGraphSource` — Jelly bytes for DB commit (no re-encode in Stage 13)
- `encodedForUpload: RdfGraphSource?` — pre-encoded bytes in the backend's preferred upload format, or `null` if the backend handles encoding itself
- `newEtag: String?` — from remote fetch, used for conditional PUT in Stage 12
- `needsUpload: bool` — false for 304 (not modified) and gone shards

Parallel to `MergeResult` from Stage 7.

---

### Stage 12: Shard Upload (backend, remote I/O)

Uploads merged shard documents to remote. **Exact parallel to Stage 8 (Upload) for resources.**

| | |
|---|---|
| **Owner** | Backend |
| **I/O** | Remote HTTP |
| **Input** | `Stream<MergedShard + (other events pass-through)>` |
| **Operation** | `needsUpload == true` → upload to remote using `encodedForUpload` (pre-encoded by Stage 11) if non-null, otherwise encode from `mergedGraph` internally → conditional PUT using `newEtag`. On 412 Precondition Failed: surface as conflict (shard changed between Stage 2 fetch and now — next sync cycle corrects). Other events pass through. |
| **Output** | `Stream<UploadedShard(shardIri, newRemoteEtag?) + (other events pass-through)>` |
| **Batching** | Chunked: max N concurrent uploads (same limit as Stage 8) |

Stage 12 is a backend-owned `StreamTransformer`, exact parallel to Stage 8.

---

### Stage 13: Shard DB Commit (core, DB write)

Persists the merged shard document and its remote ETag to the DB. **Exact parallel to Stage 9 (DB Commit) for resources.**

| | |
|---|---|
| **Owner** | Core |
| **I/O** | DB write (transaction) |
| **Input** | `Stream<UploadedShard + (other events pass-through)>` |
| **Operation** | Chunked transaction per batch: (1) write shard document to `documents` table using `encodedForDb` bytes (type = `IdxShard`); (2) persist new remote ETag to `remote_sync_state`. Other events pass through. Flush remaining buffer on `PhaseComplete`. |
| **Output** | `Stream<ShardCommitResult + (other events pass-through)>` |
| **Batching** | Chunked: 500–2000 shards per transaction (same as Stage 9; shard documents are small but the pattern is uniform) |

---

### Stage 14: Feedback Stage (orchestration)

Receives `PhaseComplete` boundary and decides whether to re-inject, inject new indices, or close the pipeline.

| | |
|---|---|
| **Owner** | Core |
| **I/O** | DB read (index queries); Remote I/O (safety net only) |
| **Input** | `Stream<ShardCommitResult + PhaseComplete>` (from Stage 13) |
| **Operation** | React to `PhaseComplete` event. Inject new `SyncInput` into `inputController`, or close it. |
| **Output** | Side effect: one item added to `inputController`, or `inputController.close()` |

**Logic:**

The Feedback Stage reacts to exactly one `PhaseComplete` per pipeline pass. It derives the current phase from `PhaseComplete.source` — no internal phase state needed. It always injects at most **one** `SyncInput` — never multiple.

```
on PhaseComplete(source, processedShardCount, zeroShardIndices):

  // Safety net: re-inject indices that had no shards
  if zeroShardIndices.isNotEmpty:
    if source.retryCount > 4 → ERROR("Indices have no shards after retries: {zeroShardIndices}")
    for iri in zeroShardIndices:
      fetchAndParseIndexDocument(iri)  // conditional GET → hasShard → index_shards
    inputController.add(SyncInput(zeroShardIndices, retryCount: source.retryCount + 1))
    return

  isIoiPhase = source.indexIris == [ioiIri]

  if isIoiPhase:
    currentIoiClockHash = db.getDocument(ioiDocumentIri).clockHash
    ioiChanged = currentIoiClockHash != source.ioiClockHashSnapshot
    if ioiChanged:
      if source.retryCount > 4 → ERROR("IoI unstable after retries")
      // Snapshot the new clock hash so the next iteration can detect further changes
      inputController.add(SyncInput([ioiIri],
          retryCount: source.retryCount + 1,
          ioiClockHashSnapshot: currentIoiClockHash))
    else:
      allIndices = queryAllIndicesFromDb()  // FullIndex + subscribed GroupIndex
      if allIndices.isEmpty:
        inputController.close()
      else:
        inputController.add(SyncInput(allIndices))
  else:
    // Content phase complete
    inputController.close()
```

**"IoI changed" detection (OQ3 resolved)**: `SyncInput` for the IoI phase carries `ioiClockHashSnapshot` — the CRDT clock hash of the IoI document read from the `documents` table at the moment of injection. After the iteration, Feedback Stage reads the current clock hash of the IoI document from the `documents` table. If it differs from the snapshot, the IoI document was CRDT-merged with new remote content (e.g. new `idx:hasShard` entries) → re-inject. No `index_shards` snapshot needed; the CRDT clock hash captures any change to the document.

---

## Boundary Elements

Two boundary types flow inline with data events:

```dart
sealed class Boundary { const Boundary(); }

/// All resources in this shard have been emitted / processed.
/// Introduced by Stage 4 (Change Detection) after the 1:N fan-out.
class ShardComplete extends Boundary {
  final IriTerm shardIri;
  /// The parsed remote shard graph for CRDT merging in Stage 11 (Shard CRDT Merge).
  /// Null for 304 (not modified) and gone shards — no remote merge needed.
  final DecodedGraphSource? remoteShardGraph;
  const ShardComplete(this.shardIri, {this.remoteShardGraph});
  /// The new ETag from the remote fetch (for persisting after shard finalize).
  final String? newEtag;
}

/// All shards of this SyncInput batch have been emitted / processed.
/// Signals the end of a complete pipeline pass.
class PhaseComplete extends Boundary {
  final SyncInput source;
  final int processedShardCount;
  /// Indices from the batch that had 0 shards (safety-net candidates).
  final List<IriTerm> zeroShardIndices;
  const PhaseComplete(this.source, this.processedShardCount, {this.zeroShardIndices = const []});
}
```

Stages that react to a boundary wrap it in their own typed event. Stages that don't care pass it through unchanged:

```dart
sealed class ChangeDetectionEvent { const ChangeDetectionEvent(); }
class SyncCandidateEvent extends ChangeDetectionEvent { /* ... */ }
class ChangeDetectionBoundary extends ChangeDetectionEvent {
  final Boundary boundary;
  const ChangeDetectionBoundary(this.boundary);
}
```

### What boundaries enable

| Boundary | Consumer | Behavior |
|---|---|---|
| `ShardComplete` | Stage 9 | May flush commit buffer |
| `ShardComplete` | Stage 10 | Triggers shard entry + document load from DB |
| `PhaseComplete` | Stage 9 | Flush remaining resource commit buffer |
| `PhaseComplete` | Stage 13 | Flush remaining shard commit buffer |
| `PhaseComplete` | Stage 14 | Triggers re-injection, index discovery, or close |

## Data Representation: RdfGraphSource

No stage decodes or encodes preemptively. Data flows through the pipeline in whatever format it naturally arrives in, and is only decoded where the decoded form is actually needed.

```
RdfGraphSource
├── EncodedRdfGraphSource  (raw bytes, not decoded)
│   ├── TextGraphSource    (Turtle, JSON-LD, N-Triples, …)
│   └── BinaryGraphSource  (Jelly, CBOR-LD, …)
└── DecodedGraphSource     (decoded graph, optionally preserves original encoded form)
```

`DecodedGraphSource` preserves the original `EncodedRdfGraphSource` so downstream I/O stages can use raw bytes directly (no re-encoding).

| Source | Format in pipeline | Decoded by |
|---|---|---|
| Remote shard (HTTP 200) | `EncodedRdfGraphSource` | Stage 3 (Shard Parse) |
| Remote resource (HTTP 200) | `EncodedRdfGraphSource` | Stage 7 (CRDT Merge) |
| Local DB (Jelly bytes) | `BinaryGraphSource` | Stage 7 (Merge), or not at all (fast-path upload) |

**Key behaviors:**
- **Remote data** is always decoded by Stage 7 — it needs typeIri, clock, shard assignments to process the resource. Merge produces a `DecodedGraphSource` with `originalSource` in the DB's storage format (e.g. Jelly). Commit writes `originalSource` bytes directly — no CPU.
- **Local data for upload** (localOnly fast path): Fetch stage loads raw bytes from DB as `BinaryGraphSource`. If Merge can determine metadata from index entries alone, it passes the `BinaryGraphSource` through without decoding — Upload sends original bytes directly.
- **Conflict data**: Both sides fully decoded for CRDT merge. Merge encodes the result to DB format.

**Prerequisite**: All relevant codecs (especially Jelly) must be registered with `rdf_core` at `SyncEngine` initialization.

## Pipeline Composition

No orchestrator class — the pipeline is the composition of stream transforms:

```dart
final pipeline = shardResolution(db)               // Stage 1:  Stream<ShardRef + PhaseComplete>
    .transform(shardFetch(backend))                 // Stage 2:  Stream<FetchedShard>
    .transform(shardParse())                        // Stage 3:  Stream<ShardResult>
    .transform(changeDetection(db, lastSync))       // Stage 4:  Stream<SyncCandidate + ShardComplete>
    .transform(remoteFetch(backend))                // Stage 5:  Stream<FetchedCandidate>
    .transform(localLoad(db))                       // Stage 6:  Stream<LoadedCandidate>
    .transform(crdtMerge(merger))                   // Stage 7:  Stream<MergeResult>
    .transform(upload(backend))                     // Stage 8:  Stream<UploadResult>
    .transform(dbCommit(db, backend))               // Stage 9:  Stream<CommitResult>
    .transform(shardEntryLoad(db))                  // Stage 10: Stream<LoadedShardEntries>
    .transform(shardCrdtMerge(merger))              // Stage 11: Stream<MergedShard>        (↔ Stage 7)
    .transform(shardUpload(backend))                // Stage 12: Stream<UploadedShard>      (↔ Stage 8)
    .transform(shardDbCommit(db))                   // Stage 13: Stream<ShardCommitResult>  (↔ Stage 9)
    .transform(feedback(inputController, db));      // Stage 14: Side effects → inputController
```

## Summary Table

| Stage | Name | Owner | I/O Type | Batching |
|---|---|---|---|---|
| 1 | Shard Resolution | Core | DB read | 2 queries per batch (SQLite-chunked) |
| 2 | Shard Fetch | Backend | Remote I/O | max N concurrent |
| 3 | Shard Parse | Core | CPU | — |
| 4 | Change Detection | Core | DB read | 1 query per shard |
| 5 | Remote Resource Fetch | Backend | Remote I/O | max N concurrent |
| 6 | Local Content Load | Core | DB read | chunked reads |
| 7 | CRDT Merge | Core | CPU | — |
| 8 | Upload | Backend | Remote I/O | max N concurrent |
| 9 | DB Commit | Core + Backend | DB write | 500–2000 per tx |
| 10 | Shard Entry Load | Core | DB read | 2 queries per shard (entries + document) |
| 11 | Shard CRDT Merge | Core | CPU | — |
| 12 | Shard Upload | Backend | Remote I/O | max N concurrent |
| 13 | Shard DB Commit | Core | DB write | 500–2000 per tx |
| 14 | Feedback | Core | DB read (+ Remote for safety net) | — |

**I/O type pattern**: DB read → Remote → CPU → DB read → Remote → DB read → CPU → Remote → DB write → DB read → CPU → Remote → DB write → orchestration

**Stage symmetry**: Stages 10–13 are the shard-document counterpart of Stages 6–9 (Local Content Load → CRDT Merge → Upload → DB Commit). Both paths share the same CRDT merger, the same upload mechanism, and the same `documents` table commit.

---

## Open Questions

### 1. IRI Storage ID in Pipeline Types

The current storage maps IRIs to integer IDs for efficient DB operations. Pipeline types should carry the pre-resolved ID alongside the `IriTerm` so DB stages (4, 6, 9) can use it directly without repeated lookups.

**Decision**: Use `typedef IriStorageId = dynamic;` as an opaque handle that flows through pipeline types. Each storage implementation assigns its own concrete type (`int` for Drift, or just `IriTerm` for in-memory/test storages). Only the storage layer that produced the value may cast it to its concrete type.

```dart
/// Opaque storage-internal identifier for an IRI. The concrete type is determined
/// by the storage implementation (e.g. [int] for Drift, [IriTerm] for in-memory).
/// Only the storage layer that produced this value may cast it to its concrete type.
typedef IriStorageId = dynamic;
```

This is a deliberate, contained exception to the no-`dynamic` guideline: `dynamic` appears only in this single typedef. Generics would propagate a type parameter through every pipeline type across all stages, which is a larger complexity cost than this one well-documented escape hatch.

### 2. Remaining Items: Shard Membership

**Resolved** by the existing implementation.

The `index_entries` table has a `shard_iri` column (integer FK to `sync_iris`) as part of its primary key `(shard_iri, resource_iri_id)`. Stage 4's "remaining items" detection therefore requires no separate query: `getActiveIndexEntriesForShard(shardIri)` loads **all** active local entries for the shard in one query (the same query already issued for the clockHash diff). Resources where `localClockHash != null && remoteClockHash == null` are `localOnly` candidates — they are present locally but absent from the remote shard document, so they need uploading.

### 3. IoI Change Detection Granularity — **Resolved**

**Resolution**: Use the CRDT clock hash of the IoI document stored in the `documents` table. `SyncInput` for the IoI phase carries `ioiClockHashSnapshot` (read from DB at injection time). At the Feedback Stage, one DB read of the IoI document's current clock hash suffices — if it differs from the snapshot, the IoI changed and must be re-injected.

This is strictly superior to the alternatives: it captures any CRDT-visible change to the IoI (not just `hasShard` additions), reuses data already maintained by the CRDT merge path (no extra storage), and requires only a single point-lookup at feedback time.

### 4. Shard-Dataset and Single-File Backend Validation

This pipeline is designed and validated for **file-per-resource** first (see [Implementation Scope](#implementation-scope)). Once the file-per-resource concept is finalized, we must separately design and validate how **shard-dataset** (TRiG) and **single-file** backends map onto this pipeline.

Key concerns:
- Shard-dataset backends download one file containing many resources — the backend's Stage 2/5 transforms must decompose this into individual `RdfGraphSource` items for the pipeline.
- Single-file backends aggregate all resources into one upload — Stage 8/12 must buffer and compose.
- Both modes currently rely on import tables and full-shard rebuild within the backend (see Implementation Scope).
- Verify that the streaming/boundary model (`ShardComplete`, `PhaseComplete`) works correctly when the backend internally aggregates or splits data.

### 5. Upload Pre-Encoding — **Resolved**

**Resolution**: Backends expose `String? preferredUploadContentType`. CPU stages 7 and 11 pre-encode the merged graph into this format and attach the result as `encodedForUpload: RdfGraphSource?` on `MergeResult` / `MergedShard`. The backend's upload `StreamTransformer` (Stages 8 and 12) uses these pre-encoded bytes directly — pure I/O, zero CPU at upload time.

**Format reuse**: If `preferredUploadContentType == "application/x-jelly-rdf"` (the DB format), `encodedForUpload = encodedForDb` — same bytes, no extra work. If a different format, Stage 7/11 encodes once. If `null`, the backend handles encoding internally (e.g. a single-file backend that composes many graphs into one file, or a shard-dataset backend building a TRiG document).

This applies symmetrically to all 15,000 individual resource documents (Stage 7→8) and shard documents (Stage 11→12) — encoding is fully separated from I/O in both paths.
