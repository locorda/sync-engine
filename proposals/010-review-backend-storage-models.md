# 010: Review of Backend Storage Modes — Upload Completeness Strategy

**Status**: Draft
**Created**: 2026-03-26
**Context**: 009 defines four upload completeness options for aggregating backends (shard-dataset, single-file, delta-file). This document performs a detailed comparison of Option 1 (Backend Mirror) and Option 3 (Core DB Query), reworked around the key insight of backend-driven ingress. Supersedes the initial Option 3 sketch in 009.

---

## Key Insight: Backend-Driven Ingress

The absolutely essential idea, without which aggregating backend modes cannot work:

**The backend must be able to signal to Core that all resources from a downloaded aggregate must be fully processed and stored by the pipeline, regardless of application-level fetch policy settings.**

In aggregating modes, the backend's download is an *ingress* operation. Whatever the backend receives from remote must be processable by Core's pipeline. The pipeline must not artificially restrict what gets processed when the backend has already downloaded the data. Concretely:

1. **Shard-dataset mode (Mode 2)**: When the backend downloads a shard dataset file, it receives *all* resource graphs for that shard in a single HTTP response. The backend must tell Core: "I have all resources for this shard — process and store them all, even if the app configured `onRequest` for this type." Otherwise, `onRequest` resources would be deferred, never committed to Core's DB, and unavailable when Stage 12 needs to assemble the complete dataset for upload.

2. **Single-file mode (Mode 3)**: When the backend downloads one file containing all shards and all resources, it must be able to feed all of that data into the pipeline. The pipeline's shard-by-shard structure still applies — the backend emits per-shard data as individual `ShardContent` events — but the backend controls when and how data from the file enters the pipeline. Additionally, the pipeline must process ALL indices for single-file backends (including those the app didn't subscribe to), because the upload needs the complete file.

3. **Delta-file mode (Mode 4)**: When the backend downloads delta files from other installations, it receives changed resources that must be ingested through the pipeline — even if they belong to shards or resource types the current pipeline pass wouldn't normally prioritize.

**This confirms what the current implementation already does**: `sync_function.dart`'s `_validateDatasetCompatibilityForBackend()` forces all fetch policies to `Prefetch` when dataset mode is active, and `remote_sync_orchestrator.dart` automatically overrides `onRequest` to eager fetching when `_useShardDatasets` is true. The streaming pipeline formalizes this by making it a per-shard signal from the backend rather than a static configuration check.

---

## The Pre-Ingestion Mechanism

### [Proposed 007 change]: `ShardContent.allResourcesAvailable`

