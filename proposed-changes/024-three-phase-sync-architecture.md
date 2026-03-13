# 024 — Three-Phase Sync Architecture

**Status**: Draft  
**Created**: 2026-03-01  
**Context**: Initial sync takes ~48–54s for Chat Essence app (2015 messages, 62 group shards × 2 types = 124 shard operations, 263 files total). Root cause is sequential per-shard processing where download, merge, upload, and DB commit are interleaved.

## Decision Alignment (026)

This proposal is the mandatory baseline in the performance-first direction defined in `026-recap-sync-direction.md`.

- 024 is required regardless of storage mode.
- It improves execution order and batching without forcing a storage-format decision.
- It applies to both profiles:
  - Dataset/Flat mode (Dir, GDrive default profile).
  - Linked-Data mode (Solid/interoperability profile).

In short: 024 is phase A of the new strategy, not an optional optimization.

---

## Problem Statement

### Measured Performance (Chat Essence, Dir Backend, Initial Sync)

```
syncFunction                          53,985 ms
├── sync.metaPhase                       737 ms
├── sync.contentPhase                 53,098 ms
│   ├── content.collectSpecs              57 ms
│   ├── content.groupIndexBatch          478 ms  (128 GroupIndex entries)
│   ├── content.shardPhase            27,382 ms  (SyncChatMessage, 62 shards)
│   ├── content.shardPhase            15,664 ms  (SyncMessageGroup, 62 shards)
│   ├── content.shardPhase             1,672 ms  (SyncKeyword, 1 shard, 2015 docs)
│   └── ... (remaining types)
```

### Per-Shard Breakdown (typical shard, ~20–50 docs)

| Step | Duration |
|---|---|
| `shard.buildQueue` | 5–10 ms |
| `shard.syncDocsBatch` | 15–50 ms (includes download + merge) |
| **`finalize.applyAndStore`** | **86–114 ms** (serialize + upload) |
| `finalize.commitBatch` | 6–28 ms |
| **`shard.finalize` total** | **99–136 ms** |

### Why This Is Slow

The current orchestrator processes **each shard as an atomic unit**: download its documents → merge → serialize the shard → upload the shard → commit to DB. Then move to the next shard. This means:

1. **Sequential I/O**: 124 shards × (download + upload) = 248 I/O operations in series.
2. **Per-shard upload overhead**: Even a tiny shard (3 docs) costs ~100ms to serialize and upload.
3. **Per-shard DB commit**: 124 separate `commitDeferredBatch` calls (6–162ms each).
4. **No parallelism**: The next shard waits until the previous one is fully committed.
5. **Interleaved concerns**: Download, merge, upload, and persistence are tightly coupled within each shard iteration.

### Current Flow (Pseudocode)

```
for each resourceType:
  for each shard in resourceType:          // 62 shards, sequential
    docs = download(shard)                 // I/O: read from remote
    for each doc in docs:
      mergedDoc = crdtMerge(doc, localDoc) // CPU: merge
    shardGraph = buildShardGraph(docs)     // CPU: serialize
    upload(shardGraph)                     // I/O: write to remote
    commitBatch(mergedDocs)                // I/O: write to local DB
```

---

## Proposal: Three-Phase Sync

Restructure the sync loop into three distinct phases that separate concerns and enable batching/parallelism:

### Phase 1: Download (parallel/batched)

Download **all** remote data before any merging or uploading begins.

```
allRemoteData = {}
for each resourceType:
  for each shard in resourceType:
    allRemoteData[shard] = download(shard)    // parallel or batched
```

**Key properties:**
- All downloads happen first, before any writes.
- Downloads can be **parallelized** (multiple concurrent HTTP requests) or **batched** (backend-specific bulk APIs).
- Downloaded data is held in memory or temp storage until Phase 2.
- Backend chooses its optimal strategy:
  - **Dir backend**: Parallel file reads (or just sequential — fast enough locally).
  - **GDrive**: Batch API (up to 100 per request) or parallel downloads.
  - **Solid**: Parallel HTTP GETs; future bulk endpoints if/when available.
  - **WebDAV**: Parallel GETs or PROPFIND for change detection + parallel downloads.

### Phase 2: Merge (bulk, CPU-only)

Process all downloaded data, performing CRDT merges against local state. No I/O to remote.

```
allMergeResults = {}
for each resourceType:
  for each shard in resourceType:
    remoteData = allRemoteData[shard]
    for each doc in remoteData:
      mergedDoc = crdtMerge(doc, localDoc)    // CPU-only
    allMergeResults[shard] = buildShardGraph(mergedDocs)
```

