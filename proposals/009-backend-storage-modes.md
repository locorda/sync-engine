# 009: Backend Storage Modes in the Streaming Pipeline

**Status**: Draft  
**Created**: 2026-03-25  
**Context**: 007 (Feedback-Loop Sync Pipeline) targets file-per-resource first. This document designs how backends implement alternative physical layouts — **shard-dataset**, **single-file**, and **delta-file** modes — and where necessary proposes refinements to 007's pipeline to accommodate those modes.  
**Supersedes / extends**: proposed-changes/015, proposed-changes/025

---

## Motivation

007's streaming pipeline (Stages 1–14) is designed around the **file-per-resource** model: each synced resource maps 1:1 to a remote file, and shard metadata is the only aggregated upload (Stage 10–12). This works well for backends with low per-request overhead (local filesystem, Solid with bulk endpoints).

For backends where every HTTP request carries significant latency (GDrive ~200ms, Solid without bulk endpoints, WebDAV), the file count is the dominant bottleneck:

| Scale | Files (file-per-resource) | Files (shard-dataset) | Files (single-file) |
|---|---|---|---|
| 500 resources, 10 shards | ~510 | ~10 | 1 |
| 2,000 resources, 30 shards | ~2,030 | ~30 | 1 |
| 15,000 resources, 100 shards | ~15,100 | ~100 | 1 |

Reducing physical files from O(resources) to O(shards) or O(1) is essential for network-bound backends.

---

## Pipeline Adaptation Philosophy

007 is a **proposal**, not a fixed implementation. The stage boundaries and Core/backend ownership split described there are design targets, not constraints: if a backend mode requires modifying a Core stage or introducing new pipeline events, that is in scope here.

**Design preference**: encapsulate backend storage complexity within the four backend-owned stages (2, 5, 8, 12) where it fits naturally — this keeps Core backend-agnostic. But if a backend mode exposes a gap in 007's design (e.g., batch-level events, new feedback signals, different encoding handshake), this document should surface and propose those Core changes.

The structural insight likely to hold regardless: the pipeline's natural internal granularity is **per-resource**. Backends aggregating many resources into fewer files need to multiplex (download: one file → many resources) and demultiplex (upload: many resources → one file). Whether that happens entirely within backend stages or requires new Core-level event types is an open question this document addresses per mode.

**Convention for proposed 007 changes**: Sections or callouts marked `[Proposed 007 change]` describe modifications to 007's pipeline design that this document proposes. They are kept here as proposals until the backend storage mode concept is agreed upon, at which point they should be incorporated into 007.

---

## Mode 1: File-per-Resource (Baseline)

Each resource is a separate remote file. Shard metadata is also a separate file. 007 specifies this as the baseline, but see the proposed change below regarding upload encoding.

**Backend stages**:
- **Stage 2** (Shard Fetch): One HTTP GET per shard. Emits `ShardContent` with raw bytes.
- **Stage 5** (Resource Fetch): One HTTP GET per `remoteOnly`/`conflictCandidate`. Emits `FetchedCandidate` with raw bytes.
- **Stage 8** (Resource Upload): Internal sub-pipeline — (8a CPU) encode `mergedGraph` to wire format + IRI transposition → (8b I/O) one HTTP PUT per `needsUpload`.
- **Stage 12** (Shard Upload): Internal sub-pipeline — (12a CPU) encode `MergedShard` → (12b I/O) one HTTP PUT per merged shard.

> **[Proposed 007 change]**: 007 defines `preferredUploadContentType` so Core's CPU stages (7, 11) can pre-encode for upload. **This mechanism should be removed.** Even file-per-resource backends (e.g. Solid) require backend-specific CPU work that Core cannot anticipate (IRI transposition, relative-path rewriting, etc.). Instead, each backend's upload stage is itself a small CPU+I/O sub-pipeline. The CPU/IO split is maintained — within the backend. See the dedicated section below for the full proposal.

---

## Mode 2: Shard-Dataset (One Dataset File per Shard)

All resources referenced by a shard are stored together with the shard metadata in one RDF dataset file (TRiG, Jelly, JSON-LD, or any other RDF dataset encoding). The default graph is shard metadata; named graphs are individual resources keyed by document IRI.

### Download Path: Stage 2 + Stage 5

**Stage 2 (Shard Fetch)** downloads the entire dataset file and splits it into individual resource graphs. Internal sub-pipeline:

- **2a (I/O)**: Conditional GET for the dataset file.
- **2b (CPU)**: Decodes the RDF dataset into default graph (shard metadata) + named graphs (resources).

After 2b:
1. Emits `ShardContent` carrying the **default graph** as `RdfGraphSource` (for Stage 3 to parse shard entries).
2. The extracted named graphs (individual resource graphs) need to be retained for later use — both for Stage 5 (resource fetch) and potentially for Stage 12 (upload completeness). Where and how these are stored depends on the completeness option chosen (see below): in-memory cache, persistent backend DB table, or not at all (if Core provides them later).

This follows the same sub-pipeline pattern as Mode 1's upload stages (8a CPU → 8b I/O), applied in reverse: I/O first, then CPU. RDF dataset decoding is CPU-heavy for large shards (~50–500 resources), so the split keeps the I/O vs CPU separation explicit. This is a general pattern for all aggregating backends (Mode 2, 3, 4): Stage 2 does I/O + decoding, Stage 12 does encoding + I/O.

**Stage 5 (Resource Fetch)** does *not* issue HTTP requests. Instead:

1. For `remoteOnly`/`conflictCandidate`: Retrieves the resource graph from whatever store Stage 2b populated. Emits `FetchedCandidate` with `DecodedGraphSource` (already parsed).
2. For `localOnly`/`remoteRemoved`: Pass through (no remote data needed).

