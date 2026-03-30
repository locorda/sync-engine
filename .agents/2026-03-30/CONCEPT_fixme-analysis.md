# FIXME Analysis: Pipeline Async→Sync & Semantics Cleanup

> **Date**: 2026-03-30  
> **Scope**: 5 FIXME comments from `git diff`, covering async elimination, naming semantics, and batching concerns  
> **Principle**: Separate I/O from CPU stages; make CPU stages fully synchronous; batch I/O to minimize round-trips

---

## Table of Contents

1. [FIXME 1 & 2: Make Stages 7 and 11 Synchronous](#fixme-1--2-make-stages-7-and-11-synchronous)
2. [FIXME 3: `prepareIndexEntryWrites` Cost in Stage 9](#fixme-3-prepareindexentrywrites-cost-in-stage-9)
3. [FIXME 4: `remoteRemoved` Semantics in Stage 4](#fixme-4-remoteremoved-semantics-in-stage-4)
4. [FIXME 5: `localOnly` Naming in `backend_pipeline.dart`](#fixme-5-localonly-naming-in-backend_pipelinedart)
5. [Implementation Strategy](#implementation-strategy)

---

## FIXME 1 & 2: Make Stages 7 and 11 Synchronous

### The Problem

Both Stage 7 (`stage7_crdt_merge.dart`) and Stage 11 (`stage11_shard_crdt_merge.dart`) use `asyncExpand` but should use `expand` or `map`. Their doc comments explicitly state the desired fix:

- **Stage 7**: _"should be .expand or .map, but certainly not async. We need to replace all async operations."_
- **Stage 11**: _"should be .expand or .map, but certainly not async. [...] The only async operation is the CRDT merge, which needs to be refactored to be sync (currently it loads the merge contract, which is cached after the meta phase, so it should be a sync cache lookup)."_

Both stages are **CPU stages** in the pipeline — they perform CRDT merging, graph construction, and encoding. No I/O should happen here.

### Root Cause Analysis

#### Stage 7 Async Call Chain

Three `await` calls in `_mergeFetched()`:

| # | Call | Location | Actually Async? | Analysis |
|---|------|----------|-----------------|----------|
| 1 | `mergeContractLoader.load(governanceIris)` | L96 | **No** (during content phase) | `CachingMergeContractLoader` uses `LRUCache<String, Future<MergeContract>>`. After meta phase, all contracts are cached. Interface returns `Future<MergeContract>`. |
| 2 | `merger.merge(...)` | L99-L103 | **No** | `RemoteDocumentMerger.merge()` is `Future<MergeResult> ... async` but the body is **pure CPU**: `OrganizedGraph.fromGraph()`, `ClockComparison.compareClocks()`, `_mergeSubjectsAndProperties()`, `_buildResultDocument()`. **Zero awaits in the body.** |
| 3 | `reconciler.reconcile(...)` | L113 | **Transitively async** | Calls 3 things that are each needlessly async (see below). |

#### `DocumentShardReconciler.reconcile()` Sub-Chain

| Sub-call | Actually Async? | Details |
|----------|-----------------|---------|
| `_shardDeterminer.determineShards()` | **Yes (storage reads)** | Calls `_indexDiscovery.discoverIndices()` → `_getOrLoadIndexConfig()`. Has a two-level cache: watch-based metadata (sync) + LRU parsed config (sync on hit). Cache miss reads from storage via `_storage.getDocument()`. **During content phase, cache should always be warm** from meta phase.  Then calls `_determineShardsForFullIndex` / `_determineShardsForGroupIndex` which each call `_getDocument()` → `_storage.getDocument()` for index document data. |
| `_mergeContractLoader.load()` | **No** (cached) | Same as #1 above — warm cache after meta phase. |
| `_localDocumentMerger.replaceInDocument()` | **No** | Method is declared `Future<RdfGraph> ... async` but body is **pure CPU**: iterates changes, compares triples, calls `mergeContract.getEffectiveMergeWith()` (sync map lookup), `crdtTypeRegistry.getType()` (sync), `crdtType.localValueChange()` (sync), builds `RdfGraph.fromTriples()`. **Zero awaits.** |

#### Stage 11 Async Call Chain

Only one `await` call in `_mergeShardEntries()`:

| # | Call | Location | Actually Async? |
|---|------|----------|-----------------|
| 1 | `documentManager.prepareModify(...)` | L80-L86 | **Transitively** — internally calls `_mergeContractLoader.load()` (cached, effectively sync) and `_computeSave()` which calls `_shardDeterminer.calculateShards()` (storage reads). |

#### Key Insight: `_computeSave` in CrdtDocumentManager

`_computeSave()` at L477 is declared `Future<PreparedDocumentSave?>` and internally calls:
- `_shardDeterminer.calculateShards()` → calls `determineShards()` twice (old + new app data) → each calls `discoverIndices()` + `_determineShardsFor*Index()` → **Storage I/O** via `_getDocument()`.

This is the **real blocker**: while `MergeContractLoader` and `RemoteDocumentMerger` can trivially become sync, the shard determination path has genuine storage dependencies (loading index documents, group index documents, templates).

### Proposed Solution

The solution requires **three layers** of refactoring, from leaf changes to structural changes:

#### Layer 1: Quick Wins — Remove Unnecessary `async`

These methods have zero I/O and can immediately become sync:

1. **`RemoteDocumentMerger.merge()`** → Return `MergeResult` instead of `Future<MergeResult>`. Remove `async` keyword.

2. **`LocalDocumentMerger.replaceInDocument()`** → Return `RdfGraph` instead of `Future<RdfGraph>`. Remove `async` keyword.

These changes are trivial and can be done in isolation. Impact: 2 fewer `await`s in Stage 7.

#### Layer 2: Sync Cache Accessor for `MergeContractLoader`

Add a **synchronous** accessor that retrieves from cache without fallback:

```dart
abstract interface class MergeContractLoader {
  Future<MergeContract> load(List<IriTerm> isGovernedBy);
  
  /// Returns the cached merge contract or throws if not cached.
  /// Safe to call during content phase (all contracts loaded in meta phase).
  MergeContract loadCached(List<IriTerm> isGovernedBy);
  
  // ... existing methods
}
```

`CachingMergeContractLoader` implementation:

```dart
@override
MergeContract loadCached(List<IriTerm> isGovernedBy) {
  final key = _cacheKey(isGovernedBy);
  final cached = _cache[key];
  if (cached == null) {
    throw StateError(
      'MergeContract not cached for $key. '
      'This should only be called during content phase '
      'after meta phase has loaded all contracts.');
  }
  // The cached Future should already be completed during content phase
  // But we need to handle the case where it's still pending
  // Option A: Store completed values separately
  // Option B: Use a sync cache alongside the async one
  ...
}
```

**Problem**: `LRUCache<String, Future<MergeContract>>` stores `Future`s, not resolved values. Two options:

**Option A — Dual Cache** (recommended): Maintain a separate `LRUCache<String, MergeContract>` that gets populated when Futures complete. `loadCached()` reads from this sync cache.

**Option B — Completed Future Check**: Extract value from `Future` using `SynchronousFuture` pattern or `Completer.isCompleted` check. Less clean, Dart futures don't expose this easily.

**Impact**: All `MergeContractLoader` consumers can switch from `await loader.load(...)` to `loader.loadCached(...)` during content phase. This removes 1 `await` in Stage 7, 1 in Stage 11 (via `prepareModify`), and 1 in `DocumentShardReconciler.reconcile()`.

#### Layer 3: Pre-warm Index Discovery and Shard Determination

This is the main challenge. `ShardDeterminer.determineShards()` and `calculateShards()` make genuine storage reads:

1. `_indexDiscovery._getOrLoadIndexConfig()` — loads + parses index document from storage on LRU cache miss
2. `_determineShardsForFullIndex._getDocument()` — loads index document for sharding config
3. `_determineShardsForGroupIndex._getDocument()` — loads template + group index documents

**Why these _should_ be cached during content phase:**
- The meta phase syncs all index-of-indices, so the watch-based metadata caches (`_indexedClassToFullIndexMetadata`, `_indexedClassToTemplateMetadata`) are warm.
- However, the LRU parsed config cache in `_getOrLoadIndexConfig` and the per-request `_getDocument` calls in `_determineShardsFor*` may still miss.

**Proposed approach — Explicit Pre-Warming Between Phases:**

Add a method to `IndexDiscovery` / `ShardDeterminer` that loads and caches all required documents:

```dart
/// Pre-loads all index configurations into the sync cache.
/// Call once before content phase to eliminate async lookups.
Future<void> warmCaches() async {
  // Load all FullIndex configs
  for (final entry in _indexedClassToFullIndexMetadata.values) {
    await _getOrLoadIndexConfig(entry.iri, entry.clockHash, _loadAndParseFullIndex);
  }
  // Load all GroupIndexTemplate configs
  for (final entry in _indexedClassToTemplateMetadata.values) {
    await _getOrLoadIndexConfig(entry.iri, entry.clockHash, _loadAndParseTemplate);
  }
}
```

Similarly, `ShardDeterminer` could pre-load all index documents referenced by the configs.

After warming, provide **sync accessors**:

```dart
/// Synchronous version of discoverIndices — uses only cached data.
/// Throws if cache is not warm (call warmCaches() first).
List<CrdtIndexData> discoverIndicesSync(IriTerm type, {required ShardDeterminationMode mode});
```

**Impact on Stage 7**: With Layers 1-3 complete:
- `mergeContractLoader.loadCached()` — sync
- `merger.merge()` — sync
- `reconciler.reconcile()` — sync (because `determineShards` uses sync caches, `replaceInDocument` is sync, `loadCached` is sync)

Stage 7 becomes `expand`/`map` instead of `asyncExpand`. Same for Stage 11.

**Impact on Stage 11**: With Layer 2 done, `prepareModify` still needs `calculateShards()`. With Layer 3, that becomes sync too. BUT: `_computeSave` in `CrdtDocumentManager` also calls `_shardDeterminer.calculateShards()`. This is the same dependency chain. If Layer 3 is complete, `_computeSave` can also become sync, making `prepareModify` sync.

### Alternative: Move Shard Reconciliation Out of Stage 7

Instead of making everything sync, another approach is to **extract** shard determination into a separate I/O stage:

- **Stage 6.5** (new): Pre-load shard determination data in batch (all index documents, templates, group indices for the batch of resources)
- **Stage 7**: Pure CPU merge using pre-loaded data

This respects the I/O/CPU separation more cleanly. However, it means adding a new stage and passing pre-loaded data through the pipeline, which adds complexity. The cache-warming approach (Layer 3) achieves the same result more elegantly since the data is inherently cacheable and rarely changes during a sync cycle.

**Recommendation**: Layer 3 (cache warming) is preferred. The meta phase already loads all meta-indices, so warming the parsed-config caches is a natural extension. No new pipeline stage needed.

---

## FIXME 3: `prepareIndexEntryWrites` Cost in Stage 9

### The Problem

In Stage 9 (`stage9_db_commit.dart`, L113):
```dart
// FIXME: potentially expensive to prepare index entry writes for every merged document
final indexEntries = await indexManager.prepareIndexEntryWrites(...);
```

`prepareIndexEntryWrites` is called **per document** inside the buffered flush loop. Its cost:

1. **`_createMissingGroupIndex(missing)`** — **Heavy I/O**: Loads template config via `_indexDiscovery`, creates GroupIndex document + shard via `_documentManager.save()`, `_storage.saveIndexEntries()`. Called per missing group index.

2. **`_propertyResolver.resolveIndexedPropertiesBatch(shardDocumentIris)`** — **Storage I/O**: Up to 3 batched storage reads (shard docs, index docs, template docs). Has internal LRU cache (100 entries).

3. **`_buildTombstonedShardEntryWrites(...)`** — **Sync**: Triple extraction and entry construction from the document graph. No I/O.

4. **`_buildShardIndexEntryWrites(...)`** — **Sync**: Property extraction, header property resolution, entry construction per shard. No I/O.

### Analysis

The per-document cost is:
- **0-N calls** to `_createMissingGroupIndex` (typically 0 for existing resources)
- **1 call** to `resolveIndexedPropertiesBatch` (batched within the single document's shards, but repeated across documents)
- **Sync work**: Graph traversal per shard per document — O(shards × properties)

The `_propertyResolver` has LRU caching, so repeated calls for the same shard IRIs hit cache. For a typical sync batch of ~990 resources across a small number of shards, the cache hit rate should be very high after the first few documents.

### Proposed Solution

#### Option A: Batch `resolveIndexedPropertiesBatch` Across Documents (Recommended)

Pre-resolve all indexed properties for all shard IRIs across all documents in the flush batch:

```dart
// In _flush():
// 1. Collect all shard IRIs from all pending documents
final allShardIris = <IriTerm>{};
for (final save in pendingSaves) {
  final shards = save.document.getMultiValueObjectList<IriTerm>(
    save.documentIri, SyncManagedDocument.idxBelongsToIndexShard);
  allShardIris.addAll(shards.map((s) => s.getDocumentIri()));
  // Also collect tombstoned shards
  allShardIris.addAll(_collectTombstonedShards(save.document, save.documentIri)
    .map((s) => s.getDocumentIri()));
}

// 2. Single batch resolve
final resolvedProperties = await propertyResolver.resolveIndexedPropertiesBatch(allShardIris);

// 3. Pass to per-document index entry construction (now sync)
for (final save in pendingSaves) {
  final entries = indexManager.prepareIndexEntryWritesSync(
    document: save.document,
    documentIri: save.documentIri,
    resourceTypeIri: save.typeIri,
    physicalTime: save.metadata.ourPhysicalClock,
    updatedAt: save.metadata.updatedAt,
    missingGroupIndices: save.missingGroupIndices,
    preResolvedProperties: resolvedProperties,
  );
  pendingIndexEntries.addAll(entries);
}
```

This requires:
- A new `prepareIndexEntryWritesSync` variant that accepts pre-resolved properties
- Or refactoring `prepareIndexEntryWrites` to accept an optional `preResolvedProperties` parameter

**Benefit**: 1 batch I/O call per flush instead of N (one per document). The sync construction work stays the same (unavoidable per-document cost).

#### Option B: Lazy Index Entry Preparation

Defer index entry preparation entirely to a post-commit stage. Stage 9 would only save documents and ETags; a new stage would compute and save index entries in batch.

**Downside**: Index entries would be temporarily stale between commit and the lazy update pass. This could cause issues if other pipeline stages or app code relies on up-to-date index entries immediately after commit.

#### Option C: Accept Current Cost

If the `_propertyResolver` LRU cache has a high hit rate (which it should for typical sync batches), the actual I/O cost is:
- First ~10 documents: cache cold → storage reads
- Remaining ~980 documents: cache hot → no I/O

The sync construction work per document (graph traversal, property extraction) is O(shards × indexed_properties) which is generally cheap.

**Recommendation**: **Option A** — batch the property resolution at flush-time. This is a clean optimization that fits the existing batching architecture. The `_createMissingGroupIndex` calls are harder to batch (they're write operations with retry logic), but they're rare (only for newly-discovered group indices).

#### Missing GroupIndex Creation

A separate concern: `_createMissingGroupIndex` in `prepareIndexEntryWrites` creates new GroupIndex documents via `_documentManager.save()`. This is a **write operation inside what should be a read-prepare step**.

**Proposal**: Separate missing GroupIndex creation from index entry preparation:
1. Collect all `missingGroupIndices` across the batch
2. Create them in a single batch before preparing entries
3. Pass the "all group indices exist now" guarantee to the entry preparation (which can then skip the creation check)

This aligns better with the I/O separation principle.

---

## FIXME 4: `remoteRemoved` Semantics in Stage 4

### The Problem

In `stage4_change_detection.dart`, `_handleGone()` (L126-L137):

```dart
// FIXME: Is this really "remoteRemoved"? The resource is removed from 
// the remote shard, but it may still exist in some other shard. This situation
// here actually says nothing about the resource's state, only about the shard's state!
SyncDirection.remoteRemoved,
```

When a shard returns HTTP 404/410 (`ShardResultGone`), all local index entries for that shard get classified as `SyncDirection.remoteRemoved`. But this is **semantically wrong**:
- The _shard_ is gone, not the _resource_
- The resource may still exist in other shards (e.g., a resource belongs to both a FullIndex shard and a GroupIndex shard)
- `remoteRemoved` suggests the resource should be deleted/cleaned up, but only the shard association is gone

### Current Impact

In Stage 7, `remoteRemoved` is handled as:
```dart
case SyncDirection.remoteRemoved:
  // TODO: Apply proper deletion semantics
  if (localGraph == null) return;
  mergedGraph = localGraph;
```

So currently, `remoteRemoved` just passes through the local graph unchanged. The `TODO` indicates proper deletion handling isn't implemented yet.

In `backend_pipeline.dart`, `remoteRemoved` is treated as pass-through (no remote fetch needed), which is correct — there's no remote data to fetch.

### Analysis

The fundamental issue is that `SyncDirection` conflates two different classification dimensions:

1. **Resource-level direction**: Is this resource new remotely, new locally, or conflicting?
2. **Shard-level state**: Is the shard the resource was in still present?

A gone shard doesn't tell us about the resource's fate — we'd need to check other shards to know if the resource still exists somewhere.

### Proposed Solution

#### Option A: Rename to Better Reflect Semantics (Minimal Change)

Rename `remoteRemoved` to `shardGone` and update documentation:

```dart
enum SyncDirection {
  remoteOnly,
  localOnly,
  conflictCandidate,
  /// The shard containing this resource's index entry was removed remotely (404/410).
  /// The resource itself may still exist in other shards — this only indicates
  /// the shard is gone. The resource needs to be re-uploaded to a valid shard.
  shardGone,
}
```

**Advantage**: Minimal code change, communicates actual semantics.

#### Option B: Drop `remoteRemoved` / `shardGone` Entirely (Consider Carefully)

When a shard is gone, the entries should still be uploaded to _some_ shard. The shard reconciliation in Stage 7 already handles re-assigning resources to valid shards via `reconciler.reconcile()`. So the behavior for `shardGone` could be identical to `localOnly`: the local version needs to be uploaded, no remote fetch needed.

This would mean merging `remoteRemoved` into `localOnly` — both mean "no useful remote state, local state should be uploaded."

**Risk**: There might be future semantics where shard-gone requires different handling (e.g., checking if the resource was intentionally deleted by another installation removing a shard). But that's speculative and currently unimplemented.

#### Option C: Add Shard-Level Classification Alongside Resource-Level (Full Solution)

Split the classification into two orthogonal dimensions:

```dart
enum ResourceDirection {
  remoteOnly,
  localOnly,
  conflict,
}

enum ShardState {
  present,
  notModified,
  gone,
}
```

`SyncCandidate` would carry both. Pipeline stages could make decisions based on the dimension they care about.

**Downside**: More complex, may be over-engineering for the current use case.

**Recommendation**: **Option A** (`shardGone`) as immediate fix. This aligns with the broader `SyncDirection` refactoring proposed in FIXME 5 — see that section for the complete 5-value enum design that splits `localOnly` into `remoteUnchanged` + `notInRemoteShard` and renames `remoteRemoved` to `shardGone`.

---

## FIXME 5: `localOnly` Naming in `backend_pipeline.dart`

### The Problem

In `backend_pipeline.dart` (L157-L163):

```
FIXME: I wonder if this is correct - or maybe: I rather
wonder if localOnly and remoteRemoved are set correctly.
Maybe it is also the wording that irritates me, because
localOnly rather means remoteUnchanged, no? And it does
not really matter if remote has an older state we already
incorporated or if it did not exist yet.
```

### Analysis

`localOnly` is assigned in **two** separate code paths in Stage 4:

#### Path 1: `_handleNotModified` (L112-L131) — "Remote shard unchanged"

```dart
/// ShardNotModified: emit localOnly for locally-changed entries.
Stream<SyncCandidateEvent> _handleNotModified(...) async* {
  final localEntries = await storage.getActiveIndexEntriesForShard(result.shardIri);
  for (final entry in localEntries) {
    if (entry.updatedAt > lastSyncTimestamp) {
      yield SyncCandidate(
        entry.resourceIri, ...,
        SyncDirection.localOnly, // ← HERE
      );
    }
  }
}
```

This fires when the shard returned HTTP 304 (Not-Modified). The **remote shard exists and is unchanged** — we already have its data. Only locally-modified entries need uploading. This is genuinely **"remoteUnchanged"** semantics.

#### Path 2: `_classify` (L273-L278) — "Not in remote shard entries"

```dart
if (existsLocally && !existsRemotely) {
  return SyncCandidate(..., SyncDirection.localOnly, ...);
}
```

This fires when a resource exists in the local index for this shard but **not** in the remote shard's parsed entries. Possible scenarios:
1. **New local resource**: Created locally, never synced → not in any remote shard yet
2. **Resource moved to different shard**: Shard recalculation moved it
3. **Remote has older version we already incorporated**: Resource was removed from this shard by another installation

This is **"notInRemoteShard"** semantics — different from "remoteUnchanged."

### The Core Problem

**`localOnly` conflates two semantically distinct situations under one enum value:**

| Code Path | Actual Meaning | Remote Shard State | Resource in Remote Shard? |
|-----------|----------------|-------------------|--------------------------|
| `_handleNotModified` | Remote is unchanged, we have local changes to upload | Exists, HTTP 304 | **Yes** (shard not re-parsed, so we don't check entries) |
| `_classify` | Resource not found in remote shard entries | Exists, HTTP 200 parsed | **No** |

Both result in the same pipeline behavior (no remote fetch, use local graph, upload), but they represent fundamentally different situations. Giving them distinct values would:
- Make pipeline code self-documenting
- Enable future differentiated handling (e.g., different upload strategies)
- Resolve the naming confusion the FIXME describes

### Connection to FIXME 4

This is the same naming/semantics issue as `remoteRemoved`. All three (`localOnly`-from-304, `localOnly`-from-classify, `remoteRemoved`) mean "no useful remote data for this resource in this shard — use local state." The distinction is _why_ there's no remote data:
- `_handleNotModified`: remote shard unchanged (304), local entries modified since last sync
- `_classify`: resource not in remote shard entries (parsed 200 response)
- `_handleGone`: entire shard gone (404/410)

From the pipeline's current handling, they're treated identically: pass-through (no remote fetch), use local graph, needs upload.

### Proposed Solution: Three Distinct Enum Values (Recommended)

Split `localOnly` into two values and rename `remoteRemoved`:

```dart
enum SyncDirection {
  /// New from remote — not present locally.
  remoteOnly,

  /// Remote shard unchanged (HTTP 304), resource was locally modified
  /// since last sync. No remote merge needed — upload local state.
  remoteUnchanged,

  /// Resource exists locally but not in the remote shard's entries
  /// (parsed HTTP 200). Could be a new local resource never synced,
  /// a resource that moved shards, or a resource removed from this
  /// shard by another installation. Upload local state.
  notInRemoteShard,

  /// Both sides have different clockHash — needs merge.
  conflictCandidate,

  /// The entire shard was removed remotely (HTTP 404/410).
  /// Resources may still exist in other shards.
  /// Similar to notInRemoteShard: upload local state.
  shardGone,
}
```

This gives us 5 values instead of 4, with clear semantics for each:

| Value | Source | Means |
|-------|--------|-------|
| `remoteOnly` | `_classify` | New remote resource, fetch + save |
| `remoteUnchanged` | `_handleNotModified` | Shard not changed, upload local modifications |
| `notInRemoteShard` | `_classify` | Entry missing from remote shard, upload |
| `conflictCandidate` | `_classify` | Clock hashes differ, needs CRDT merge |
| `shardGone` | `_handleGone` | Entire shard removed remotely |

#### Pipeline Impact

In `backend_pipeline.dart` the pass-through condition becomes clearer:

```dart
if (event.candidate.direction == SyncDirection.remoteUnchanged ||
    event.candidate.direction == SyncDirection.notInRemoteShard ||
    event.candidate.direction == SyncDirection.shardGone) {
  passThrough.add(event); // No remote fetch needed
}
```

In Stage 7, all three no-remote-data cases can share handling:

```dart
case SyncDirection.remoteUnchanged:
case SyncDirection.notInRemoteShard:
  mergedGraph = localGraph!;

case SyncDirection.shardGone:
  // TODO: Apply proper deletion semantics
  if (localGraph == null) return;
  mergedGraph = localGraph;
```

#### Alternative: Group via Helper

If 3 values with identical handling feels redundant, a helper getter keeps it DRY:

```dart
enum SyncDirection {
  remoteOnly, remoteUnchanged, notInRemoteShard, conflictCandidate, shardGone;

  /// True when no useful remote data exists — local state should be uploaded.
  bool get isLocalUploadOnly => switch (this) {
    remoteUnchanged || notInRemoteShard || shardGone => true,
    remoteOnly || conflictCandidate => false,
  };
}
```

Then pipeline code uses `event.candidate.direction.isLocalUploadOnly` instead of listing all three values.

---

## Implementation Strategy

### Phase 1: Quick Wins (No Architectural Changes)

1. **Remove `async` from `RemoteDocumentMerger.merge()`** — Change return type to `MergeResult`, remove `async` keyword. All callers change from `await merger.merge(...)` to `merger.merge(...)`.

2. **Remove `async` from `LocalDocumentMerger.replaceInDocument()`** — Change return type to `RdfGraph`, remove `async` keyword. All callers update.

3. **Refactor `SyncDirection` enum** — Split `localOnly` into `remoteUnchanged` (from `_handleNotModified`) and `notInRemoteShard` (from `_classify`). Rename `remoteRemoved` to `shardGone`. Add `isLocalUploadOnly` helper getter. Update all references across pipeline stages and `backend_pipeline.dart`.

**Impact**: Stage 7 and 11 still need `asyncExpand` (due to merge contract + shard determination), but 2 of the 5 async calls are eliminated.

### Phase 2: Sync Merge Contract Loading

4. **Add sync cache to `CachingMergeContractLoader`** — Maintain a separate `LRUCache<String, MergeContract>` for resolved values. Populate when `Future` completes. Add `MergeContract loadCached(List<IriTerm>)` to interface.

5. **Switch content-phase callers to `loadCached()`** — Stage 7, Stage 11 (`prepareModify`), `DocumentShardReconciler`. Keep `load()` for meta-phase and cold-start scenarios.

**Impact**: 3 more `await`s eliminated (one each in Stage 7 `_mergeFetched`, `DocumentShardReconciler.reconcile`, `CrdtDocumentManager.prepareModify`).

### Phase 3: Sync Index Discovery / Shard Determination

6. **Add `warmCaches()` to `IndexDiscovery`** — Pre-load all index configs from storage into LRU cache after meta phase completes.

7. **Add sync accessors to `IndexDiscovery` and `ShardDeterminer`** — `discoverIndicesSync()`, `determineShardsSync()`. These read only from warm caches and throw on cache miss.

8. **Pre-load index documents for `ShardDeterminer._getDocument()`** — Either warm a cache with all index/template/group-index documents, or provide a sync `getDocumentSync()` accessor on storage. The former is preferable (bounded set of documents).

9. **Call `warmCaches()` between meta and content phases** in the pipeline orchestrator.

**Impact**: `reconciler.reconcile()` becomes fully sync. `prepareModify` becomes fully sync. Stage 7 becomes `expand`. Stage 11 becomes `expand`.

### Phase 4: Batch Index Entry Preparation in Stage 9

10. **Pre-resolve indexed properties at flush-time** — Collect all shard IRIs from the flush batch, call `resolveIndexedPropertiesBatch()` once, pass results to per-document entry construction.

11. **Separate missing GroupIndex creation from entry preparation** — Create missing GroupIndices in a dedicated batch step before entry construction.

12. **Add `prepareIndexEntryWritesSync(preResolvedProperties: ...)` variant** — Pure CPU version that uses pre-resolved data, no I/O.

**Impact**: Stage 9 flush goes from N property-resolution calls to 1 batched call per flush.

### Dependency Graph

```
Phase 1 (Quick Wins)
├── 1. merger.merge() → sync           [independent]
├── 2. replaceInDocument() → sync      [independent]
└── 3. SyncDirection rename            [independent]

Phase 2 (Sync MergeContract)
└── 4. Dual cache + loadCached()       [independent]
    └── 5. Switch callers              [depends on 4]

Phase 3 (Sync Index Discovery)
├── 6. warmCaches()                    [independent]
├── 7. Sync accessors                  [depends on 6]
├── 8. Pre-load index docs             [depends on 6]
└── 9. Wire up in orchestrator         [depends on 6, 7, 8]
    └── Stage 7/11 → expand            [depends on 1, 2, 5, 9]

Phase 4 (Batch Index Entries)
├── 10. Pre-resolve at flush-time      [independent]
├── 11. Separate GroupIndex creation    [independent]
└── 12. Sync prepareIndexEntryWrites   [depends on 10, 11]
```

### Risks and Considerations

- **Cache Invalidation**: If index documents change _during_ a content phase (e.g., GroupIndex creation by `_createMissingGroupIndex`), pre-warmed caches could become stale. Mitigation: GroupIndex creation should also update the warm caches when it writes new documents.

- **First Sync (Cold Start)**: On very first sync, the meta phase data may not be complete. Sync accessors must handle this gracefully — either fall back to async loading or skip shard determination for the first cycle.

- **Testing**: Each phase should have dedicated tests verifying the sync behavior under warm-cache conditions, and that cache-miss throws `StateError` with a clear message rather than silently returning wrong data.

- **`_computeSave` in `CrdtDocumentManager`**: This is called from both pipeline stages AND from local save operations (app saves). For local saves, caches may not be warm. Solution: Keep async `_computeSave` for local saves, add `_computeSaveSync` for pipeline use, or always warm caches on `SyncEngine` initialization.
