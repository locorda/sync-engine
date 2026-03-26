# 007: Feedback-Loop Sync Pipeline — Clean Stage Decomposition

## Goal

A **maximally decomposed streaming sync pipeline** where each stage has exactly one I/O type. Data flows through composed stream transforms — no external coordinator, no phase barriers. 

**Design maxims**: KISS, YAGNI, clarity over cleverness.

**Target**: Sync 15,000 resources in under 3 seconds for a **full initial sync** (empty local ← full remote, or full local → empty remote) against a **local directory backend** (no network RTT). With a real network backend the bottleneck shifts to network I/O; the 3 s target applies only to local-storage backends where disk I/O and CPU are the limiting factors.

## Core Model: Single Pipeline with Feedback Loop

A single pipeline processes all sync work. A **Feedback Stage** at the end injects new items into the input stream based on what was discovered. Meta-sync (IoI + IoGI → index documents) and content-sync (indices → data resources) are distinguished by *what gets injected*, not by separate pipeline instances.

```
inputController ──▶ [Pipeline Stages 1–13] ──▶ Feedback Stage ──┐
      ▲                                                          │
      └──────────────────────────────────────────────────────────┘
      (re-inject meta-indices or inject discovered content indices)
```

### Protocol Change: IoGI (Index of GroupIndices)

GroupIndex documents (e.g. `notes-2025-03-index`) must be synchronized before the content phase can reference them — the content phase needs their `idx:hasShard` entries to resolve shard IRIs. However, GroupIndex documents are not entries of the IoI (which only catalogs FullIndex documents). A new meta-index is required:

> **KK:** huh? The way you phrase it, it sounds pretty strange even though there is some truth to it: the job of the first phase (the "Meta-Sync") is, to make sure all (!) relevant index documents are synced, so that we can discover all shards in the content phase. But your phrasing is strange I think. Please reformulate

**IoGI** (Index of GroupIndices) is a FullIndex whose entries are GroupIndex instance documents. It is structurally identical to the IoI (catalogs FullIndex documents) and the IoGIT (catalogs GroupIndexTemplate documents). The IoGI is itself a FullIndex and therefore appears as an entry in the IoI's shards.

> **KK:** we need to mention here that core has  to automatically maintain this index, adding all group indices to it, like it adds all templates to the IoGIT and all full shards to the IoI (I can't remember how it does this precisely, you need to research - it might even work fully out-of-the box as soon as the index is configured - I don't know)

The IoGI is automatically added to `buildEffectiveConfig()` with `onRequest` fetch policy:

```dart
ResourceConfigData(
    typeIri: IdxGroupIndex.classIri,
    crdtMapping: Uri.parse('https://w3id.org/solid-crdt-sync/mappings/index-v1'),
    indices: [
      FullIndexData(
          localName: IndexNames.groupIndices,  // 'lcrd-group-indices'
          item: indexIndexItemConfig,
          rootResourceFetchPolicy: RootResourceFetchPolicy.onRequest)
    ]),
```

`onRequest` means that IoGI shard entries (= GroupIndex document IRIs) are discovered and their `clockHash` values are known, but the actual GroupIndex documents are only fetched for subscribed groups. This prevents downloading hundreds of group indices the user hasn't subscribed to.