This means **zero additional HTTP requests** for individual resources — all data was pre-fetched with the shard.

### `RootResourceFetchPolicy.onRequest` in Aggregating Modes

In file-per-resource mode, `onRequest` means: don't download a resource until the app explicitly requests it (via `ensure()`). The current implementation enforces that `onRequest` is **incompatible with dataset mode** — `sync_function.dart` throws a `StateError`, and `remote_sync_orchestrator.dart` forces prefetch when `_useShardDatasets` is true (line 880–882). In other words, Core **automatically overrides** the app's configured fetch policy to eager fetching when the backend signals dataset mode. The reason: you cannot selectively fetch individual resources from within an aggregated dataset file.

For the streaming pipeline, this constraint depends on the completeness option:

- **Option 1 (Backend Mirror)**: `onRequest` is effectively **supported**. The backend's persistent mirror already contains all resource graphs from previous sync cycles. When the app calls `ensure()`, the backend serves the resource from its local mirror — no HTTP call, near-instant. During sync, Stage 2 downloads the full dataset file for changed shards (updating the mirror), but unchanged shards (304) are already in the mirror. The "lazy" aspect applies to Core's CRDT processing, not to data availability.

- **Options 2 & 3**: `onRequest` is **not supported** — same limitation as the current implementation. Without a backend-side mirror, there is no local source for resources that were never processed through the pipeline. All resources of each shard must flow through Stage 4→8 (Option 2) or be queryable from Core's DB (Option 3), which requires them to have been synced at least once.

### Upload Path: Stage 8 + Stage 12

**Stage 8 (Resource Upload)** does *not* upload individual resources. Instead:

1. For each `MergeResult` with `needsUpload`: Buffers the `mergedGraph` (decoded) in a **per-shard accumulator** (`Map<IriTerm, DecodedGraphSource>`), keyed by resource IRI.
2. On `ShardComplete` boundary: Does *not* upload anything — defers to Stage 12.
3. Emits `UploadResult` carrying the resource's **clockHash** (extracted from `cm:clockHash` in the merged graph) as the remote ETag. This matches the current dataset-mode implementation (`DatasetBasedGraphSyncStorage._extractETag()`), where each resource's clockHash serves as its version identifier in the DB — the shard file has one HTTP ETag, but individual resources are versioned by clockHash.

**Stage 12 (Shard Upload)** assembles and uploads the complete RDF dataset. Internal sub-pipeline:

- **12a (CPU)**: Assembles the RDF dataset — default graph = merged shard metadata, named graphs = all resource graphs for the shard.
- **12b (I/O)**: Conditional PUT of the assembled dataset file. Emits `UploadedShard` with the new ETag.

Step 12a requires the *complete* set of resource graphs for the shard — not just the changed ones from Stage 8's accumulator. How the unchanged resources are gathered is the central design challenge addressed in the **Upload Completeness Problem** section below.

### State Management

The backend transformer's internal state depends on the chosen completeness option. At minimum, it needs:

- **Upload accumulator**: *Changed* resource graphs from Stage 8, consumed by Stage 12a, evicted after upload. Always needed regardless of completeness option.

Additional state varies by option:
- **Option 1 (Mirror)**: Persistent storage (e.g., DB table) for the last-uploaded state. Stage 2b writes downloaded resource graphs there; Stage 12a reads from it.
- **Option 2 (Core pushes all)**: No additional backend state — all resources arrive through the pipeline.
- **Option 3 (Backend pulls from DB)**: Optionally a transient download cache for Stage 5, evicted per shard. Stage 12a queries Core's DB instead.

### Upload Completeness Problem

Stage 12 must assemble a complete RDF dataset containing *all* resources in the shard — not just the ones that changed. This is the central design challenge for all aggregating modes (shard-dataset, single-file, delta-file).

**Why this is hard in the streaming pipeline**: 007's pipeline processes only resources that need action (remote-changed, locally-changed, conflicts). There is no guarantee that a shard needing upload was even downloaded in this sync cycle — a shard may have had no remote changes (304) while containing locally-changed resources. When Stage 12 receives the `MergedShard` + the few changed resources from Stage 8's accumulator, it is missing all the *unchanged* resources that must also go into the dataset file.

**How the current (non-streaming) implementation solves this**: Core takes full responsibility. In Phase 3, Core queries the `index_entries` table for all active entries in the shard (`_getFinalEntrySet`), loads each resource's canonical graph from the local `documents` table (populated during Phase 2's CRDT merge + DB commit), and injects them into the `DatasetBasedGraphSyncStorage` before handing the complete `RdfDataset` to the backend adapter for upload. The backend is entirely passive — it receives a complete dataset and uploads it. Even when the remote returned 304, the canonical graphs come from Core's local DB.

**The question for the streaming pipeline** is: who is responsible for gathering the unchanged resources, and how?

#### Option 1: Backend Maintains a Persistent Remote Mirror

The backend maintains a persistent per-resource store (e.g., a DB table keyed by resource IRI) that mirrors the last-known remote state of each resource graph. Each stage interacts with this store:

**Stage 2a (I/O — Conditional GET)** *(Option 1 override)*:
- Before issuing the HTTP request, compares Core's ETag for this shard (from the pipeline event) with the shard ETag stored in the persistent mirror.
- **If they match**: sends `If-None-Match: <etag>` normally. A 304 response confirms the mirror is consistent with the remote — Stage 2b and 2c are skipped safely.
- **If they differ** (or no ETag is stored in the mirror yet): forces an **unconditional GET** (no `If-None-Match` header). The mirror may be stale or partially written (e.g., a crash mid-Stage-2c left resource graphs written but the ETag not yet committed) — sending the ETag could yield a false-positive 304, leaving the mirror in an inconsistent state.