**Key properties:**
- Pure computation — no network or file I/O.
- Can feed results to the application in batches (e.g., `onUpdateBatch` callbacks) during this phase.
- Merge results accumulate without being committed to DB yet (deferred batch).
- A single large `commitDeferredBatch` at the end replaces 124 individual commits.

### Phase 3: Upload (parallel/batched)

Upload all changed files, then commit everything to the local DB.

```
changedShards = allMergeResults.where(changed)
uploadAll(changedShards)                      // parallel or batched
commitDeferredBatch()                         // single DB transaction
```

**Key properties:**
- Only changed shards/files are uploaded (skip unchanged ones).
- Uploads can be **parallelized** or **batched**, same as downloads.
- A single `commitDeferredBatch` at the end commits all merged data to the local DB.
- If upload fails partway, no local state has been committed yet → clean retry.

---

## Backend Download Strategies

Each backend implements its own optimal download strategy. The orchestrator provides a list of "what to download" and the backend returns all the data.

### Interface Sketch

```dart
/// Backend provides bulk download capability
abstract class RemoteSyncStorage {
  /// Download multiple datasets in the most efficient way
  /// the backend supports (parallel, batched, sequential).
  Future<Map<DatasetId, RdfDataset>> downloadAllDatasets(
    List<DatasetId> ids,
  );

  /// Upload multiple datasets efficiently.
  Future<void> uploadAllDatasets(
    Map<DatasetId, RdfDataset> datasets,
  );
}
```

### Per-Backend Strategies

| Backend | Download Strategy | Upload Strategy |
|---|---|---|
| **Dir** | Sequential or parallel file reads | Sequential file writes |
| **GDrive** | Batch API (100/request) or parallel | Batch API or parallel |
| **Solid** | Parallel HTTP GETs (configurable concurrency) | Parallel HTTP PUTs |
| **WebDAV** | PROPFIND + parallel GETs | Parallel PUTs |

### Concurrency Control

- Configurable max concurrency per backend (e.g., `maxParallelDownloads: 10`).
- Backends with rate limits (GDrive) can self-throttle.
- Memory pressure managed by streaming or chunked processing for very large datasets.

---

## DB Commit Optimization

### Current: Per-Shard Commits (124×)

```
commitDeferredBatch()  // 6–162ms × 124 = ~1.5–20s total
```

### Proposed: Single Bulk Commit

```
// All merges accumulated during Phase 2
commitDeferredBatch()  // one transaction, ~50–200ms total
```

**Expected savings**: The per-shard commit overhead (measured at 6–162ms per shard, scaling with doc count) is dominated by SQLite transaction overhead. A single transaction for all ~2015 documents should be faster than 124 separate transactions by an order of magnitude.

---

## Interaction with `onUpdateBatch` Callbacks

The application receives merge results via `onUpdateBatch` callbacks during Phase 2. This allows the UI to update progressively even though the sync hasn't completed:

```
Phase 1: Download all          → no callbacks yet
Phase 2: Merge all             → onUpdateBatch fires per shard/batch
Phase 3: Upload + commit       → no callbacks (data already delivered)
```

This maintains the current UX where the user sees data appearing incrementally during sync.

---

## Error Handling & Atomicity

### Download Failures (Phase 1)

- If a subset of downloads fails, the orchestrator can proceed with available data and retry failed downloads.
- Alternatively: fail fast and retry the entire sync (current behavior).
- Backend-specific: transient errors (network timeout) vs. permanent errors (404).

### Merge Failures (Phase 2)

- CRDT merges are deterministic and should not fail. If they do, it's a bug.
- Phase 2 produces merge results but doesn't commit — safe to discard and retry.

### Upload Failures (Phase 3)

- **Critical consideration**: If upload succeeds for some files but fails for others, we have a partially updated remote state.
- **Mitigation**: CRDT semantics guarantee that re-syncing will converge. The next sync cycle will detect and fix inconsistencies.
- **Alternative**: Upload all, then commit locally. If upload fails partway, don't commit. Re-download on next sync to reconcile.
- This is the same trade-off as today (current code uploads per shard and commits per shard — a crash mid-sync leaves partial state too).

### What Changes vs. Current Error Handling

The current approach commits per shard, so a crash after shard 60/124 means 60 shards are committed locally. The three-phase approach commits everything at the end, so a crash before the final commit means nothing is committed locally — but the remote may have partial uploads. In both cases, the next sync converges via CRDT merge.