`ShardContent` (Stage 2's output for HTTP 200 responses) gains a flag:

```dart
class ShardContent extends FetchedShard {
  final IriTerm shardIri;

  /// Storage-internal identifier for this shard, or `null` if Stage 1 did not
  /// know about this shard (proactively injected by an aggregating backend that
  /// downloaded it as part of a larger aggregate file). Stage 4 handles `null`
  /// by upserting `shardIri` into `sync_iris` to obtain an `IriStorageId`;
  /// the new shard has 0 local entries so all remote entries are `remoteOnly`.
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

- **Stage 2 (backend)**: Sets `allResourcesAvailable = true` when the shard's data came from an aggregate download (dataset file, single file). Stores the per-resource named graphs in its **internal cache** (shared with Stage 5 via dependency injection, not via the pipeline event).
- **Stage 3 (Core CPU)**: Propagates the flag to `ParsedShard`.
- **Stage 4 (Core DB read)**: When `allResourcesAvailable` is `true`, overrides the configured fetch policy for ALL entries in this shard to `prefetch`. Every `remoteOnly` resource is classified and emitted as a sync candidate — none are deferred. **Unchanged resources (same `clockHash` in local and remote) are still skipped** — they don't need processing and are already in Core's DB from a previous cycle.
- **Stage 5 (backend)**: Serves resource graphs from its internal cache (populated during Stage 2's decode). No HTTP requests. Evicts the cache on `ShardComplete`.

For `ShardNotModified` (304) and `ShardGone` (404/410), the flag is not set — no resource data was downloaded.

### How Pre-Ingestion Guarantees Core's DB Completeness

This is the critical chain that makes Option 3 viable:

1. **First sync (or any sync where the shard returns 200)**: Backend downloads aggregate file → sets `allResourcesAvailable = true` → Core's Stage 4 classifies ALL remote entries (no deferral) → all `remoteOnly` and `conflictCandidate` resources flow through Stages 5–9 → **committed to Core's `documents` table**. ✔

2. **Subsequent syncs with no shard changes (304)**: No download, no processing of remote data. All resources from previous cycles are already in Core's DB. ✔

3. **Subsequent syncs with shard changes (200)**: Backend downloads updated file → sets `allResourcesAvailable = true`. New resources classify as `remoteOnly` → committed. Changed resources classify as `conflictCandidate` → merged → committed. Unchanged resources (same `clockHash`) are **skipped** by Stage 4 — but they were committed on a previous cycle, so they are already in Core's DB. ✔

**Invariant**: After the first complete sync cycle with a 200 response, Core's `documents` table contains a canonical graph for every resource that has appeared in the shard. This invariant is maintained across all subsequent cycles because:
- New resources always have a fresh `clockHash` → classified as `remoteOnly` → committed
- Changed resources have a different `clockHash` → classified as `conflictCandidate` → merged → committed
- `onRequest` deferral is overridden by `allResourcesAvailable` → nothing is skipped based on fetch policy
- Only truly unchanged resources (same `clockHash`) are skipped, and those are guaranteed to already be in Core's DB

**This invariant is what makes Option 3's Stage 12 DB query reliable.**

### [Proposed 007 change]: GroupIndex Discovery via IoGI + Backend-Driven Injection

GroupIndex documents are not entries of the IoI (which catalogs FullIndex documents only). Instead, the **IoGI** (Index of GroupIndices) — a new FullIndex with well-known constant IRI — catalogs all GroupIndex instance documents. The IoGI is synced alongside the IoI in the meta-index phase (Loop 1) of 007.

For **file-per-resource / shard-dataset** backends:
- IoGI is configured with `onRequest` fetch policy → only subscribed GroupIndex documents are fetched
- The Feedback Stage queries `FullIndex + subscribed GroupIndex` IRIs for the content phase
- Unsubscribed GroupIndex data is never downloaded — exactly what we want

For **single-file** backends:
- Stage 2 downloads the entire file on the first shard request (meta-index phase: IoI or IoGI). For the specifically requested IoI/IoGI shards it emits `ShardContent(allResourcesAvailable: true)` with non-null `shardStorageId`. During the **content phase**, when Stage 1 requests known content shards, Stage 2 additionally emits extra `ShardContent` events with `shardStorageId = null` for content shards it downloaded but Stage 1 didn't ask for. Proactive extra-shard injection is **content-phase only** — no extra events during the meta-index phase.
- The `onRequest` override causes ALL GroupIndex documents to be committed during the meta-index phase.
- The Feedback Stage queries **subscribed GroupIndex IRIs only** for the content phase — same as for other backends. The unsubscribed GroupIndex data was already committed via proactive Stage 2 injection; Stage 4 sees the same clockHash for those shards → skips them without re-fetching.
- **No `BackendStorageMode` check needed** — the `allResourcesAvailable` + proactive injection mechanism together guarantee Core's DB completeness.

**Why this works**: The single-file backend downloads everything in Stage 2 (all shards including unsubscribed GroupIndex). Extra shards are proactively injected with `shardStorageId = null`; Stage 4 creates their `sync_iris` entry and processes all remote entries as `remoteOnly`. During the content phase, when the Feedback Stage injects only subscribed GroupIndex, Stage 4 finds the same clockHash for the unsubscribed shards (already committed) → skips them efficiently. Stage 12 assembles the complete single-file upload using the accumulator (changed resources) + Core's DB query for unchanged resources.

---

## Option 3 Reworked: Core DB as Completeness Source

### The Core Idea

Option 3 uses **Core's `documents` table** as the single source of truth for unchanged resource graphs. There is no backend-owned mirror — when Stage 12 needs the complete resource set for dataset assembly, it queries Core's DB for what it doesn't already have from Stage 8's accumulator.

**The viability of Option 3 depends entirely on the DB completeness invariant** established by the pre-ingestion mechanism above. Without pre-ingestion (`allResourcesAvailable`), `onRequest` resources might never be committed to Core's DB, making Stage 12's query incomplete. With pre-ingestion, the invariant is guaranteed and Option 3 is sound.

### Stage-by-Stage Walkthrough

**Stage 2 (Shard Fetch — backend I/O):**

**Stage 2a (I/O — Conditional GET):**
- Uses `storedEtag` from `remote_sync_state` directly (passed via `ShardRef` from Stage 1). No secondary ETag to verify.
- Sends `If-None-Match: <storedEtag>` normally. No ETag present → unconditional GET.
- On 304: emits `ShardNotModified`. On 200: proceeds to 2b.
- **Unlike Option 1**: No mirror ETag comparison. The `remote_sync_state` ETag is the only source. This is simpler — no need to detect download-path inconsistencies because there is nothing persistent to become inconsistent *during* download.

**Stage 2b (CPU — decode downloaded dataset):**
- Decodes the RDF dataset into default graph (shard metadata) + per-resource named graphs.
- Stores the named graphs in the **backend's internal cache** (shared with Stage 5).
- Emits `ShardContent(source: defaultGraph, allResourcesAvailable: true)`.

**No Stage 2c** — Option 3 does not write anything to persistent storage during download. The backend's internal cache is the only working state. This eliminates the entire "crash during mirror write" failure class that Option 1 must handle.

**Stage 3 (Shard Parse — Core CPU):**
- Decodes shard metadata → extracts entries. Propagates `allResourcesAvailable` to `ParsedShard`. No change from 007.

**Stage 4 (Change Detection — Core DB read):**
- Sees `allResourcesAvailable = true` → overrides fetch policy to `prefetch` for this shard.
- Classifies ALL remote entries. No `onRequest` deferral.
- All `remoteOnly` and `conflictCandidate` resources are emitted → they will flow through Stages 5–9 → committed to Core's DB.
- Unchanged resources (same `clockHash`) are still skipped — they are in Core's DB from a previous cycle.
- Emits `ShardComplete` with the remote shard graph for Stage 11.

**Stage 5 (Resource Fetch — backend I/O):**
- For `remoteOnly`/`conflictCandidate`: retrieves the resource graph from the backend's internal cache (populated during Stage 2b). No HTTP request. Emits `FetchedCandidate` with `DecodedGraphSource`.
- For `localOnly`/`remoteRemoved`: pass through (no remote data needed).
- On `ShardComplete` boundary: **evicts the cache for this shard**. Memory released before the next shard's download begins.

**Stages 6–7 (Local Content Load + CRDT Merge — Core):**
- No change from 007. Resources are loaded, merged, encoded for DB and upload.

**Stage 8 (Resource Upload — backend, buffering):**
- For each `MergeResult` with `needsUpload`: buffers `mergedGraph` (decoded) in the **per-shard accumulator** (`Map<IriTerm, DecodedGraphSource>`), keyed by resource IRI.
- Does NOT write to any persistent backend state. The canonical graph will be committed to Core's DB by Stage 9.
- Emits `UploadResult` with the resource's `clockHash` as the remote ETag.

**Stage 9 (DB Commit — Core):**
- Commits canonical merged graphs to `documents` table. Standard Core stage, identical regardless of completeness option.
- **Critical for Option 3**: After Stage 9, canonical graphs are in Core's DB. Stage 12 depends on this. The atomicity of the Stage 9 transaction guarantees that canonical graph + index entry clockHash are consistent.

**Stage 12 (Shard Upload) — Option 3 sub-pipeline:**

- **12a (DB read — pull unchanged graphs from Core's DB)**:
  1. Receives `MergedShard` from Stage 11 (carries the full entry set from Stage 10 — all resource IRIs in this shard, including unchanged ones).
  2. Receives changed resource graphs from Stage 8's accumulator.
  3. Computes `missingIris = MergedShard.entryResourceIris - accumulatorKeys`.
  4. Calls `coreQueryService.getDocumentGraphsByIri(missingIris)` — a Core-provided read-only query that loads canonical graphs from the `documents` table.
  5. Result: a complete `Map<IriTerm, DecodedGraphSource>` of all resource graphs for this shard (changed from accumulator + unchanged from Core's DB).

- **12b (CPU — assemble dataset)**: Assembles the complete RDF dataset: default graph = merged shard metadata from `MergedShard`, named graphs = all resource graphs from 12a. Optionally validates that each resource's clockHash matches what Stage 10 computed.

- **12c (I/O — upload)**: Conditional PUT of the assembled dataset file. On success, emits `UploadedShard` with the new ETag.

### The "304 but Locally Dirty" Case

When a shard returns 304 (no remote changes) but has locally-changed resources:

1. Stage 2 emits `ShardNotModified` — backend cache is empty, `allResourcesAvailable` is irrelevant.
2. Stage 4 classifies locally-changed resources as `localOnly` (from `index_entries WHERE updatedAt > lastSyncTimestamp`). Unchanged resources are skipped.
3. Stage 5 passes `localOnly` through (no remote data needed).
4. Stages 6–7: local graph loaded from DB, accepted as merged result.
5. Stage 8 buffers them in the accumulator.
6. Stage 9 commits (re-writes canonical graph with updated metadata).
7. Stage 10 loads the full entry set from `index_entries` — includes ALL resources in the shard, not just the changed ones.
8. Stage 12a computes `missingIris` (the unchanged resources) and queries Core's DB. **They ARE in Core's DB** — committed during a previous 200 cycle, guaranteed by the pre-ingestion invariant. ✔

**This fixes the gap in the current three-phase implementation**: `_prepareShardUpload` uses `originalNamedGraphs` from the downloaded dataset as the source for unchanged resources. On 304, `originalNamedGraphs` is empty → unchanged resources are missing from the upload. Option 3 queries Core's DB instead, which always has them (assuming at least one previous 200 cycle — which is guaranteed for any shard that has resources in it).

### Crash Safety Analysis

**Crash during Stage 2 (download):** In-memory cache lost. No persistent state was modified. Restart is clean. ✔ *Simpler than Option 1* — no partially-written mirror to detect/repair.

**Crash after Stage 9 (resources committed) but before Stage 12 (shard uploaded):** Core's DB has the canonical graphs (committed). Remote still has the old dataset. On restart: sync detects the shard needs upload (local clockHash differs from remote entry), re-runs merge (idempotent), queries Core's DB for the complete resource set, re-uploads. ✔ *Same recovery as Option 1.*

**Crash after Stage 12 (uploaded) but before Stage 13 (ETag committed):** Remote has the new dataset. Core's DB still has the old ETag in `remote_sync_state`. On restart: downloads the shard again (ETag mismatch), discovers same state, merge is idempotent. ✔ *Same as Option 1.* One wasted download.

**Key insight**: Option 3's crash safety is **simpler by construction** — fewer persistent state transitions means fewer failure modes. Option 1 has three explicit ETag lifecycle checkpoints (2c commit, 8 clear, 12c restore), each a potential corruption point requiring self-healing logic. Option 3 has zero backend-side persistent state transitions during sync.

### ETag Skew Risk (Entry–Data clockHash Mismatch)

If the application writes to a resource between Stage 10 (shard entry set computed) and Stage 12a (Core DB queried for graphs), Stage 12 would assemble a dataset where:
- The shard entry set has the **old** clockHash (from Stage 10).
- The resource graph has the **new** clockHash (from the app's write committed to `documents`).

This produces an inconsistent dataset. However:
- **No data loss or corruption** — CRDT merge is idempotent.
- **Self-correcting**: The mismatch triggers a false-positive shard download on the next sync cycle. After one cycle, entry and graph are consistent again.
- **Window is narrow**: Only the time between Stage 10's DB read and Stage 12a's DB read (typically milliseconds in the streaming pipeline).
- **Option 1 does NOT have this risk**: The mirror's resource graph was written in Stage 8 under the backend's control, and no external writes affect it.

### `onRequest` Compatibility

With the pre-ingestion flag, `onRequest` is effectively overridden to `prefetch` for every shard where the backend sets `allResourcesAvailable = true`. The question becomes moot for 200 responses — all resources are processed.

For a **future** `onRequest`-compatible aggregating backend (where the app genuinely wants to defer processing of some resources even though they were downloaded): only Option 1's mirror can provide this. The mirror stores resource graphs from the download without requiring Core to have processed them. Option 3 cannot serve unprocessed resources because they are not in Core's DB.

### Required Core Pipeline Changes

1. **`ShardContent.allResourcesAvailable` flag** — [Proposed 007 change]: New field on `ShardContent`, propagated through `ParsedShard`. Stage 4 checks it to override fetch policy.

2. **`CoreQueryService.getDocumentGraphsByIri()`** — Core exposes a read-only bulk query for canonical graphs. Structurally the same as `Storage.getDocumentsByIri()` but returns only graphs (stripping `StoredDocument` metadata). The Drift implementation uses the existing batch `IN` query on `sync_documents`.

```dart
/// Provided by Core to the backend for upload completeness queries.
abstract class CoreQueryService {
  /// Loads canonical graphs for the given document IRIs from Core's documents table.
  /// Returns decoded RdfGraphs keyed by IRI. Missing IRIs are omitted from the result.
  Future<Map<IriTerm, RdfGraph>> getDocumentGraphsByIri(Set<IriTerm> documentIris);
}
```

3. **GroupIndex discovery via IoGI** — [Proposed 007 change]: The IoGI meta-index (synced in Loop 1 alongside IoI) catalogs GroupIndex documents. For single-file backends, `allResourcesAvailable` overrides `onRequest` so all GroupIndex documents are committed, enabling the Feedback Stage to inject all indices into the content phase without a `BackendStorageMode` check.

---

## Comparison: Option 1 vs. Option 3

Both options use the pre-ingestion mechanism (`allResourcesAvailable`) for the download path. They differ in how Stage 12 gathers unchanged resources for dataset assembly.

| Aspect | Option 1 (Backend Mirror) | Option 3 (Core DB Query) |
|---|---|---|
| **Persistent state** | Backend-owned mirror table (resource graphs + per-shard ETags) | None (uses Core's `documents` table) |
| **Storage overhead** | ~2x (mirror + Core DB both store all resource graphs) | None |
| **Download path (200)** | Stage 2c writes all resource graphs to mirror + commits shard ETag | Nothing persistent — backend cache only |
| **Download path (304)** | Mirror verified via ETag comparison; skip if match | Nothing — no download, no cache |
| **Upload data source** | Stage 12a reads from mirror (all graphs in one place) | Stage 12a reads accumulator (changed) + Core's DB (unchanged) |
| **Crash safety complexity** | Higher — 3 ETag lifecycle checkpoints with self-healing | Lower — no backend-side persistent state to corrupt |
| **`onRequest` support** | Yes (mirror has graphs even if Core never processed them) | No (Core's DB only has processed graphs) |
| **ETag skew risk** | None (mirror updated within backend's control) | Narrow window: app writes between Stage 10 and Stage 12a |
| **Core–backend coupling** | Low (backend is self-contained) | Medium (backend needs `CoreQueryService`) |
| **Memory during download** | Low — graphs go to persistent mirror, not held in memory long | Per-shard cache: ~50–500 resources x ~1–2 KB = ~50 KB–1 MB peak |
| **Group index overlap** | Graph stored once in mirror, read N times for N shard uploads | Same graph queried from Core's DB N times (once per shard's Stage 12a) |
| **Works for shard-dataset** | Yes | Yes |
| **Works for single-file** | Yes (mirror covers all shards; handles unsubscribed indices) | Yes, but Stage 12a is one large bulk DB read of ALL resources |
| **Works for delta-file** | Yes (compaction reads from mirror) | Yes for normal deltas; compaction needs bulk DB read |
| **Implementation per transport** | Implement `ShardMirrorStorage` (~5 methods) | Use `CoreQueryService` (no backend-side storage needed) |
| **Framework complexity** | Higher — mirror abstraction, ETag lifecycle, writes/reads | Lower — just a query call in Stage 12 |

### When Each Wins

**Option 1 wins when:**
- `onRequest` for aggregating backends is needed (now or future) — unique advantage
- Maximum crash-safety guarantees matter (self-healing ETag lifecycle)
- Backend wants to be fully self-contained (no Core dependency at upload time)
- Group indices with heavy cross-shard overlap (graph stored once, served to N uploads)
- Single-file mode with unsubscribed indices (mirror has everything the backend downloaded)

**Option 3 wins when:**
- Storage efficiency matters (no doubled data)
- Simplicity is preferred (fewer moving parts, simpler crash recovery)
- `onRequest` is definitively not needed for aggregating backends
- The narrow ETag skew window is acceptable (self-corrects in one cycle)
- All indices are subscribed (full coverage of Core's DB)

---

## Applying the Key Insight Across Modes

The pre-ingestion mechanism (`allResourcesAvailable`) and the completeness strategy (Option 1 or Option 3) apply uniformly to all aggregating modes. The differences are in scope and timing.

### Shard-Dataset Mode (Mode 2)

**Scope**: Per-shard. Each shard is a separate dataset file.

**The Container**: The *shard* is the container — one RdfDataset file per shard. The default graph contains shard metadata (entries with `clockHash`), named graphs contain individual resource data. This is the most granular aggregating mode.

**Backend-driven ingress**: Stage 2 downloads one dataset file per shard, decodes the RdfDataset, caches per-resource named graphs, emits `ShardContent(allResourcesAvailable: true)`. Core's Stage 4 processes all entries without deferral.

**Upload**: Stage 12 assembles one dataset file per shard. Accumulator has changed resources; unchanged resources come from mirror (Option 1) or Core's DB (Option 3).

**Pre-ingestion value**: The backend has already paid the cost of downloading all resource graphs. Processing and storing all of them leverages the download that already happened — deferring some via `onRequest` would waste the work.

### Single-File Mode (Mode 3)

**Scope**: Global. One file contains all shards and all resources.

**The Container Analogy**: Just as in shard-dataset mode the *shard* is the container (one RdfDataset per shard file), in single-file mode the *entire file* is the container — technically a single RdfDataset with all named graphs of the entire application. The IoI hierarchy serves as the logical root: the default graph (or a well-known named graph) contains the IoI structure, and all shard metadata + resource graphs are named graphs within the same dataset. The serialization format is typically Jelly (binary, efficient), but TriG or other RDF dataset formats are equally valid (useful for debugging/testing).

```
# Conceptual structure of a single-file dataset:
#
# Default graph (or well-known root graph):
#   IoI document → idx:hasShard → IoI-Shard-1, IoI-Shard-2, ...
#
# Named graphs:
#   <ioi-shard-1>    { entries pointing to FullIndex + GroupIndexTemplate documents }
#   <full-index-A>   { idx:hasShard → shard-A-0, shard-A-1, ... }
#   <shard-A-0>      { entries: (resource-1, clockHash), (resource-2, clockHash), ... }
#   <resource-1>     { the actual RDF data }
#   <resource-2>     { the actual RDF data }
#   ...              { all other shard metadata + resource graphs }
```

**Backend-driven ingress — download path**: Stage 2 downloads the entire file on the **first shard request**. Decodes the RdfDataset into its constituent named graphs, partitions them by shard membership, and caches everything internally. For each subsequent shard request from Stage 1, serves from cache (zero HTTP). Emits `ShardContent(allResourcesAvailable: true)` for every shard.

The single-file backend doesn't need to "push" extra shards into the pipeline proactively. The pipeline's existing feedback loop handles shard discovery:
1. IoI phase: download file → decode RdfDataset → cache all named graphs → process IoI shards → IoI merge → Feedback Stage discovers all indices
2. Content phase: process content shards → Stage 2 serves from cache (already downloaded and decoded)

If the file contains data for indices the IoI didn't know about (e.g., new index from another installation): the IoI merge incorporates the new index, the Feedback Stage re-injects the IoI, and the new index is discovered in the next iteration. The backend already has the data cached.

**Backend-driven ingress — upload path**: Stage 12 buffers all `MergedShard` events across all shards. On `PhaseComplete`: assembles the complete RdfDataset — IoI hierarchy as root, shard metadata + resource graphs as named graphs — and writes it as a single file.

- **With Option 3**: Stage 12a issues one large `getDocumentGraphsByIri(missingIris)` call covering ALL unchanged resources across ALL shards. For 15,000 resources where only 10 changed: queries ~14,990 resources. Feasible with SQLite chunking at 999 variables, but substantial.
- **With Option 1**: Stage 12a reads from mirror (no large bulk DB read needed). One ETag covers the whole file.

**Full index processing**: As described in the "Single-File Mode Forces Full Index Processing" change above, the Feedback Stage injects ALL indices for single-file backends. This ensures Core's DB (and the mirror, if Option 1) contains data for unsubscribed indices too — necessary for complete file assembly.

### Delta-File Mode (Mode 4)

Delta-file mode is an extension of single-file mode. The same container concept applies: each delta file is an RdfDataset containing changed shard metadata + resource graphs as named graphs. The base file is structurally identical to a single-file mode dataset.

**Normal sync (delta write)**: The completeness problem is **bypassed by design** — only changed resources go into the delta file. No complete dataset assembly needed. The delta RdfDataset contains only the named graphs that changed since the last sync.

**Backend-driven ingress for deltas**: When downloading other installations' delta files, the backend decodes the RdfDataset and feeds changed resources into the pipeline via `ShardContent` events (one per affected shard). If the delta covers only part of a shard, `allResourcesAvailable` should be `false` — only the changed resources are available, not the full shard. If the download is a base file (full snapshot), `allResourcesAvailable = true` — same as single-file mode.

**Compaction**: When writing a new base file, the complete RdfDataset is required — structurally identical to single-file mode's upload case (IoI hierarchy as root, all shard metadata + resource graphs as named graphs). Option 1 or Option 3 as above. This can be an out-of-band process separate from the normal sync pipeline.

### Group Indices

Group indices create cross-shard overlap: one resource can appear in N shards (N GroupIndex instances). Pre-ingestion ensures all resource graphs are committed to Core's DB regardless of which shard they came from.

**Pre-ingestion interaction**: In shard-dataset mode with group indices, a resource may appear in multiple dataset files (one per shard). Each download triggers Stage 2b → cache → `allResourcesAvailable = true`. Stage 4 may see the same resource from multiple shards. Per 007's analysis: "CRDT merge is idempotent, and uploading the same merged result twice is a no-op." The resource is committed to Core's DB on first encounter; subsequent encounters see same `clockHash` → skipped.

**Option 3 implication**: When Stage 12 processes N shards containing the same resource, it queries Core's DB for that resource once per shard (each shard's `missingIris` computation is independent). This is redundant but harmless. An optimization (shared query cache across shards within a phase) could eliminate the redundant reads but adds state complexity.

**Option 1 implication**: The mirror stores per-resource (not per-shard). A resource appearing in 5 shards is stored once. Read from the mirror once per shard upload — naturally efficient.

---

## Option 1 as Universal Base

Option 1 could serve as a proper base for all aggregating modes:

1. **`onRequest` is a unique advantage**: No other option supports it. If aggregating backends with lazy fetch are ever needed, Option 1 is the only path.
2. **Self-contained backend**: No new Core API needed (except the `allResourcesAvailable` flag, which is minimal). The framework provides `ShardMirrorStorage` once; transport backends implement ~5 methods.
3. **Uniform across all modes**: Shard-dataset, single-file, delta-file — the mirror pattern adapts to each. The scope changes (per-shard vs. per-file) but the mechanism is identical.
4. **Crash safety is explicit and self-healing**: The ETag lifecycle is more complex but more robust.

**The real cost is storage**: For 15,000 resources x ~1–2 KB average graph size = **~15–30 MB** of mirrored data. On a modern mobile device or desktop, this is negligible. On a constrained device, it's a concern. But the target scale is 2–100 installations with personal data — 30 MB extra is a rounding error.

The mirror tables are structurally simple:
```sql
resource_mirror (
  resource_iri_id INTEGER,     -- FK to sync_iris.id
  shard_iri_id   INTEGER,      -- FK to sync_iris.id (for per-shard eviction)
  graph_content  BLOB,         -- Jelly-encoded graph
  PRIMARY KEY (resource_iri_id)
)

shard_mirror_etag (
  shard_iri_id   INTEGER PRIMARY KEY,  -- FK to sync_iris.id
  etag           TEXT                   -- nullable (cleared = invalidated)
)
```

Two tables, simple CRUD. The Drift implementation is straightforward.

---

## Assessment and Recommendation

### The Pre-Ingestion Mechanism is Non-Negotiable

Regardless of whether Option 1 or Option 3 is chosen, the `allResourcesAvailable` flag on `ShardContent` is essential. It is the mechanism by which aggregating backends:
1. Override `onRequest` fetch policy for downloaded data
2. Ensure all resources flow through the pipeline on every 200 response
3. Guarantee Core's DB completeness for unchanged-resource queries (making Option 3 viable) or confirm mirror consistency (making Option 1 correct)

This is a [Proposed 007 change] that should be incorporated into 007 regardless of the completeness strategy decision.

### Option 1 vs. Option 3

**Option 1 (Mirror)** is the strongest design:
- Supports `onRequest` for aggregating backends (unique advantage)
- Self-contained backend (no Core API dependency at upload time)
- Uniform across all modes (shard-dataset, single-file, delta-file)
- Naturally handles unsubscribed indices in single-file mode
- Explicit crash safety with self-healing ETag lifecycle
- Storage cost (~15–30 MB) is negligible for the target scale

**Option 3 (Core DB Query)** is the pragmatic lightweight alternative:
- Simpler crash safety (no backend-side state to corrupt)
- No storage duplication
- Viable for shard-dataset mode and single-file mode (when all indices are fully processed)
- Requires `CoreQueryService` coupling between backend and Core
- Has a narrow (harmless, self-correcting) ETag skew risk

### Recommendation

**Option 1 should be the primary strategy**, with the framework providing a standard `ShardMirrorStorage` implementation that all aggregating backends share. The storage cost is a reasonable trade-off for the architectural clarity, crash safety, `onRequest` support, and cross-mode uniformity it provides.

**Option 3 remains a valid secondary strategy** for backends that want minimal complexity and no extra storage, accepting the trade-off of no `onRequest` support and the ETag skew risk. The framework could support both by making the completeness strategy configurable per backend mode — but implementing Option 1 first and considering Option 3 only if the storage cost becomes a real problem in practice aligns with YAGNI.