**Stage 2b (CPU — decode downloaded dataset)**:
- Decodes the RDF dataset into shard metadata (default graph) + per-resource named graphs.
- Passes the extracted named graphs to Stage 2c.
- On 304 (not modified): no download, no decode — Stage 2a verified that Core's ETag matches the mirror's stored shard ETag, so the mirror is guaranteed consistent. Stage 2c is skipped.

**Stage 2c (I/O — write to persistent mirror)** *(Option 1 only)*:
- **Writes all extracted resource graphs into the persistent mirror** (e.g., DB table keyed by resource IRI), overwriting any previous state.
- As the final step, **persists the shard ETag** (from the HTTP response) into the mirror. Writing the ETag last makes it an atomic commit signal: if Stage 2c is interrupted before this point, the stored ETag will not match Core's ETag on the next sync cycle, triggering an unconditional GET in Stage 2a and re-downloading the shard.
- Keeping this as a distinct I/O sub-stage makes the CPU/IO split explicit and allows the DB writes to be batched or made transactional independently of decoding.

**Stage 5 (Resource Fetch)**:
- For `remoteOnly`/`conflictCandidate`: **reads the resource graph from the persistent mirror** (it was written there in Stage 2b). No HTTP request needed.
- The mirror is the source of truth; no transient in-memory cache is required.

**Stage 8 (Resource Upload — buffering)**:
- For each `MergeResult` with `needsUpload`: **writes the merged resource graph back into the persistent mirror**, replacing the pre-merge state.
- On the **first write for a given shard** in this sync cycle: **clears (invalidates) the shard ETag** stored in the mirror before writing the resource graph. The mirror now intentionally diverges from the remote — if Stage 12b fails or the process crashes before the upload completes, Stage 2a on the next sync will detect the missing ETag and force an unconditional GET, restoring the mirror from the actual remote state.
- The mirror now holds the post-merge (canonical) state for this resource.
- Emits `UploadResult` with the resource's clockHash as the remote ETag.

**Stage 12 (Shard Upload)** *(Option 1 sub-pipeline)*:

- **12a (I/O — query persistent mirror)**: For every resource IRI listed in `MergedShard`'s entry set, reads the resource graph from the mirror — both changed (updated in Stage 8) and unchanged (still at their last-downloaded state).
- **12b (CPU — assemble dataset)**: Assembles the complete RDF dataset: default graph = merged shard metadata, named graphs = all retrieved resource graphs. Optionally validates that each resource's clockHash matches what Stage 10 computed.
- **12c (I/O — upload + commit ETag)**: Conditional PUT of the assembled dataset file. On success: **writes the new shard ETag** (from the PUT response) into the mirror's per-shard ETag store — re-establishing the invariant that `mirror_etag == actual_remote_etag`. This is the symmetric counterpart to Stage 2c's commit-signal write.

**Trade-offs**:
- (+) Backend is fully self-contained — no new Core API needed.
- (+) Works even without downloading the shard (304 case: mirror has previous state).
- (+) **Enables `onRequest`**: mirror serves as local data source for `ensure()` — no HTTP needed for on-demand fetch.
- (+) **Crash-safe with full ETag lifecycle**: (1) Stage 2c writes resources then commits the downloaded shard ETag — crash before commit → unconditional re-download. (2) Stage 8 clears the shard ETag before writing canonical graphs — crash before Stage 12c → unconditional re-download on next sync restores true remote state. (3) Stage 12c writes the new ETag after successful upload — re-establishes the `mirror_etag == remote_etag` invariant. Every failure mode leaves the mirror in a detectably inconsistent state that triggers self-healing.
- (−) **Doubles storage**: every resource graph is stored in both Core's DB and the backend's mirror. For shard-dataset mode with 15,000 resources × ~1–2 KB, this adds ~15–30 MB of redundant data.
- (−) Adds significant implementation complexity — but this complexity is **borne once by the framework** (see below), not by every transport backend.

#### Option 2: Core Ensures All Resources of Dirty Shards Flow Through the Pipeline