---

## Open Questions

### 1. Memory Pressure During Phase 1

**Question**: Holding all downloaded data in memory before merging — is that feasible?

**Assessment**: For Chat Essence (~2015 documents, ~1–2 KB each), total in-memory data is ~2–4 MB. Well within limits. For very large datasets (100K+ documents), streaming or chunked processing within Phase 1 may be needed. A pragmatic approach: process one resource type at a time through all three phases.

### 2. Per-Type vs. All-At-Once Processing

**Question**: Should all three phases span the entire sync, or should we run 3 phases per type?

**Option A – Global phases**: Download everything → merge everything → upload everything.
- Maximum parallelism for downloads.
- Maximum batch size for DB commit.
- Highest memory usage.

**Option B – Per-type phases**: For each type: download all its shards → merge → upload.
- Bounded memory per type.
- Still enables parallel downloads within a type.
- Still collapses 62 commits into 1 per type.

Recommend **Option B** as the pragmatic choice — most of the benefit with bounded memory.

### 3. Compatibility with Existing Shard-Based Architecture

**Question**: Does this require changing the file/shard structure?

**Answer**: **No.** This proposal is purely about *execution order* and *batching*. The same shards, indices, and files are read and written — just in a different sequence. This is what makes it an excellent first step before considering structural changes (see Proposal 025).

### 4. Incremental Sync Optimization

**Question**: For incremental sync (only a few shards changed), is 3-phase overkill?

**Assessment**: For incremental sync with 1–3 changed shards, the current sequential approach is fine (no significant overhead). The 3-phase optimization primarily benefits initial sync and large batch updates. The orchestrator can detect "small sync" vs. "large sync" and choose the appropriate path, or simply always use 3-phase (the overhead of parallelizing 2 downloads is negligible).

### 5. Solid Bulk Endpoints

**Question**: Solid Community Server has discussed bulk operations. How would those integrate?

**Assessment**: The `downloadAllDatasets` / `uploadAllDatasets` abstraction naturally accommodates bulk endpoints. A Solid backend could implement `downloadAllDatasets` as either parallel GETs (today) or a single bulk request (future). The orchestrator doesn't need to know.

---

## Expected Impact

### Performance (Initial Sync, Chat Essence)

| Metric | Current | Three-Phase (projected) |
|---|---|---|
| Download | Sequential (124×) | Parallel (e.g., 10 concurrent) |
| Download time | Embedded in 48–54s | ~2–5s (parallel I/O) |
| Merge time | Same | Same (~15s CPU, unchanged) |
| Upload | Sequential (124×) | Parallel (e.g., 10 concurrent) |
| Upload time | Embedded in 48–54s | ~2–5s (parallel I/O) |
| DB commits | 124 × (6–162ms) | 1 × ~100–200ms |
| **Estimated total** | **48–54s** | **~20–25s** (projected) |

**Note**: The merge time is unchanged because CRDT merge is CPU-bound. The savings come entirely from parallelizing I/O and collapsing DB commits.

### Why Not Faster?

The remaining ~15s is CPU time for CRDT merges across ~2015 documents. To go below that, structural changes (fewer files = less per-file overhead, see Proposal 025) or algorithmic optimizations in the merge logic are needed.

---

## Relationship to Other Proposals

- **025 (Flat File Storage Architecture)**: Reduces file count from 263 to ~10–15. Three-phase sync is a prerequisite — it provides the download/merge/upload separation that Flat File mode builds on.
- **015 (Shard-Level File Consolidation)**: Dataset-mode shards. Three-phase sync works with both individual-resource and dataset-mode shards.
- **014 (GDrive Sync Performance)**: Proposed batch APIs. Three-phase download naturally enables batch/parallel regardless of backend.
- **013 (Sync Structure Analysis)**: Documented sequential overhead. This proposal directly addresses it.

---

## Next Steps (if approved)

1. **Refactor `RemoteSyncOrchestrator`** — separate the shard loop into download-collect / merge-all / upload-commit phases.
2. **Add `downloadAllDatasets` / `uploadAllDatasets`** to `RemoteSyncStorage` interface.
3. **Implement parallel download** in Dir backend (simplest to test).
4. **Collapse `commitDeferredBatch`** into a single call after all merges.
5. **Benchmark** — measure actual improvement with Chat Essence app.
6. **Extend to GDrive/Solid backends** with backend-specific parallelism.