Note: For aggregating backends (shard-dataset, single-file), `allResourcesAvailable` on `ShardContent` overrides `onRequest` for all resource types — including GroupIndex documents in IoGI shards. This is not IoGI-specific; it is the general mechanism described in [Backend-Driven Ingress](#proposed-007-change-backend-driven-ingress-allresourcesavailable).

> **KK:** why did you keep this paragraph? We did not talk about allResourcesAvailable yet, and there really is nothing special to it in this context, or do you disagree?

The IoGI IRI is a well-known constant (like `ioiIri`), derived from the same deterministic IRI generation as other meta-indices.

### Pipeline Trigger

The sync manager (manual, timer, or reconnect) triggers the pipeline with two values:
- **`lastSyncTimestamp`** — from DB, passed to Stage 4 for identifying locally-changed items (`updatedAt > lastSyncTimestamp`).
- **`ioiIri`** — the Index-of-Indices IRI, used as one of the initial seeds.
- **`iogiIri`** — the Index-of-GroupIndices IRI, used as the other initial seed.

### Sync Flow

1. **Seed**: read IoI + IoGI clock hashes from `documents` table → `inputController.add(SyncInput([ioiIri, iogiIri], metaIndexClockHashes: {ioiDocIri: ioiHash, iogiDocIri: iogiHash}))`
2. Stage 1 resolves all shards for the batch (here: IoI + IoGI). Shards flow through Stages 2–10. IoI shard resources are FullIndex index documents (indices for application-specific types, but also meta-indices like the IoI itself, IoGIT, IoGI, etc.). IoGI shard resources are GroupIndex instance documents — fetched only for subscribed groups (`onRequest`). For aggregating backends, `allResourcesAvailable` on `ShardContent` overrides this (see [Backend-Driven Ingress](#proposed-007-change-backend-driven-ingress-allresourcesavailable)).
3. Stage 9 commits index documents → extracts `idx:hasShard` → populates `index_shards` table. For GroupIndex documents committed here, their shard IRIs become known for the content phase.
4. `PhaseComplete` arrives at Feedback Stage (after all shards of both IoI and IoGI have been processed):
   - **IoI or IoGI changed** (current clock hash ≠ snapshot for either) → re-inject both with new snapshots: `inputController.add(SyncInput([ioiIri, iogiIri], retryCount: retryCount + 1, metaIndexClockHashes: {ioiDocIri: newIoiHash, iogiDocIri: newIogiHash}))`
   - **Both stable** → query content index IRIs from DB (all FullIndex + subscribed GroupIndex; or for aggregating backends: all FullIndex + all GroupIndex). Optionally let the backend inject additional index IRIs (see Feedback Stage). Inject as **one** batch: `inputController.add(SyncInput(allContentIndices))`
> **KK:** no, that is wrong. It is not all GroupIndex for aggregating backends. It is always subscribed GroupIndex. The singe-file & delta mode backends will insert additional shards on the PhaseComplete in Stage 2. They need to detect if it is meta or content, and if it is content add all shards that were not already processed, thus catching all GroupIndex shards they know about in addition. There is no hook for the backend to inject anything at feedback stage.
5. Stage 1 resolves all shards for all content indices in two bulk DB queries. Resources are now data (notes, tags, etc.)
> **KK:** Hmm, the order of the document is not so great - we don't know about stage 1 and wonder why two bulk queries (but it is for the shard iris, and for the etags)
6. `PhaseComplete` arrives → Feedback Stage detects content phase completion
7. `inputController.close()` → pipeline ends

### Loop Detection

Every `SyncInput` carries a `retryCount`. The Feedback Stage increments it on re-injection. If `retryCount > 4`, the pipeline aborts with an error — the meta-indices are oscillating and something is fundamentally wrong.

```dart
class SyncInput {
  final List<IriTerm> indexIris;
  final int retryCount;
  /// Clock hashes of the meta-index documents (IoI, IoGI) at the moment this
  /// meta-index-phase input was injected. Feedback Stage compares these against
  /// the DB values after the iteration to detect whether any meta-index changed.
  /// Null for content-phase inputs (no stability check needed).
  final Map<IriTerm, String>? metaIndexClockHashes;
  const SyncInput(this.indexIris, {this.retryCount = 0, this.metaIndexClockHashes});
}
```


Each `SyncInput` is a **batch**: all index IRIs that should be processed together. The Feedback Stage always injects exactly **one** `SyncInput` per phase — never multiple individual items. This guarantees that Stage 1 can resolve all shards for the entire batch in two bulk DB queries.

### Shard List Availability

Each installation creates its own documents for IoI, IoGI, and at least one shard for each on startup, populating the `index_shards` table. Note though that they have predictable IRIs so all installations will create the same documents and they will be crdt-merged during the sync. Stage 1 always finds at least the local shards. After the meta-index shards are synced and index documents are committed (Stage 9), the `index_shards` table is populated for all discovered indices *before* the Feedback Stage injects them. There is never a moment where Stage 1 encounters an index with unknown shards under normal operation.

**Safety net**: If Stage 1 finds 0 shards for any index within the batch (e.g. corrupted DB), it records those IRIs in the `PhaseComplete`'s `zeroShardIndices` list. The Feedback Stage detects this, fetches the affected index documents via conditional GET, parses `idx:hasShard`, populates `index_shards`, and re-injects those indices as a new `SyncInput` with `retryCount + 1`. Convergence is guaranteed by the retry limit.

## Design Principles

1. **Stream across stages, batch within stages**: Resources flow continuously from stage to stage — no phase barriers. Within a single stage, I/O operations are batched/chunked for efficiency (e.g. 10 concurrent downloads, 500 items per DB transaction).
2. **Backend as stream transform**: The backend is a function `Stream<Request> → Stream<Result>`. All backend-specific complexity (file-per-resource vs. file-per-shard vs. aggregated storage) is encapsulated inside the transform.
3. **Boundary elements for coordination**: Typed sentinel events (`ShardComplete`, `PhaseComplete`) flow inline with data — no external coordinator needed.
4. **CPU stages only do CPU; I/O stages only do I/O**: No parsing in I/O stages. `EncodedRdfGraphSource` (raw bytes/text) flows through I/O stages untouched. All decoding/encoding happens in CPU stages (3, 7, 11). **Backend-owned stages** (2, 5, 8, 12) maintain this separation *internally* via sub-pipelines (e.g. 8a CPU → 8b I/O) — from Core's perspective each backend stage is a single opaque `StreamTransformer`.
5. **Only sync what changed**: ETags for remote shards, `updatedAt > lastSyncTimestamp` for local. Unchanged items are never processed.
6. **Backend persists its own remote knowledge**: Each backend maintains its own view of the remote state via a transactional callback within Core's DB commit. Core never accesses mirror data directly.
> **KK:** that must be removed - this is not needed any more, it was a dead end
7. **Use the right stream operator per stage**: CPU stages (3, 7, 11) use `stream.map()` — synchronous, no controller, zero microtask overhead. 1:N async stages (1, 4) use `asyncExpand`. Concurrent and chunked I/O stages (2, 5, 6, 8, 9, 10, 12, 13) use custom `StreamTransformer`s with `sync: true` internal controllers, so results flow directly into downstream CPU stages without an extra microtask per item. `inputController` stays `sync: false` (added to from synchronous context). Each stage table includes an **Implementation** row specifying the chosen operator.
8. **Concurrency pools must implement explicit back-pressure**: Pool stages (2, 5, 8, 12) must call `subscription.pause()` when all N slots are occupied and `subscription.resume()` when a slot frees. This bounds in-flight items per pool to N regardless of backend speed — correct for local-directory backends where network RTT is zero. The `pause()`/`resume()` signal propagates automatically through upstream `stream.map()` and `asyncExpand()` stages without additional work. Pool stages must additionally **treat boundary events as flush points**: when a `ShardComplete` or `PhaseComplete` is dequeued from the input while in-flight operations are still pending, the boundary is buffered until all previously-dispatched operations have completed and emitted their results — only then is the boundary forwarded downstream. This preserves the ordering invariant that Stage 10 reads `index_entries` only after all per-shard resources have been emitted through Stage 9 and committed.

## Implementation Scope

**First implementation target: file-per-resource backend.**

This pipeline is initially designed and implemented for the **file-per-resource** storage model, where each synced resource maps 1:1 to a remote file (in file-per-resource mode, shard documents are index documents only — there are no aggregated resource uploads).

**Shard-dataset and single-file backends** are implemented self-contained within each backend (with helper services provided by Core). Their approach:
- **Stage 2 (download)**: Backend downloads the aggregate file (shard dataset or single-file) and emits one `ShardContent` per shard it contains. When all resource graphs for a shard were already downloaded as part of the aggregate file, the backend sets `allResourcesAvailable = true` on `ShardContent` — this disables `onRequest` deferral so Core processes all entries immediately, even for resource types the app didn't explicitly request. During the **content phase only**, extra shards not in Stage 1's `ShardRef` batch are additionally emitted with `shardStorageId = null` (see [Backend-Driven Ingress](#backend-driven-ingress-allresourcesavailable)). During the meta-index phase Stage 2 emits only the specifically requested IoI/IoGI shard events — no extra injection.
- **Stage 12 (upload assembly)**: For aggregating backends, Stage 12 must assemble complete dataset or single-file uploads. Unchanged resources not already in the Stage 12 accumulator are fetched from Core's `documents` table. No import tables or mirror DB required — Core's DB is the single source of truth for unchanged resource graphs.

Core's pipeline stages remain unchanged; all backend-specific aggregation complexity stays inside the backend's stream transforms.

---

## Backend-Driven Ingress: `allResourcesAvailable`

Aggregating backends (shard-dataset, single-file, delta-file) download multiple resources in a single HTTP response. When this happens, the backend must signal to Core that **all resources for a shard are already available locally**, so the pipeline processes them all regardless of the application's configured fetch policy.

`ShardContent` (Stage 2's output for HTTP 200 responses) carries a flag:

```dart
class ShardContent extends FetchedShard {
  final IriTerm shardIri;

  /// Storage-internal identifier for this shard, or `null` if Stage 1 did not
  /// know about this shard (proactively injected during the **content phase** by
  /// an aggregating backend that downloaded it as part of a larger aggregate file).
  /// Must never be `null` during the meta-index phase — only the specifically
  /// requested IoI/IoGI shards are emitted then.
  /// Stage 4 handles `null` by upserting `shardIri` into `sync_iris` to obtain
  /// an `IriStorageId`; the new shard has 0 local entries so all remote entries
  /// are `remoteOnly`.
  final IriStorageId? shardStorageId;

  final RdfGraphSource source; // shard metadata (default graph)
  final String newEtag;

  /// When `true`, the backend has pre-fetched ALL resource graphs for this shard
  /// (e.g., from a dataset file). Core MUST override fetch policy and process
  /// all entries — no deferral for `onRequest` resources.
  ///
  /// The actual resource graphs are served by the backend's Stage 5
  /// from its internal cache; this flag only affects Core's Stage 4 classification.
  final bool allResourcesAvailable;

  const ShardContent(
    this.shardIri, this.shardStorageId, this.source, this.newEtag, {
    this.allResourcesAvailable = false,
  });
}
```

This flag flows through the pipeline:

- **Stage 2 (backend)**: Sets `allResourcesAvailable = true` when the shard's data came from an aggregate download (dataset file, single file). Stores per-resource named graphs in its internal cache (shared with Stage 5 via dependency injection).
- **Stage 3 (Core CPU)**: Propagates the flag to `ParsedShard`.
- **Stage 4 (Core DB read)**: When `allResourcesAvailable` is `true`, overrides the configured fetch policy for ALL entries in this shard to `prefetch`. Every `remoteOnly` resource is classified and emitted — none are deferred. Unchanged resources (same `clockHash`) are still skipped.
- **Stage 5 (backend)**: Serves resource graphs from its internal cache (populated during Stage 2). No HTTP requests. Evicts the cache on `ShardComplete`.

**This is not specific to any particular index type.** The flag applies uniformly to IoI shards, IoGI shards, and content shards. For example, when a single-file backend sets `allResourcesAvailable` on IoGI shards, all GroupIndex documents are processed despite `onRequest` — because the data was already downloaded. The same mechanism ensures content resources with `onRequest` are processed when their shard was fetched as part of a dataset.

For `ShardNotModified` (304) and `ShardGone` (404/410), the flag is not set — no resource data was downloaded.

See [010](010-review-backend-storage-models.md) for the detailed analysis of how `allResourcesAvailable` guarantees Core's DB completeness and enables upload completeness strategies.

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
| **Implementation** | `asyncExpand` — 1:N async; O(1) events per sync cycle |
| **Input** | `Stream<SyncInput>` — each element contains `List<IriTerm>` |
| **Operation** | Per `SyncInput`: (1) bulk query on `index_shards WHERE index_iri IN (…)` for **all** index IRIs in the batch — chunked at SQLite's 999-variable limit if needed; the storage layer provides the `IriStorageId` for each shard IRI directly (for Drift: `index_shards.shard_iri` is already the `sync_iris.id` integer FK, no extra join). (2) `SELECT shard_iri, etag FROM remote_sync_state WHERE shard_iri IN (…)` for **all** shard IRIs from step (1). Emit one `ShardRef` per shard (carrying `shardStorageId: IriStorageId`), then one `PhaseComplete` at the end. |
| **Output** | `Stream<ShardRef(indexIri, shardIri, shardStorageId: IriStorageId, storedEtag?) + PhaseComplete>` |
| **Batching** | 2 DB queries total per `SyncInput` (with SQLite chunking at >999 IRIs) |

Index IRIs with no rows in the result are collected in `PhaseComplete.zeroShardIndices`. The Feedback Stage handles these as a safety net (see [Feedback Stage](#stage-14-feedback-stage-orchestration)).

> **ID pass-through**: `ShardRef` carries `shardStorageId: IriStorageId` — the storage-internal identifier for the shard IRI (opaque; consistent with OQ1). This propagates through `FetchedShard` and `ShardResult` so Stage 4 can query `index_entries` without a runtime IRI→ID lookup, and through `ShardComplete` so Stage 10 can call `getActiveIndexEntriesForShard(shardStorageId)`. Resource-level events (`SyncCandidate`, `FetchedCandidate`, `MergeResult`) carry their own resource `IriStorageId`s (see OQ1) — a separate concern. No IRI→ID lookup table and no IRI→ID cache is needed anywhere in the pipeline.

---

### Stage 2: Shard Fetch (backend, remote I/O)

Batched/chunked conditional GETs for shard documents.

| | |
|---|---|
| **Owner** | Backend |
| **I/O** | Remote HTTP |
| **Implementation** | Custom `StreamTransformer` — concurrency pool; `sync: true` internal controller; pauses upstream when all N slots occupied |
| **Input** | `Stream<ShardRef>` |
| **Operation** | Conditional GET (`If-None-Match: storedEtag`). No ETag → unconditional GET. |
| **Output** | `Stream<FetchedShard>` |
| **Batching** | Chunked: max N concurrent HTTP requests (e.g. 10) |

`FetchedShard` variants:
- **`ShardContent(shardIri, shardStorageId: IriStorageId?, source: RdfGraphSource, newEtag)`** — 200: shard data in backend-specific format (Turtle, Jelly, …), or already decoded if the backend parsed it for its own purposes (in which case the encoded original may also be passed through if available). `shardStorageId` is `null` for shards that were not in Stage 1's batch (proactively injected **during the content phase only** by aggregating backends that downloaded extra shards from a single aggregate file); non-null for shards Stage 1 explicitly requested. During the meta-index phase `shardStorageId` is always non-null.
- **`ShardNotModified(shardIri, shardStorageId: IriStorageId)`** — 304: shard unchanged (always from a Stage 1 `ShardRef`).
- **`ShardGone(shardIri, shardStorageId: IriStorageId)`** — 404/410: shard removed (always from a Stage 1 `ShardRef`).

---

### Stage 3: Shard Parse (core, CPU)

Decode fetched shard documents and extract resource entries.

| | |
|---|---|
| **Owner** | Core |
| **I/O** | None — pure CPU |
| **Implementation** | `stream.map()` — synchronous, no controller, zero microtask overhead |
| **Input** | `Stream<FetchedShard>` |
| **Operation** | Decode `RdfGraphSource` → extract entries. 304/404 → pass through. |
| **Output** | `Stream<ShardResult>` |

One `ShardResult` per shard — no `ShardComplete` here. Stage 4 introduces `ShardComplete` after the entry fan-out.

`ShardResult` variants (all carry `shardStorageId: IriStorageId` from `FetchedShard`):
- **`ParsedShard(shardIri, shardStorageId, entries: List<ShardEntry>, decodedGraph: DecodedGraphSource, newEtag)`** — decoded entries + full parsed graph from 200 response. The `decodedGraph` is carried through to Stage 11 for CRDT-correct shard rebuild.
- **`ShardNotModified(shardIri, shardStorageId)`** — pass-through from Stage 2.
- **`ShardGone(shardIri, shardStorageId)`** — pass-through, shard removed remotely.

Each `ShardEntry` carries at minimum `(resourceIri, clockHash)`.

---

### Stage 4: Change Detection (core, DB read)

Compare remote shard entries against local `index_entries` to classify each resource for sync. This stage performs the 1:N fan-out (one `ShardResult` → N `SyncCandidate` events) and introduces `ShardComplete` at the end of each shard.

| | |
|---|---|
| **Owner** | Core |
| **I/O** | DB read (`index_entries` table) |
| **Implementation** | `asyncExpand` — 1:N fan-out; O(shards) ≈ 50 events per cycle |
| **Input** | `Stream<ShardResult>` |
| **Operation** | Per `ParsedShard`: if `shardStorageId == null` (proactively-injected shard unknown to Stage 1), UPSERT `shardIri` into `sync_iris` to obtain `shardStorageId`; the new shard has 0 local entries so the diff yields all remote entries as `remoteOnly` (no local-entries query needed). Otherwise: (1) load local entries from `index_entries` using `shardStorageId` (no IRI→ID lookup), (2) in-memory diff by `clockHash` — local entries absent from remote with `updatedAt > lastSyncTimestamp` classify as `localOnly` (no extra query needed; see "Remaining items" below), (3) emit N `SyncCandidate` events, (4) emit `ShardComplete(shardStorageId)`. Per `ShardNotModified`: (1) load local entries using `shardStorageId`, (2) emit `localOnly` for locally-changed entries (`updatedAt > lastSyncTimestamp`), (3) emit `ShardComplete(shardStorageId)`. `ShardGone` → load local entries, emit all as `remoteRemoved`, emit `ShardComplete`. |
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

> **⚠️ Implementation note**: The actual `SyncCandidate` classification in the current codebase is more complex than the table above. In particular it incorporates the configured **fetch strategy** (prefetch vs. on-request) for each resource type, which determines whether a `remoteOnly` candidate is fetched eagerly or deferred. When `allResourcesAvailable` is set on the `ParsedShard`, the fetch policy is overridden to `prefetch` for all entries (see [Backend-Driven Ingress](#proposed-007-change-backend-driven-ingress-allresourcesavailable)). This nuance must be preserved when porting the existing classification logic into this stage.

**Remaining items**: `localOnly` candidates emerge naturally from the diff itself: `getActiveIndexEntriesForShard` loads all active local entries for the shard; any resource with a local entry but no matching remote entry is classified as `localOnly`. No separate query is needed — shard membership is stored explicitly in `index_entries.shard_iri`.

**Resources in multiple shards**: A resource can appear in more than one shard (e.g. in a FullIndex and a GroupIndex simultaneously, or temporarily in two GroupIndex shards after being moved between groups). In the streaming pipeline there is **no guarantee** that one shard's resources are committed (Stage 9) before the next shard reaches Stage 4 — the pipeline is concurrent. The same resource may therefore be classified as a sync candidate by multiple shards in the same cycle.

This is correct by construction: the shard that has the resource **remotely** classifies it as `remoteOnly` or `conflictCandidate`, fetches it, merges, and uploads the merged result. A shard that has the resource only **locally** classifies it as `localOnly` and uploads the local-only state. If both run concurrently, the local-only upload is overwritten by the merged upload. The final remote resource state is always the CRDT-merged result. Temporary duplicate index entries (the resource listed in both shards' remote index documents) self-correct in the next sync cycle as the index CRDT merges propagate.

> **KK** no, not for shard dataset backends. Then we will have different states in different files. not good.

The critical invariant is: **a resource must be uploaded to remote (Stage 8) before any shard containing it is finalized and uploaded (Stage 10)**. This is guaranteed by the pipeline order — Stage 8 always completes before Stage 10 processes the `ShardComplete` boundary. After shard finalize, the shard's index on remote reflects the post-merge clockHash for this resource. Other shards that also contain this resource but were finalized *before* the merge may have a stale clockHash in their remote index entry — this is acceptable because the resource itself is the source of truth and the shard index is only used for change detection. The discrepancy self-corrects in the next sync cycle.

---

### Stage 5: Remote Resource Fetch (backend, remote I/O)

Download resource content for candidates that need remote data.

| | |
|---|---|
| **Owner** | Backend |
| **I/O** | Remote HTTP |
| **Implementation** | Custom `StreamTransformer` — concurrency pool; `sync: true` internal controller; pauses upstream when all N slots occupied |
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
| **Implementation** | Custom `StreamTransformer` — chunked DB read; `sync: true` internal controller |
| **Input** | `Stream<FetchedCandidate + ShardComplete>` |
| **Operation** | `conflictCandidate` / `localOnly` → load local content from DB. `remoteOnly` → pass through. |
| **Output** | `Stream<LoadedCandidate(candidate, remoteSource?, localSource?) + ShardComplete>` |
| **Batching** | Chunked: 500 items per `getDocumentsByIri()` IN-query (same bound as Stage 9; avoids SQLite variable limit) |

Local content is loaded as `RdfGraphSource` (typically `BinaryGraphSource` — Jelly bytes from DB). **This stage does not decode.** Both `remoteSource` and `localSource` remain undecoded `RdfGraphSource` values; decoding is deferred to Stage 7.

---

### Stage 7: CRDT Merge (core, CPU)

Decode on demand, merge, encode for DB. **Pure CPU — no I/O.**

| | |
|---|---|
| **Owner** | Core |
| **I/O** | None — pure CPU |
| **Implementation** | `stream.map()` — synchronous, no controller, zero microtask overhead |
| **Input** | `Stream<LoadedCandidate + ShardComplete>` |
| **Output** | `Stream<MergeResult + ShardComplete>` |

> **Isolate note**: Stage 7's synchronous CPU work per resource must remain sub-millisecond to keep the event loop responsive to concurrent I/O callbacks. If heavy documents make this a bottleneck, Stage 7 can be moved to a dedicated isolate — serializing `LoadedCandidate`/`MergeResult` across the port boundary — without changing any other stage or the pipeline architecture.

**Per-direction logic**:

| Direction | Operation |
|---|---|
| `remoteOnly` | Decode `remoteSource` on demand → accept as merged graph → encode to Jelly for DB |
| `localOnly` | Decode `localSource` on demand if needed → retain as merged graph; already Jelly for DB |
| `conflictCandidate` | Decode both sides on demand → CRDT merge → encode merged graph to Jelly for DB |
| `remoteRemoved` | Apply deletion semantics (tombstone / remove) |

**Decoding is on-demand**: `RdfGraphSource.decode()` is called only when the decoded graph is actually required. If an `RdfGraphSource` already is a `DecodedGraphSource`, no work is done.

`MergeResult` carries:
- `resourceIri`
- `mergedGraph: DecodedGraphSource` — the decoded merged result (always available at this point)
- `encodedForDb: BinaryGraphSource` — Jelly-encoded bytes for DB commit (no further CPU in Stage 9)
- `needsUpload`, `needsDbWrite` — flags
- `resourceEtag?` — from remote fetch, for upload conflict detection

Stage 7 does **not** pre-encode for upload — encoding for the wire format is the backend's responsibility (see [OQ5 resolution](#5-upload-encoding--resolved)).

---

### Stage 8: Upload (backend, remote I/O)

Push resources to remote where local state must be propagated.

| | |
|---|---|
| **Owner** | Backend |
| **I/O** | Remote HTTP |
| **Implementation** | Custom `StreamTransformer` — concurrency pool; `sync: true` internal controller; pauses upstream when all N slots occupied |
| **Input** | `Stream<MergeResult + ShardComplete>` |
| **Operation** | `needsUpload == true` → encode and upload to remote (see sub-pipeline below). Otherwise → pass through. |
| **Output** | `Stream<UploadResult(mergeResult, newRemoteEtag?) + ShardComplete>` |
| **Batching** | Chunked: max N concurrent uploads |

Stage 8 is a backend-owned `StreamTransformer`. Backends typically implement it as an **internal sub-pipeline** to maintain CPU/I/O separation:

```
Backend Stage 8 — internal sub-pipeline:
    8a (CPU): encode mergedGraph → wire bytes (format serialization,
              IRI transposition, relative-path rewriting, metadata injection, etc.)
    8b (I/O): HTTP PUT wire bytes
```

From Core's perspective, Stage 8 is a single opaque `StreamTransformer`. The internal decomposition is the backend's concern. File-per-resource backends (e.g. Solid) encode + PUT one resource per event. Single-file or shard-dataset backends may buffer multiple `mergedGraph` values and compose one combined upload on `ShardComplete` or `PhaseComplete`.

---

### Stage 9: DB Commit (core, DB write)

Persist merge results to local DB.

| | |
|---|---------|
| **Owner** | Core |
| **I/O** | DB write (transaction) |
| **Implementation** | Custom `StreamTransformer` — chunked DB write; `sync: true` internal controller |
| **Input** | `Stream<UploadResult + ShardComplete>` |
| **Operation** | Chunked transaction: write documents + metadata. |
| **Output** | `Stream<CommitResult + ShardComplete>` |
| **Batching** | Chunked: 500 items per transaction |

**Transaction contents** (per chunk):
1. Write/update resource document (raw bytes from `encodedForDb`)
2. Update resource-level sync metadata (clock, ETag, …)
3. **Index document handling**: If the committed resource is an index document → extract `idx:hasShard` → update `index_shards` table. This is how the Feedback Stage can later inject content indices with a pre-populated shard list.
4. **`index_entries` clockHash update**: For each committed resource, upsert the corresponding `index_entries` row with the **post-merge** clockHash (extracted from the merged document's `sync:crdtClockHash` literal via `IndexManager.prepareIndexEntryWrites()`). This must happen in the same transaction as step 1 — atomicity guarantees that the stored `index_entries.clockHash` always reflects the actual committed state. A stale clockHash in `index_entries` would cause spurious `conflictCandidate` classifications on the next sync cycle. This step is already implemented correctly in `_commitBatchChunk()` / `_DeferredBatchCommit` and must be preserved in any pipeline reimplementation.

---

### Stage 10: Shard Entry Load (core, DB read)

Triggered by `ShardComplete` boundary. Reads active index entries **and** the locally-stored shard document from the DB. Both are required as inputs to the CRDT merge in Stage 11. **Pure DB read — no CPU.**

| | |
|---|---|
| **Owner** | Core |
| **I/O** | DB read |
| **Implementation** | Custom `StreamTransformer` — boundary-reactive pass-through; `sync: true` internal controller |
| **Input** | `ShardComplete` boundaries (pass all other events through) |
| **Operation** | Per `ShardComplete(shardStorageId, shardIri)`: (1) `getActiveIndexEntriesForShard(shardStorageId)` — canonical local entry set (integer key, no IRI→ID lookup); (2) `getDocument(shardDocumentIri)` — existing local shard graph (may be absent for new shards). `remoteShardGraph` and `newEtag` are propagated directly from the `ShardComplete` boundary event (originating in Stage 2's HTTP response, carried via Stages 3 and 4) — no additional DB fetch for these. Emit `LoadedShardEntries`. All other events pass through. |
| **Output** | `Stream<LoadedShardEntries + (other events pass-through)>` |
| **Batching** | Two DB queries per `ShardComplete` (entries + document) |

`LoadedShardEntries` carries `(shardIri, shardStorageId: IriStorageId, entries: List<IndexEntryWithIri>, localSource: BinaryGraphSource?, remoteShardGraph: DecodedGraphSource?, newEtag: String?)`. `remoteShardGraph` and `newEtag` originate in Stage 2's HTTP response and are carried inline via the `ShardComplete` boundary — Stage 10 does not fetch them from the DB. Parallel to `LoadedCandidate` from Stage 6.

---

### Stage 11: Shard CRDT Merge (core, CPU)

Assembles the new shard graph from local entries, then CRDT-merges with the remote shard, encodes for DB. **Exact parallel to Stage 7 (CRDT Merge) for resources. Pure CPU — no I/O.**

| | |
|---|---|
| **Owner** | Core |
| **I/O** | None — pure CPU |
| **Implementation** | `stream.map()` — synchronous, no controller, zero microtask overhead |
| **Input** | `Stream<LoadedShardEntries + (other events pass-through)>` |
| **Operation** | Per `LoadedShardEntries`: (1) Build candidate shard `RdfGraph` from `entries` (OR-Set of `idx:containsEntry` triples + metadata). (2) Decode `localSource` on demand. (3) CRDT-merge candidate with `localSource` (to pick up HLC/clock state) and then with `remoteShardGraph` (OR-Set merge: entry sets unioned, LWW for metadata). (4) Encode merged result to Jelly for DB. All other events pass through. |
| **Output** | `Stream<MergedShard + (other events pass-through)>` |
| **Batching** | — |

`MergedShard` carries:
- `shardIri`
- `mergedGraph: DecodedGraphSource` — decoded merged shard (OR-Set of all surviving entries)
- `encodedForDb: BinaryGraphSource` — Jelly bytes for DB commit (no re-encode in Stage 13)
- `newEtag: String?` — from remote fetch, used for conditional PUT in Stage 12
- `needsUpload: bool` — false for 304 (not modified) and gone shards

Parallel to `MergeResult` from Stage 7. Stage 11 does **not** pre-encode for upload — this is the backend's responsibility in Stage 12 (see [OQ5 resolution](#5-upload-encoding--resolved)). The shard document building logic (OR-Set merge of entries, clock hash computation, `idx:hasShard` triple generation) should remain very close to the current implementation.

---

### Stage 12: Shard Upload (backend, remote I/O)

Uploads merged shard documents to remote. **Exact parallel to Stage 8 (Upload) for resources.**

| | |
|---|---|
| **Owner** | Backend |
| **I/O** | Remote HTTP |
| **Implementation** | Custom `StreamTransformer` — concurrency pool; `sync: true` internal controller; pauses upstream when all N slots occupied |
| **Input** | `Stream<MergedShard + (other events pass-through)>` |
| **Operation** | `needsUpload == true` → encode and upload to remote (see sub-pipeline below) → conditional PUT using `newEtag`. On 412 Precondition Failed: surface as conflict (shard changed between Stage 2 fetch and now — next sync cycle corrects). Other events pass through. |
| **Output** | `Stream<UploadedShard(shardIri, newRemoteEtag?) + (other events pass-through)>` |
| **Batching** | Chunked: max N concurrent uploads (same limit as Stage 8) |

Stage 12 is a backend-owned `StreamTransformer`, exact parallel to Stage 8. Same internal sub-pipeline pattern:

```
Backend Stage 12 — internal sub-pipeline:
    12a (CPU): encode mergedGraph → wire bytes (shard serialization,
               dataset assembly for aggregating backends, etc.)
    12b (I/O): HTTP PUT / conditional PUT
```

For aggregating backends (shard-dataset, single-file), Stage 12a additionally queries Core's `documents` table for unchanged resource graphs to assemble complete datasets — see [010](010-review-backend-storage-models.md) for details.

---

### Stage 13: Shard DB Commit (core, DB write)

Persists the merged shard document and its remote ETag to the DB. **Exact parallel to Stage 9 (DB Commit) for resources.**

| | |
|---|---|
| **Owner** | Core |
| **I/O** | DB write (transaction) |
| **Implementation** | Custom `StreamTransformer` — chunked DB write; `sync: true` internal controller |
| **Input** | `Stream<UploadedShard + (other events pass-through)>` |
| **Operation** | Chunked transaction per batch: (1) write shard document to `documents` table using `encodedForDb` bytes (type = `IdxShard`); (2) persist new remote ETag to `remote_sync_state`. Other events pass through. Flush remaining buffer on `PhaseComplete`. |
| **Output** | `Stream<ShardCommitResult + (other events pass-through)>` |
| **Batching** | Chunked: 500 shards per transaction (same as Stage 9) |

---

### Stage 14: Feedback Stage (orchestration)

Receives `PhaseComplete` boundary and decides whether to re-inject, inject new indices, or close the pipeline.

| | |
|---|---|
| **Owner** | Core |
| **I/O** | DB read (index queries); Remote I/O (safety net only) |
| **Implementation** | Stream `listen` on Stage 13 output — calls `inputController.add()` / `.close()` directly (no transformer) |
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

  isMetaIndexPhase = source.metaIndexClockHashes != null

  if isMetaIndexPhase:
    // Check stability of ALL meta-indices (IoI + IoGI)
    anyChanged = false
    newHashes = <IriTerm, String>{}
    for (docIri, snapshot) in source.metaIndexClockHashes!.entries:
      currentHash = db.getDocument(docIri).clockHash
      newHashes[docIri] = currentHash
      if currentHash != snapshot:
        anyChanged = true

    if anyChanged:
      if source.retryCount > 4 → ERROR("Meta-indices unstable after retries")
      // Re-inject BOTH meta-indices with updated snapshots
      inputController.add(SyncInput([ioiIri, iogiIri],
          retryCount: source.retryCount + 1,
          metaIndexClockHashes: newHashes))
    else:
      // Meta-indices stable → transition to content phase
      allIndices = queryAllContentIndicesFromDb()
      //   = all FullIndex IRIs (from IoI entries)
      //   + subscribed GroupIndex IRIs (from IoGI entries where group is subscribed)
      //
      // Feedback Stage always injects subscribed GroupIndex only — never all
      // GroupIndex IRIs. For single-file backends, unsubscribed GroupIndex
      // shards will be proactively injected by Stage 2 during the content
      // phase itself (as extra ShardContent events with shardStorageId = null).

      if allIndices.isEmpty:
        inputController.close()
      else:
        inputController.add(SyncInput(allIndices))
  else:
    // Content phase complete
    inputController.close()
```

**Meta-index stability detection (OQ3 resolved)**: `SyncInput` for the meta-index phase carries `metaIndexClockHashes` — a map of meta-index document IRIs (IoI, IoGI) to their CRDT clock hashes, read from the `documents` table at injection time. After the iteration, the Feedback Stage reads the current clock hashes from the `documents` table for each meta-index. If **any** hash differs from its snapshot, at least one meta-index was CRDT-merged with new remote content (e.g. new `idx:hasShard` entries, new GroupIndex instances) → re-inject both. Both meta-indices must be stable simultaneously for the content phase transition, because a change to the IoI could reveal new FullIndex documents whose discovery affects the IoGI (and vice versa via transitive index membership).

---

## Boundary Elements

Two boundary types flow inline with data events:

```dart
sealed class Boundary { const Boundary(); }

/// All resources in this shard have been emitted / processed.
/// Introduced by Stage 4 (Change Detection) after the 1:N fan-out.
class ShardComplete extends Boundary {
  final IriTerm shardIri;
  /// Storage-internal identifier for the shard IRI. Propagated from [ShardRef] so
  /// Stage 10 can call `getActiveIndexEntriesForShard(shardStorageId)` without an IRI→ID lookup.
  final IriStorageId shardStorageId;
  /// The parsed remote shard graph for CRDT merging in Stage 11 (Shard CRDT Merge).
  /// Null for 304 (not modified) and gone shards — no remote merge needed.
  final DecodedGraphSource? remoteShardGraph;
  /// The new ETag from the remote fetch (for persisting after shard finalize).
  final String? newEtag;
  const ShardComplete(this.shardIri, this.shardStorageId, {this.remoteShardGraph, this.newEtag});
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
final pipeline = inputController.stream
    .asyncExpand(shardResolution(db))               // Stage 1:  Stream<ShardRef + PhaseComplete>
    .transform(shardFetch(backend))                 // Stage 2:  Stream<FetchedShard>
    .transform(shardParse())                        // Stage 3:  Stream<ShardResult>
    .transform(changeDetection(db, lastSync))       // Stage 4:  Stream<SyncCandidate + ShardComplete>
    .transform(remoteFetch(backend))                // Stage 5:  Stream<FetchedCandidate>
    .transform(localLoad(db))                       // Stage 6:  Stream<LoadedCandidate>
    .transform(crdtMerge(merger))                   // Stage 7:  Stream<MergeResult>
    .transform(upload(backend))                     // Stage 8:  Stream<UploadResult>
    .transform(dbCommit(db))                        // Stage 9:  Stream<CommitResult>
    .transform(shardEntryLoad(db))                  // Stage 10: Stream<LoadedShardEntries>
    .transform(shardCrdtMerge(merger))              // Stage 11: Stream<MergedShard>        (↔ Stage 7)
    .transform(shardUpload(syncSupport))            // Stage 12: Stream<UploadedShard>      (↔ Stage 8)
    .transform(shardDbCommit(db))                   // Stage 13: Stream<ShardCommitResult>  (↔ Stage 9)
    .transform(feedback(inputController, db));      // Stage 14: Side effects → inputController
```

Backend stages (2, 5, 8, 12) need to share internal state (e.g. the per-shard resource cache populated in Stage 2 and consumed in Stage 5). The recommended pattern is `backend.createSyncSupport()` — the backend instantiates a single sync-scoped support object and uses it to create all its stage transforms: `.transform(syncSupport.shardFetch)`, `.transform(syncSupport.resourceFetch)`, etc. Core has no knowledge of this object.

> **KK** ok - so why didn't you update the dart code snipped above to show this pattern?

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
| 9 | DB Commit | Core + Backend | DB write | 500 per tx |
| 10 | Shard Entry Load | Core | DB read | 2 queries per shard (entries + document) |
| 11 | Shard CRDT Merge | Core | CPU | — |
| 12 | Shard Upload | Backend | Remote I/O | max N concurrent |
| 13 | Shard DB Commit | Core | DB write | 500 per tx |
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

### 3. Meta-Index Change Detection Granularity — **Resolved**

**Resolution**: Use the CRDT clock hash of each meta-index document (IoI, IoGI) stored in the `documents` table. `SyncInput` for the meta-index phase carries `metaIndexClockHashes` — a map of document IRIs to clock hashes (read from DB at injection time). At the Feedback Stage, one DB read per meta-index document suffices — if any hash differs from its snapshot, that meta-index changed and the entire meta-index phase must be re-injected.

Both IoI and IoGI must be stable simultaneously before transitioning to the content phase. This is because:
- A new IoI entry might add a new FullIndex whose entries affect IoGI (e.g. the IoGI itself is a FullIndex discovered through IoI)
- A changed IoGI might reveal previously unknown GroupIndex instances whose shards need processing

This approach is strictly superior to the alternatives: it captures any CRDT-visible change to the meta-indices (not just `hasShard` additions), reuses data already maintained by the CRDT merge path (no extra storage), and requires only point-lookups at feedback time.

### 4. Shard-Dataset and Single-File Backend Validation — **Resolved**

**Resolution**: Both aggregating backend modes map cleanly onto the pipeline via three mechanisms:

1. **Proactive Stage 2 injection (content phase only)**: During the content phase, when a backend downloads a single aggregate file containing more shards than Stage 1 requested, Stage 2 emits additional `ShardContent` events for those extra shards with `shardStorageId = null`. This must not happen during the meta-index phase — only specifically requested IoI/IoGI shards are emitted then. Stage 4 handles `null` via IRI UPSERT into `sync_iris`; the new shard has 0 local entries → all remote entries are `remoteOnly`.

2. **`allResourcesAvailable`**: Set to `true` on all `ShardContent` events from an aggregate download. Overrides the configured fetch policy so Stage 4 classifies all `remoteOnly` entries for immediate processing (no deferral). Stage 5 serves graphs from the backend's internal per-shard cache.

3. **Core DB Query for upload assembly**: Stage 12's CPU sub-stage queries Core's `documents` table to retrieve unchanged resources needed for dataset/single-file assembly. No import tables or mirror DB required. The `ShardComplete`/`PhaseComplete` boundary model works unchanged — extra proactively-injected shards simply appear as additional events before `PhaseComplete`.

   **Open detail (single-file / delta-file)**: These backends upload on `PhaseComplete` of the content phase and need Core helpers to gather all resource graphs at that point. Additionally, they must persist some remote state across sync cycles (e.g. a file ETag or version token) so Stage 2 can issue a conditional GET in the next cycle and detect whether the remote file changed. The precise API for both the bulk graph query and the remote-state storage is to be designed.

### 5. Upload Encoding — **Resolved**

**Resolution**: `preferredUploadContentType` and `encodedForUpload` are **removed** from the Core–backend contract (see [009 rationale](009-backend-storage-modes.md)). Even the simplest file-per-resource backends (e.g. Solid) need backend-specific CPU work before the network write — IRI transposition, relative-path rewriting, Solid metadata injection. Core cannot anticipate this. For aggregating backends, Core cannot help at all (dataset assembly, format composition).

Instead, each backend's upload stages (8 and 12) are implemented as **internal sub-pipelines** that maintain CPU/I/O separation *within* the backend:

```
Core Stage 7 (CPU: CRDT merge, encode for DB)
    ↓ MergeResult { mergedGraph, encodedForDb }
Backend Stage 8 — internal sub-pipeline:
    8a (CPU): encode mergedGraph → wire bytes (format, IRI transposition, etc.)
    8b (I/O): HTTP PUT wire bytes
    ↓ UploadResult
Core Stage 9 (DB commit)
```

The same pattern applies symmetrically to the shard path (Stage 11 → Stage 12 → Stage 13). Dart's `StreamTransformer` can chain sub-transformers internally; from Core's perspective, Stages 8 and 12 are each a single opaque `StreamTransformer`.

`MergeResult` and `MergedShard` carry `mergedGraph` (decoded) and `encodedForDb` (Jelly bytes). **No `encodedForUpload` field** — wire-format encoding is entirely the backend's responsibility. The CPU/I/O split is preserved; it just lives inside each backend rather than spanning Core and backend.

| Mode | Backend CPU sub-stage (8a / 12a) | Backend I/O sub-stage (8b / 12b) |
|---|---|---|
| File-per-Resource | Encode graph → Turtle/JSON-LD + IRI transposition | 1 PUT per resource / per shard |
| Shard-Dataset | Assemble TRiG dataset from decoded graphs | 1 PUT per shard |
| Single-File | Assemble full dataset from all accumulated graphs (on `PhaseComplete`) | 1 PUT total |
| Delta-File | Assemble delta from changed graphs (on `PhaseComplete`) | 1 PUT delta |