Core knows (via the backend's `BackendStorageMode`) that aggregating modes need complete resource sets per shard. Core changes the pipeline behavior accordingly:

**Mechanism**:
- Only shards where at least one resource changed — either remotely (200, not 304) or locally (dirty since last sync) — enter the upload path. Shards with 304 + no local changes are silently skipped. This is already the current behavior.
- For each *dirty* shard, Core ensures **all** resources of that shard flow through the pipeline, not just the changed ones. Unchanged resources within a dirty shard pass through as a lightweight category (e.g., `passThrough`) that bypasses CRDT merge (Stage 7) but still reaches Stage 8 so the backend can accumulate them.
- Alternatively, Core provides all resource graphs — changed and unchanged — as part of an enriched `MergedShard` event at Stage 11/12 boundary, so Stage 12 receives everything it needs without additional pipeline stages.
- `onRequest` fetch policy is effectively unsupported (all resources of each dirty shard must flow through).

This is what the **current implementation** does for dirty shards: it loads all named graphs from the downloaded remote shard dataset, uses canonical overrides for changed resources, and passes the rest through verbatim (`_prepareShardUpload`, lines 2748–2768).

**Trade-offs**:
- (+) **Proven pattern** — the per-dirty-shard behavior exactly matches the current three-phase architecture.
- (+) No storage duplication — Core's DB is the single source of truth.
- (+) Backend stays passive (simple `StreamTransformer` implementation).
- (+) Shards with no changes are never processed — only dirty shards pay the cost.
- (−) Unchanged resources *within dirty shards* flow through pipeline stages unnecessarily (CPU overhead from Stage 4→8, even if minimal processing).
- (−) Requires Core to be aware of the backend's storage mode at the pipeline level (breaks the "Core is backend-agnostic" clean split).
- (−) `onRequest` fetch policy is not supported — must be documented as a mode constraint.

> **[Proposed 007 change]**: If Option 2 is chosen, Stage 4 needs a new classification category (e.g., `passThrough`) that skips merge but still enters the backend's Stage 8 accumulator. Alternatively, the resource completeness assembly moves to the Stage 10–12 boundary: Core injects all resource graphs of the dirty shard into the `MergedShard` event, so Stage 12 receives everything without extra pipeline stages.

#### Option 3: Backend Queries Core's DB at Upload Time

Stage 12 receives only *changed* resources from Stage 8's accumulator. For the rest, the backend queries Core's local DB via a read-only service injected by Core.

**Mechanism**:
- Core provides a query service to the backend: `getCanonicalGraphsForShard(shardIri) → Map<IriTerm, RdfGraphSource>`.
- In Stage 12, the backend:
  1. Receives `MergedShard` (shard metadata with the full entry list from Stage 10).
  2. Receives changed resource graphs from Stage 8's accumulator.
  3. Calls `getCanonicalGraphsForShard()` to get ALL resources for the shard.
  4. Overlays the changed resources from step 2 onto the full set from step 3.
  5. Assembles and uploads the complete RDF dataset.
- `onRequest` fetch policy still not supported: Core's DB only contains resources that have been synced at least once. Resources that were never fetched (due to laziness) would be missing from the query result.

**Trade-offs**:
- (+) Only changed resources flow through the pipeline (less pipeline traffic).
- (+) No storage duplication (Core's DB is the source of truth).
- (+) Stage 12 pulls what it needs on demand — efficient.
- (−) New dependency: backend's Stage 12 depends on Core's storage API (breaks encapsulation further than Option 2).
- (−) Still needs `onRequest` disabled — same constraint as Option 2.
- (−) Adds a DB read phase inside Stage 12 (I/O stage now does both DB reads and network writes).
- (−) Core must expose a stable query API for this — tighter coupling between Core internals and backend.
- (−) **Entry–data clockHash skew**: if the application writes a resource after Stage 10 computes the `MergedShard` entry set but before Stage 12 queries Core’s DB, the uploaded shard will have a stale clockHash in the entry set while the resource graph contains newer data. The CRDT merge is idempotent — no data is corrupted — but the mismatched entry triggers a false-positive shard download in the next sync cycle. The mismatch self-corrects after one additional cycle.

#### Option 4: Core Owns Dataset Assembly (Current Architecture)

Instead of the backend assembling the RDF dataset in Stage 12, Core itself takes ownership of dataset assembly — closely mirroring what the current three-phase architecture does. Core's pipeline stage (or a new stage between 11 and 12) queries `index_entries` + `documents` to build a complete `RdfDataset` per shard and hands it to the backend's Stage 12, which only needs to serialize and upload.

**Mechanism**:
- Core's shard finalization (Stage 10/11 area) queries the `index_entries` table for all active entries, loads canonical graphs from the `documents` table, and assembles a complete `RdfDataset`.
- The backend's Stage 12 receives the pre-assembled dataset. Its job is reduced to: serialize to the target wire format (TRiG, Jelly, JSON-LD, etc.) and upload.
- This is essentially the current `_prepareShardUpload` / `DatasetBasedGraphSyncStorage` pattern moved into the streaming pipeline.

**Trade-offs**:
- (+) **Closest to current proven implementation** — minimal conceptual change from today's three-phase architecture.
- (+) Backend stays maximally passive — no completeness logic at all.
- (+) No storage duplication.
- (−) **Only works for shard-dataset mode.** Core assembles one dataset per shard, but single-file mode needs *all* shards combined into one file, and delta-file mode only needs changed resources. Core cannot assemble these without knowing the backend's physical layout — which defeats the purpose of backend encapsulation.
- (−) `onRequest` not supported (same as Options 2 & 3).
- (−) Core pipeline gains backend-format-specific logic (dataset assembly), reducing backend-agnosticism.
- (−) Locks the pipeline to dataset-per-shard granularity — future modes that don't fit this shape would need yet another path.

> **Note**: The key difference from Option 2 is *where* the dataset is assembled. Option 2 pushes individual resource graphs through the pipeline for the backend's Stage 12 to combine. Option 4 has Core assemble the dataset and push a complete `RdfDataset` to the backend. Option 2 is more flexible (works for any aggregation shape), Option 4 is simpler for the backend but only works for shard-dataset.

#### Comparison

| Aspect | Option 1 (Mirror) | Option 2 (Core pushes all) | Option 3 (Backend pulls from DB) | Option 4 (Core assembles dataset) |
|---|---|---|---|---|
| Storage overhead | ~2× (mirror + Core DB) | None | None | None |
| Pipeline traffic | Only changed resources | All resources | Only changed resources | Complete dataset per shard |
| Core API changes | None | Stage 4 new category or enriched `MergedShard` | `getCanonicalGraphsForShard()` query service | New Core stage for dataset assembly |
| Backend complexity | High in framework; **Low per transport** (implement storage interface only) | Low (passive accumulator) | Medium (query + assembly) | **Minimal** (serialize + upload) |
| `onRequest` support | **Yes** (mirror serves `ensure()`) | No (same as current impl) | No (same as current impl) | No (same as current impl) |
| Works for single-file / delta | Yes | Yes | Yes | **No** (shard-dataset only) |
| Proven in current impl | No | **Yes** | No | **Yes** (closest match) |
| Core–backend coupling | Low | Medium (mode-aware Stage 4) | High (DB query dependency) | High (Core knows dataset format) |

**Open — no recommendation yet.** Option 2 matches the current proven implementation and is simplest for backends while remaining flexible across all modes. Option 4 is the closest to today's architecture but only works for shard-dataset. Option 3 reduces pipeline traffic but increases coupling. Option 1 is the only option that supports `onRequest` (via its local mirror) but at the cost of doubled storage.

### Framework-Provided Mode Implementations

Rather than each transport backend (GDrive, Solid, Directory) implementing full pipeline logic independently, the framework provides a **standard `StreamTransformer` implementation per storage mode**. Each standard implementation depends on a **mode-specific storage interface** that transport backends implement:

```dart
// Framework-defined storage interface for Option 1's persistent mirror
abstract class ShardMirrorStorage {
  /// Returns graphs for all [iris] present in the mirror; absent IRIs are omitted.
  Future<Map<IriTerm, RdfGraph>> readResources(Set<IriTerm> iris);
  Future<void> writeResources(Map<IriTerm, RdfGraph> graphs);
  Future<String?> readShardEtag(IriTerm shardIri);
  Future<void> writeShardEtag(IriTerm shardIri, String etag);
  Future<void> clearShardEtag(IriTerm shardIri);
}

// Framework-provided standard pipeline implementation — owns all sub-stage logic
class ShardDatasetBackend implements StreamTransformer<...> {
  final ShardMirrorStorage mirror;   // injected
  final HttpTransport transport;     // injected
  // implements 2a/2b/2c → 5 → 8 → 12a/12b/12c in full
}

// Per-transport: only implements the storage interface + HTTP adapter
class SolidShardDatasetBackend extends ShardDatasetBackend {
  SolidShardDatasetBackend({required SolidHttpClient client})
      : super(mirror: DriftShardMirrorStorage(), transport: SolidHttpTransport(client));
}

class GDriveShardDatasetBackend extends ShardDatasetBackend {
  GDriveShardDatasetBackend({required GDriveClient client, required String fileId})
      : super(mirror: DriftShardMirrorStorage(), transport: GDriveHttpTransport(client, fileId));
}
```

The storage interface (e.g., `ShardMirrorStorage`) can have multiple implementations: a Drift/SQLite adapter is the natural default; in-memory for tests; possibly a Hive adapter for Flutter-only targets.

**`locorda_dir` as a universal test proxy**: The directory backend delegates to whichever standard mode implementation is configured at construction time. Since `locorda_dir` uses the local filesystem as its HTTP transport, it can simulate any physical storage mode — shard-dataset, single-file, delta-file — without requiring cloud credentials. This makes it the primary harness for testing all storage modes end-to-end.

### Resources in Multiple Shards

Same as 007's analysis: a resource may appear in multiple shard datasets. Each shard upload includes the resource's current canonical graph. Cross-shard clock hash discrepancies self-correct in the next sync cycle. CRDT merge is idempotent.

---

## Mode 3: Single-File (Everything in One File)

All shards and all resources — across all types — are stored in a single physical file. This reduces HTTP requests to **O(1)** for both download and upload.

A backend may optionally choose to split into a few files (e.g., per type or per type-group) if that improves its conflict characteristics, but the baseline concept is: **one file = one sync unit**. The pipeline design supports both — the only difference is the backend's internal grouping logic.

### Physical Layout

Simplest case — everything in one file:

```
backend-storage/
└── locorda-data.trig        # Everything: IoI, all indices, all shards, all resources
```

Optional per-type variant (backend decides):

```
backend-storage/
├── Note.trig           # All Note shards + all Note resources
├── Tag.trig            # All Tag shards + all Tag resources
├── _meta.trig          # IoI + ClientInstallation + FullIndex shards
└── ...
```

The dataset file uses a multi-layer RDF dataset structure (TRiG shown as one possible encoding):

```trig
# locorda-data.trig

# Default graph: aggregation metadata
<> a locorda:AggregatedFile ;
   locorda:containsShard <shard/note-0>, <shard/note-1>, <shard/tag-0>, ... .

# Named graph per shard (shard metadata)
<shard/note-0> {
    <shard/note-0#it> a idx:Shard ;
        idx:containsEntry <entry/note-001>, <entry/note-042>, ... .
}

# Named graph per resource
<note/note-001> {
    <note/note-001#it> a schema:Note ;
        schema:headline "My first note" ;
        sync:crdtClockHash "abc123" .
}

<tag/tag-001> {
    <tag/tag-001#it> a schema:Tag ;
        schema:name "work" ;
        sync:crdtClockHash "def456" .
}
```

### How It Maps to the Pipeline

The single-file backend bridges between 007's per-shard pipeline and its one-file (or few-files) physical layout. The key challenge: the pipeline processes shards one at a time, but the backend reads/writes one file containing everything.

#### Download Path

**Stage 2 (Shard Fetch)**: When the first shard arrives:
1. Download the entire file (one HTTP GET).
2. Parse into per-shard data (each shard's metadata + its resources).
3. Cache all shard data in memory.
4. Emit `ShardContent` for the requested shard.

For all subsequent shards (regardless of type): serve from cache (zero HTTP requests).

On `PhaseComplete`: Evict the cache.

If the backend uses the per-type variant: one GET per type file (on first shard of that type), then serve subsequent shards of that type from cache.

**Stage 5 (Resource Fetch)**: Same as shard-dataset mode — look up resource from Stage 2's cache.

This is essentially a **read-through cache** at file level. The backend is opaque to the pipeline — it emits per-shard/per-resource data exactly as the pipeline expects.

#### Upload Path

**Stage 8 (Resource Upload)**: Same as shard-dataset — buffer merged resources, do not upload.

**Stage 12 (Shard Upload)**: Does *not* upload per shard. Instead:
1. Receives `MergedShard` events (one per shard, across all types).
2. Accumulates all merged shards + their assembled resources.
3. On `PhaseComplete`: Assembles the complete file from all accumulated shard data + unchanged resources.
4. Uploads one file (or one file per type in the per-type variant).

#### Upload Completeness

The same completeness problem from Mode 2 applies here, but at file scope rather than shard scope: the backend must assemble a file containing *all* resources across *all* shards, not just the changed ones. The same three options (backend mirror, Core pushes all, backend pulls from DB) apply — see [Mode 2: Upload Completeness Problem](#upload-completeness-problem) for the full analysis.

The problem is amplified in single-file mode because the scope of "unchanged resources needed" is the entire dataset, not just one shard. In shard-dataset mode, a shard with no changes can be skipped entirely (no upload needed). In single-file mode, even if only one resource in one shard changed, the upload must include everything.

#### ETag Semantics

**Challenge**: Stage 12 normally uploads after each shard and emits `UploadedShard` so Stage 13 can commit the ETag. In single-file mode, the ETag is per-file, not per-shard. Two options:

**Option A — PhaseComplete-triggered bulk upload**: Stage 12 buffers all `MergedShard` events. On `PhaseComplete`, it assembles and uploads the file, then emits all `UploadedShard` events in sequence, followed by the `PhaseComplete`. Stage 13 commits all in one transaction. This preserves correctness but defers all shard commits until the end of the phase.

**Option B — Synthetic per-shard ETags**: After uploading the file, Stage 12 derives per-shard "synthetic ETags" (e.g., hash of each shard's content within the file). This allows Stage 13 to commit per-shard state incrementally. However, on the next sync cycle, Stage 2 must translate per-shard ETags back to the per-file ETag for the HTTP conditional request — added complexity.

**Recommendation**: Option A. It's simpler, and the latency of deferring all commits to `PhaseComplete` is negligible compared to the HTTP savings. The backend's `onCommit` callback in Stage 9 can still update per-resource mirror state within resource commits.

### Change Detection

The single-file ETag from the remote backend detects whether *anything* changed. When the file is downloaded, per-shard clock hashes within it enable skipping unchanged shards during merge (Stage 4's classification logic handles this naturally — unchanged shards produce 304-equivalent `ShardNotModified`).

### Incremental Sync Optimization

On incremental sync (not initial), if nothing changed remotely, the backend's conditional GET returns 304 and no parsing/merging is needed. The trade-off: a change to *one* resource anywhere triggers re-download and re-upload of the entire file. For the target scale (2–20 installations, total data in the tens-to-hundreds of KB range), this is acceptable. The per-type variant mitigates this by limiting re-download/re-upload scope to one type.

### When to Split into Multiple Files

A backend should consider the per-type (or per-type-group) variant when:
- The single file becomes very large (>5 MB) and incremental sync bandwidth matters.
- Conflict probability is high: two installations editing different types would conflict on every sync if sharing one file. Per-type splits isolate conflicts.
- The backend's API supports batch operations anyway (e.g. GDrive batch API), making a few parallel requests cheap.

---

## Mode 4: Single-File + Delta Files (Installation-Specific Changes)

This mode extends single-file mode to reduce the frequency at which the large base file must be read and written. Every installation writes its changes to a small, installation-specific **delta file**. Periodically, deltas are compacted into the base.

The same applies to the per-type variant — each type file gets its own deltas.

**Upload completeness**: Delta-file mode *partially* sidesteps the completeness problem from Mode 2/3: Stage 12 only needs the *changed* resources for the delta (not the full dataset). However, for **compaction** (merging deltas into the base file), the complete dataset *is* needed — the same options from Mode 2 apply at compaction time. If compaction is treated as a separate offline process rather than part of the normal sync pipeline, the in-pipeline completeness problem is avoided.

### Physical Layout

With true single-file:

```
backend-storage/
├── locorda-data.trig               # Base file: last compacted state
├── locorda-data.delta.inst-A.trig  # Installation A's changes since last compaction
├── locorda-data.delta.inst-B.trig  # Installation B's changes since last compaction
└── ...
```

With per-type variant:

```
backend-storage/
├── Note.trig               # Base file for Notes
├── Note.delta.inst-A.trig  # Installation A's Note changes
├── Tag.trig                # Base file for Tags
├── Tag.delta.inst-A.trig   # Installation A's Tag changes
└── ...
```

### How It Works

#### Write Path (Local Changes Only)

When the local installation has changes to upload:

1. **Stage 8**: Buffers changed resources (same as single-file mode).
2. **Stage 12**: Instead of rewriting the entire base file:
   - Assembles a delta TRiG containing *only* the changed/new/deleted resources and their shard entry updates.
   - Uploads *only* the delta file (e.g., `locorda-data.delta.inst-A.trig`).
   - The base file is untouched.

Delta file structure:
```trig
# locorda-data.delta.inst-A.trig

# Metadata: what this delta contains
<> a locorda:DeltaFile ;
   locorda:installation <inst-A> ;
   locorda:basedOnVersion "etag-of-base-when-delta-was-created" ;
   locorda:timestamp "2026-03-25T10:00:00Z"^^xsd:dateTime .

# Changed shard entries (only the modified entries, not the full shard)
<shard/note-3> {
    # Updated/added entries only
    <entry/note-789> idx:clockHash "xyz789" .
    <entry/note-790> idx:clockHash "abc012" .
}

# Changed/new resource graphs
<note/note-789> {
    <note/note-789#it> a schema:Note ;
        schema:headline "Updated note" ;
        sync:crdtClockHash "xyz789" .
}

<note/note-790> {
    <note/note-790#it> a schema:Note ;
        schema:headline "New note" ;
        sync:crdtClockHash "abc012" .
}
```

#### Read Path (Sync from Remote)

When syncing (downloading remote changes):

1. **Stage 2**: Downloads:
   - The base file (conditional GET — skipped if unchanged).
   - All delta files from *other* installations (conditional GETs).
2. **CRDT merge**: The base file + all deltas are merged to produce the current state. CRDT semantics guarantee convergence regardless of the order deltas are applied. The merge happens in Stage 2 before emitting per-shard data to the pipeline.
3. **Change detection**: After merging base + deltas, per-shard clock hashes are compared against locally stored values (same as single-file mode).

#### Compaction

Periodically (e.g., every N sync cycles, or when delta files exceed a size threshold), one installation writes the compacted state back to the base file and deletes all delta files:

1. Download base + all deltas.
2. CRDT merge everything.
3. Upload merged result as new base file.
4. Delete all delta files.

Compaction can run as a background operation after a normal sync cycle. Only one installation should compact at a time — optimistic locking via ETag on the base file prevents concurrent compactions.

### Benefits

| Scenario | Single-File Mode | Delta-File Mode |
|---|---|---|
| Local changes, no remote changes | Download + re-upload entire file | Upload small delta only |
| Remote changes, no local changes | Download entire file | Download base (if changed) + small deltas |
| Both local and remote changes | Download + merge + re-upload entire file | Download deltas + merge + upload local delta |
| Conflict (concurrent edits) | Re-download, re-merge, re-upload full file | Re-download deltas, re-merge, upload delta |

The primary advantage: **write amplification is drastically reduced**. Instead of rewriting a potentially large base file on every sync, only a small delta is uploaded. This matters most for:
- Large types (thousands of resources).
- Frequent syncs (delta is tiny if only 1–2 resources changed).
- Metered network connections (bandwidth conservation).

### Challenges & Trade-offs

**Discovery**: The backend must enumerate delta files for other installations. For GDrive, this means listing files matching a naming pattern (`locorda-data.delta.*.trig`). For filesystem backends, a directory listing. For Solid, a container listing. This adds one list operation per sync cycle (or per type file, if using the per-type variant).

**Staleness**: Delta files reference `basedOnVersion` (the base file's ETag when the delta was created). If the base file has been compacted since, the delta may contain entries superseded by the base. CRDT merge resolves this correctly — the base's post-compaction state already includes the delta's changes (since compaction merged them). The delta is effectively a no-op and can be deleted.

**Complexity**: This is the most complex mode. It should only be implemented for backends where write amplification is a real problem (large datasets on metered/slow connections). For most use cases, single-file mode is simpler and sufficient.

**Number of delta files**: With 2–20 installations, there are at most 20 delta files. Each delta is typically small (a few KB). The listing + conditional GETs add ~20 requests per sync cycle — still far fewer than file-per-resource or even shard-dataset.

---

## Backend Configuration & Selection

Each backend declares its preferred storage mode when creating a `RemoteSyncStorage` session:

```dart
enum BackendStorageMode {
  /// Each resource is a separate remote file. Shard metadata is a separate file.
  /// Supports onRequest fetch policy.
  filePerResource,
  
  /// All resources of a shard are stored with shard metadata in one TRiG dataset.
  /// Does NOT support onRequest fetch policy.
  shardDataset,
  
  /// Everything (or a backend-chosen grouping) in a single file (or very few files).
  /// Does NOT support onRequest fetch policy.
  singleFile,
  
  /// Single base file + per-installation delta files for incremental writes.
  /// Does NOT support onRequest fetch policy.
  singleFileWithDeltas,
}
```

The mode is per-backend (or potentially per-type, if a backend wants to use different modes for different resource types). Core's pipeline stages do not branch on the mode — they only see the backend's `StreamTransformer` implementations.

---

## Stage Behavior by Mode — Summary

| Stage | File-per-Resource | Shard-Dataset | Single-File | Delta-File |
|---|---|---|---|---|
| **2 (Shard Fetch)** | 1 GET per shard | 1 GET per shard (TRiG), cache resources | 1 GET total (first shard), cache all | 1 GET base + N GET deltas, merge, cache |
| **5 (Resource Fetch)** | 1 GET per resource | Lookup from Stage 2 cache | Lookup from Stage 2 cache | Lookup from Stage 2 cache |
| **8 (Resource Upload)** | 1 PUT per resource | Buffer per shard | Buffer all | Buffer all |
| **12 (Shard Upload)** | 1 PUT per shard | Assemble TRiG, 1 PUT per shard | Buffer; on PhaseComplete: 1 PUT total | Buffer; on PhaseComplete: 1 PUT delta |

---

## [Proposed 007 change]: Remove `preferredUploadContentType`; Backends Use Internal Sub-Pipelines

007 defines `String? preferredUploadContentType` on the backend interface so CPU stages 7 and 11 can pre-encode merged graphs into the backend's preferred wire format. The intent was to keep upload stages (8, 12) as pure I/O, with Core doing the encoding on the backend's behalf.

**Problem**: Even the simplest file-per-resource backends (e.g. Solid) need backend-specific CPU work before the network write — IRI transposition, relative-path rewriting, Solid metadata injection. Core cannot anticipate this. The pre-encoding hook in Core does not eliminate the CPU step in the backend; it only moves *one part* of it (format serialization) to Core while leaving the rest in the backend anyway. For aggregating backends (shard-dataset, single-file, delta-file), `preferredUploadContentType` is already `null` because Core cannot help at all.

**Proposed resolution**: Remove `preferredUploadContentType` and `encodedForUpload` from the Core–backend contract. Instead, backends compose their own **internal sub-pipeline** of CPU and I/O sub-stages, maintaining the separation principle *within* the backend:

```
Core Stage 7 (CPU: CRDT merge, encode for DB)
    ↓ MergeResult { mergedGraph, encodedForDb }
Backend Stage 8 — internal sub-pipeline:
    8a (CPU): encode mergedGraph → wire bytes (format, IRI transposition, etc.)
    8b (I/O): HTTP PUT wire bytes
    ↓ UploadResult
Core Stage 9 (DB commit)
```

The same applies to Stages 11/12 (shard path). Dart's `StreamTransformer` can chain sub-transformers internally; from Core's perspective, Stage 8 is still a single opaque `StreamTransformer`.

**Result**:
- `MergeResult` and `MergedShard` drop the `encodedForUpload` field.
- Stages 7 and 11 (Core CPU) produce `encodedForDb` and `mergedGraph` only.
- The CPU/I/O split is preserved — it just lives inside each backend rather than spanning Core and backend.
- Backends have full control over their encoding without Core needing to know about wire formats.

| Mode | Backend CPU sub-stage (8a / 12a) | Backend I/O sub-stage (8b / 12b) |
|---|---|---|
| File-per-Resource | Encode graph → Turtle/JSON-LD + IRI transposition | 1 PUT per resource / per shard |
| Shard-Dataset | Assemble TRiG dataset from decoded graphs | 1 PUT per shard |
| Single-File | Assemble full TRiG from all accumulated graphs (on `PhaseComplete`) | 1 PUT total |
| Delta-File | Assemble delta TRiG from changed graphs (on `PhaseComplete`) | 1 PUT delta |

---

## Impact on `ShardComplete` / `PhaseComplete` Semantics

The boundary elements from 007 gain additional meaning for aggregating backends:

- **`ShardComplete`**: In shard-dataset mode, Stage 5 uses this to evict the shard's download cache. In single-file/delta mode, Stage 12 uses this to accumulate one more shard into the upload buffer.

- **`PhaseComplete`**: In single-file and delta mode, Stage 12 uses this as the **flush trigger** — assemble and upload the file (or delta). In shard-dataset mode, `PhaseComplete` is only relevant for the Feedback Stage (Stage 14).

This is consistent with 007's design principle 3 ("Boundary elements for coordination") and principle 8 ("`ShardComplete`/`PhaseComplete` as flush points in pool stages"). Single-file mode simply extends the flush scope from per-shard to per-phase.

---

## Backend Helper Services from Core

Core provides helper services that backends can use within their `StreamTransformer` implementations. These are not pipeline stages — they are utility services available via dependency injection:

1. **DB access for canonical graph retrieval** (relevant for upload completeness Option 3): Stage 12 queries Core for unchanged resource graphs. Core provides a read-only bulk query interface, e.g., `getCanonicalGraphsForShard(shardIri) → Map<IriTerm, RdfGraphSource>`. This service is only needed if Option 3 is chosen; with Option 2, Core pushes all resources through the pipeline and no query is needed.

2. **TRiG / Dataset codec**: Core's `rdf_core` provides `encodeDataset()` / `decodeDataset()` for TRiG serialization. Backends use this in their Stage 2 (download + parse) and Stage 12 (assemble + upload) transforms.

3. **Backend state persistence via `onCommit` callback**: As specified in 007 Stage 9, the backend's `onCommit(batch)` runs inside Core's transaction. Backends can persist per-resource mirror state (ETags, file IDs, checksums) atomically with Core's document commit. For single-file/delta mode, the file-level ETag can be persisted in a separate `onPhaseCommit()` callback after Stage 12/13 complete.

---

## Recommended Implementation Order

1. **File-per-resource** — Already specified in 007. Implement first.
2. **Shard-dataset** — Natural step from current implementation. Reuse existing `DatasetBasedGraphSyncStorage` concepts. Implement second.
3. **Single-file** — Extension of shard-dataset. Implement when GDrive backend performance requires it.
4. **Delta-file** — Only if single-file mode's write amplification is a measured problem. YAGNI until proven necessary.

---

## Open Questions

### 1. Cross-Backend Coordination for onRequest

If one backend uses shard-dataset mode (requiring all resources) and another uses file-per-resource (allowing lazy loading), the framework must ensure all resources are available locally before the shard-dataset backend can sync. This constraint exists today (see proposed-changes/015). The new pipeline needs a clear resolution point — probably in the Feedback Stage's content-phase logic.

### 2. Mixed Modes per Type

Should a single backend be able to use different storage modes for different resource types? E.g., file-per-resource for large binary attachments, shard-dataset for small metadata documents. The interface supports it (mode is part of the `BackendStorageMode` config), but the pipeline's Stage 2/5/8/12 transforms would need to branch per resource type. Worth investigating if a concrete use case emerges.

### 3. Upload Completeness Strategy

The upload completeness problem (see Mode 2 analysis) has three options with different trade-offs. The choice of option affects Core's pipeline design:
- **Option 2** requires Stage 4 changes or an enriched `MergedShard` event — a Core-level change.
- **Option 3** requires Core to expose `getCanonicalGraphsForShard()` — a new API surface.
- **Option 1** requires no Core changes but doubles storage.

This is probably the most consequential design decision for the streaming pipeline's backend support. It should be decided before implementation begins.

### 4. Memory Pressure Bounds

For true single-file mode, the download cache and upload accumulator hold the entire file in memory. With 15,000 resources × ~1–2 KB ≈ 15–30 MB, this is within bounds for the target scale but should be documented as a constraint. Backends can mitigate this by choosing the per-type variant (splitting into a few files). If memory becomes an issue, a streaming TRiG parser/serializer that doesn't require holding the full dataset in memory could be considered.

### 5. Conflict Amplification in Single-File Mode

With everything in one file, *any* concurrent edit from another installation causes an ETag conflict on upload, even if the edits touch different resource types. CRDT merge resolves the conflict correctly (re-download, re-merge, re-upload), but the frequency of conflicts increases. For 2–5 installations with low sync frequency, this is acceptable. For higher concurrency, the per-type variant or shard-dataset mode may be preferable. This is a backend-level decision.
