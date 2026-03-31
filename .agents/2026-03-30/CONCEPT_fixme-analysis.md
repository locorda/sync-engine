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

### Proposed Solution: Explicit Pipeline Data Passing

> **Rejected approach**: Implicit cache-warming between phases was considered but rejected as too implicit and fragile. It violates the pipeline's data-passing principle — pipeline stages should receive their data explicitly, not depend on warm caches from prior stages.
>
> **Chosen approach**: Split Stage 7 into explicit sub-stages that separate parsing (CPU), preloading (I/O), and merging (CPU). Stage 11 uses `asyncMap` with LRU cache.

#### Prerequisites: Remove Unnecessary `async` (Already Done)

These methods had zero I/O and have been made sync by user:

1. **`RemoteDocumentMerger.merge()`** — now returns `MergeResult` (pure CPU)
2. **`LocalDocumentMerger.replaceInDocument()`** — now returns `RdfGraph` (pure CPU)

#### Stage 7 → Split into 7a / 7b / 7c

| Sub-Stage | Type | Operator | What |
|-----------|------|----------|------|
| **7a** | CPU | `.map()` | Decode RDF sources (Jelly bytes → `RdfGraph`) |
| **7b** | I/O | `.transform()` | Batch-preload MergeContracts + Index data |
| **7c** | CPU | `.expand()` | CRDT merge + shard reconciliation + encoding |

##### 7a — Parse (`stage7a_parse.dart`)

- Per-element `.map()`, no batching needed
- Decodes `remoteSource?.decodeWith(rdfCore)` and `localSource?.decodeWith(rdfCore)`
- Input: `FetchedCandidateEvent` → Output: `ParsedCandidateEvent`

##### 7b — Preload (`stage7b_preload.dart`)

- `StreamTransformer` with batch accumulation
- Collects unique type IRIs + governance IRI sets from parsed graphs
- Batch-loads:
  1. `discoverIndices(type)` per unique type (~3 calls for ~3 types)
  2. Index/Template documents for sharding configs (~3-6 reads, per-type)
  3. `mergeContractLoader.load()` per unique governance IRI set
  4. **[OPEN]** GroupIndex documents for existence checks — see [Open Design Decision](#open-design-decision-groupindex-existence-checks) below
- All loaded data packaged into a shared `BatchPreloadedData` struct
- Input: `ParsedCandidateEvent` → Output: `PreloadedCandidateEvent`

##### 7c — CRDT Merge (`stage7c_crdt_merge.dart`)

- Pure CPU, sync `.expand()`
- Uses pre-loaded data for all lookups (no storage access)
- `DocumentShardReconciler` gets sync variant accepting `BatchPreloadedData`
- `ShardDeterminer` gets sync variant — map lookup instead of storage read
- Input: `PreloadedCandidateEvent` → Output: `MergedResourceEvent`

##### Why Preloading Is Feasible

Storage reads in `determineShards()` are **per-type**, not per-document:

| Read | Granularity | Count for 990 docs / 3 types |
|------|-------------|------------------------------|
| `discoverIndices(type)` | per-type | ~3 (watch-cached, often sync) |
| FullIndex document (sharding config) | per-index | ~3 |
| GroupIndexTemplate document | per-template | ~3 |
| GroupIndex existence check | per-group-key | varies, bounded, shared across docs |

Total: ~10-20 storage reads to preload everything for a batch of 990 documents.

##### New Data Types

```dart
/// Pre-loaded I/O data shared across a batch, computed in Stage 7b.
class BatchPreloadedData {
  /// MergeContracts keyed by governance IRI set (joined with |).
  final Map<String, MergeContract> mergeContracts;

  /// Index configs per resource type.
  final Map<IriTerm, List<CrdtIndexData>> indexConfigsByType;

  /// Pre-loaded index/template documents for shard determination.
  /// Key: document IRI → value: StoredDocument? (null = confirmed missing).
  /// Note: GroupIndex documents are NOT included — existence checks are
  /// deferred to Stage 9 (I/O stage). Only FullIndex + GroupIndexTemplate docs.
  final Map<IriTerm, StoredDocument?> indexDocuments;
}
```

```dart
/// Stage 7a output: FetchedCandidate + decoded RdfGraphs.
class ParsedCandidate implements ParsedCandidateEvent {
  final FetchedCandidate fetched;
  final RdfGraph? remoteGraph;
  final RdfGraph? localGraph;
}

/// Stage 7b output: ParsedCandidate + shared batch preloaded data.
class PreloadedCandidate implements PreloadedCandidateEvent {
  final ParsedCandidate parsed;
  final BatchPreloadedData preloadedData;
}
```

#### Stage 11 → Split into 11a / 11b / 11c

Same structural split as Stage 7, but 11b is simpler — no batch-accumulating transformer needed.

| Sub-Stage | Type | Operator | What |
|-----------|------|----------|------|
| **11a** | CPU | `.map()` | Extract governance IRIs from shard doc, build shard document from entries |
| **11b** | I/O | `.asyncMap()` | Load MergeContract per governance IRI set (LRU cached) |
| **11c** | CPU | `.expand()` | CRDT merge with loaded contract, encode |

##### Why 11b doesn't need a batching transform

- `calculateShards()` is a **no-op** for `IdxShard.classIri` — shards are not indexed into other shards
- The only remaining I/O is `_mergeContractLoader.load()` for shard governance IRIs
- **Different shards may reference different governance versions** — different Locorda versions or apps may have written shards with different `sync:isGovernedBy` triples. We cannot assume a single MergeContract for all shards.
- However, the number of distinct governance IRI sets is **very small** (~2-3 Locorda versions in a deployment)
- The `MergeContractLoader` already has an LRU cache → first shard per governance set triggers a load, all subsequent shards hit cache (microseconds)
- A full batch-preload transformer would add complexity for negligible benefit

##### Refactoring needed

`CrdtDocumentManager.prepareModify()` needs a new variant:

- `prepareModifyWithContract()` — accepts pre-loaded `MergeContract` as parameter
- Skips `calculateShards()` for `IdxShard.classIri`
- Returns sync result (no remaining I/O)

```dart
// Stage 11a: .map() — CPU
.map(shardPrepare(shardDocGen))              // extract governance IRIs, build shard triples

// Stage 11b: .asyncMap() — I/O (LRU cached)
.asyncMap(shardContractLoad(mergeContractLoader))  // load MergeContract per governance set

// Stage 11c: .expand() — CPU
.expand(shardCrdtMerge(documentManager, rdfCore))  // CRDT merge + encode
```

#### Resolved: GroupIndex Existence Checks → "Required Group Indices" (Deferred to Stage 9)

**Decision**: Option C — skip existence check in 7c entirely, defer to Stage 9.

##### Rationale

`_determineShardsForGroupIndex` currently loads GroupIndex documents per group-key to check existence (`_getDocument`). This is the **last remaining storage I/O** blocking 7c from being pure CPU. But:

1. The shard IRI is calculated **regardless** of existence — it only needs the template sharding config + `hash(resourceIri)`.
2. "Exists" means "this installation has this GroupIndex document locally" — a simple existence check, not a content read.
3. The number of groups is **not bounded** — the framework must not assume anything about group count.
4. The existence check is naturally an I/O operation that belongs in an I/O stage, not a CPU stage.

##### Design

- **`MissingGroupIndex` is eliminated.** `ResolvedGroupIndex` already captures all needed fields (identical structure).
- **`_determineShardsForGroupIndex`** drops the `_getDocument` existence check entirely. It produces only `resolvedGroupIndices` — pure CPU from group keys + template sharding config.
- **`DocumentSaveResult` and `PreparedDocumentSave`** lose the `missingGroupIndices` field. Only `resolvedGroupIndices` is carried.
- **`ShardDeterminationResult`** loses `missingGroupIndices` field.

##### Where existing GroupIndex creation moves

**Stage 9 (pipeline path):** `prepareIndexEntryWrites` receives `resolvedGroupIndices` (instead of `missingGroupIndices`). It does a **batched existence check** across all required group indices in the flush batch, then creates only those that don't exist locally. This is the shared implementation.

**Non-pipeline path (`IndexManager._save` → `updateIndices`):** Calls the **same** `prepareIndexEntryWrites` method with `resolvedGroupIndices`. No separate code path — the method handles the batched existence check + creation internally. The method is already async, so no wrapper needed.

##### Code sharing principle

`prepareIndexEntryWrites(resolvedGroupIndices: ...)` is the single method that both pipeline and non-pipeline paths call. It:

1. Collects all `groupIndexIri` from `resolvedGroupIndices`
2. Batched existence check: `storage.hasDocuments(groupIndexIris)` (or equivalent batch API)
3. Creates missing ones via existing `_createMissingGroupIndex` logic (adapted to take `ResolvedGroupIndex`)
4. Proceeds with index entry construction

This avoids copy-paste between pipeline and non-pipeline paths — the sync shard determination method (shared) produces `resolvedGroupIndices`, and the async `prepareIndexEntryWrites` (shared) handles the deferred existence check. To be discussed.

---

## FIXME 3: `prepareIndexEntryWrites` Cost in Stage 9

> **Updated 2026-03-31**: Complete redesign — move index entry preparation into the pipeline's explicit data-passing model. CPU work moves to Stage 7c, I/O stays batched in Stage 9. No implicit cache-sharing between stages.

### The Problem

In Stage 9 (`stage9_db_commit.dart`, L113):
```dart
// FIXME: potentially expensive to prepare index entry writes for every merged document
final indexEntries = await indexManager.prepareIndexEntryWrites(...);
```

`prepareIndexEntryWrites` is called **per document** inside the buffered flush loop. It mixes CPU work (graph traversal, property extraction, request building) with I/O work (property resolver storage reads, GroupIndex existence checks, GroupIndex creation).

### What `prepareIndexEntryWrites` Does (Decomposition)

| # | Step | CPU/I/O | Input | Notes |
|---|------|---------|-------|-------|
| 1 | GroupIndex existence check | **I/O Read** | `resolvedGroupIndices` | `storage.getDocumentsByIri(groupIndexIris)` |
| 2 | Create missing GroupIndices | **I/O Write** | missing from step 1 | Loads template, generates graph, saves document + shard |
| 3 | Extract shard IRIs from graph | CPU | merged graph | `getMultiValueObjectList(belongsToIndexShard)` |
| 4 | Extract clockHash, resourceIri, type | CPU | merged graph | **Redundant** — all already available in `MergeResult` |
| 5 | Collect tombstoned shards | CPU | merged graph | Reified statement traversal for `crdt:deletedAt` |
| 6 | Resolve indexed properties | **I/O Read** | shard doc IRIs | Traverses shard→index→template hierarchy. LRU cached. |
| 7 | Build tombstone `SaveIndexEntryRequest`s | CPU | tombstoned shards + resolved properties | Needs `indexIri` per tombstoned shard |
| 8 | Build active `SaveIndexEntryRequest`s | CPU | active shards + resolved properties | Extracts header properties, builds requests |

### Key Insights (from analysis)

1. **clockHash is NOT computed here** — `RemoteDocumentMerger.merge()` computes it in 7c and writes it as a `crdt:clockHash` triple into the merged graph. `prepareIndexEntryWrites` redundantly re-reads it from the graph. We already have `mergeResult.clock.hash` as an explicit value.

2. **Indexed properties can be extracted from already-loaded data** — Stage 7b already loads Index and Template documents via `collectRequiredDocumentIris` + `storage.getDocumentsByIri`. The `IndexPropertyResolver` logic (shard→index→template→`idx:indexedProperty`) traverses the same documents. We can extract indexed properties in 7b from already-loaded docs and pass them through explicitly.

3. **Tombstone `indexIri` is available from the DB** — The `IndexEntries` table stores `indexIriId` per (shard, resource) pair. For tombstoned shards, we can look up the `indexIri` from existing index entries instead of traversing shard documents. No I/O into shard documents needed.

4. **Shard→Index mapping is produced by `determineShards`** — `_determineShardsForFullIndex` and `_determineShardsForGroupIndex` already know which shardIri maps to which indexIri (they generate both). This mapping just isn't returned today.

5. **Principle: Pipeline stages pass data explicitly** — No implicit cache-warming between stages. 7b loads, 7c computes, data flows through `MergeResult` to Stage 9. Stage 9 only does batched DB commits.

### Chosen Solution: Explicit Data Flow Through Pipeline

#### Overview

| Stage | What changes |
|-------|-------------|
| **7b** | Extract indexed properties from already-loaded Index/Template docs. Pass through `PreloadedCandidate`. |
| **7c** | Build `List<SaveIndexEntryRequest>` for **active** shards (pure CPU). Build tombstoned shard IRI list (pure CPU). Both added to `MergeResult`. |
| **9** | For active shards: just `pendingIndexEntries.addAll(mergeResult.indexEntries)` — no `await`. For tombstones: batch-resolve `indexIri` from DB (1 query per flush), build tombstone requests, add to batch. GroupIndex existence check: batched per flush. |

#### Step 1: Indexed Properties in 7b (I/O, already loaded)

Stage 7b already loads Index and Template documents. We add extraction of indexed properties from these same documents:

```dart
// In preloadChunk() — after loading index/template documents:
final indexedProperties = <IriTerm, Set<IriTerm>>{};
for (final candidate in chunk) {
  final configs = indexConfigCache[candidate.typeIri]!;
  for (final config in configs) {
    final indexOrTemplateIri = switch (config) {
      FullIndexData() => shardDeterminer.generateFullIndexIri(config, candidate.typeIri),
      GroupIndexData() => shardDeterminer.generateGroupIndexTemplateIri(config, candidate.typeIri),
    };
    if (!indexedProperties.containsKey(indexOrTemplateIri)) {
      final docIri = indexOrTemplateIri.getDocumentIri();
      final doc = loadedDocs[docIri];
      if (doc != null) {
        indexedProperties[indexOrTemplateIri] =
            IndexPropertyResolver.extractIndexedProperties(doc.document, indexOrTemplateIri);
      }
    }
  }
}
```

`PreloadedCandidate` gets new field: `Map<IriTerm, Set<IriTerm>> indexedProperties`.

`IndexPropertyResolver._extractIndexedProperties()` needs to become a public static method (no state dependency — pure graph traversal).

#### Step 2: `shardToIndex` Mapping from `ShardDeterminer` (no code change needed)

`determineShards()` already returns `ShardDeterminationResult` with `shards` and `resolvedGroupIndices`. The mapping from shard→index is implicit:

- **FullIndex**: shardIri is generated from `fullIndexIri` → the index IRI can be extracted from the sharding config that produced the shard IRI.
- **GroupIndex**: shardIri is generated from `groupIndexIri` → available via `resolvedGroupIndices[].groupIndexIri`.

**Proposal**: Add `Map<IriTerm, IriTerm> shardToIndex` to `ShardDeterminationResult`. `_determineShardsForFullIndex` and `_determineShardsForGroupIndex` already compute both IRIs — they just discard the mapping.

#### Step 3: Build Active Index Entries in 7c (CPU)

After reconciliation in 7c, we have everything needed for active `SaveIndexEntryRequest`s:

- `reconciled.graph` → extract `idx:belongsToIndexShard` triples (shard IRIs)
- `mergeResult.clock.hash` → clockHash
- `shardToIndex` map → indexIri per shard
- `indexedProperties` from 7b → which properties to include in headers
- `reconciled.graph` → extract header property values

```dart
// In 7c _merge(), after reconciliation:
final activeIndexEntries = _buildActiveIndexEntries(
  reconciled, d, preloaded.indexedProperties, shardToIndex);
```

No I/O needed — all data explicitly pre-loaded.

#### Step 4: Tombstone Handling (Partially in 7c, Partially in 9)

**CPU part (7c)**: Extract tombstoned shard IRIs from the reconciled graph. These are reified `idx:belongsToIndexShard` statements with `crdt:deletedAt`. This is pure graph traversal — the old shard IRIs were already present as active or tombstoned triples in the local/remote graph before merge; reconciliation may create new tombstones when shard assignments change.

**I/O part (9)**: For each tombstoned shard IRI, look up the corresponding `indexIri` from the `IndexEntries` DB table (which already stores `indexIriId` per shard+resource pair). This is a single batched DB query per flush. Then build `SaveIndexEntryRequest(isDeleted: true)` entries.

`MergeResult` gets new fields:
- `List<SaveIndexEntryRequest> indexEntries` — active shard entries (built in 7c)
- `Set<IriTerm> tombstonedShardIris` — shard IRIs with CRDT deletion tombstones (extracted in 7c)

#### Step 5: GroupIndex Existence Check + Creation (Batched in 9)

GroupIndex existence check and creation stays in Stage 9 (it's I/O Write), but **batched** per flush:

1. Collect all `resolvedGroupIndices` from all `MergeResult`s in the pending batch
2. Deduplicate by `groupIndexIri`
3. Single batched `storage.getDocumentsByIri(allGroupIndexIris)` for existence check
4. Create missing ones (reuse `_createMissingGroupIndex` logic)

This replaces the current per-document call.

#### Resulting Stage 9

```dart
// Simplified Stage 9 — no per-document I/O for index entries:
case UploadResult():
  final mergeResult = event.mergeResult;
  if (mergeResult.needsDbWrite) {
    pendingSaves.add(SaveDocumentRequest(...));
    pendingIndexEntries.addAll(mergeResult.indexEntries);
    pendingTombstones.addAll(mergeResult.tombstonedShardIris.map(
        (shardIri) => (shardIri: shardIri, resourceIri: mergeResult.resourceIri, typeIri: mergeResult.typeIri)));
    pendingResolvedGroupIndices.addAll(mergeResult.resolvedGroupIndices);
  }
  // ...

// In _flush():
// 1. Batch-resolve tombstone indexIris from DB (1 query)
// 2. Build tombstone SaveIndexEntryRequests
// 3. Batched GroupIndex existence check + creation
// 4. Atomic transaction: saveDocuments + saveIndexEntries + setRemoteETags
```

### Impact on Non-Pipeline Path

The classical (non-pipeline) sync path in `remote_sync_orchestrator.dart` continues to use the existing `prepareIndexEntryWrites` method unchanged — it's async and handles its own I/O. The refactoring only affects the pipeline path.

### Required API Changes

| Component | Change |
|-----------|--------|
| `IndexPropertyResolver._extractIndexedProperties` | Make **public static** (pure graph traversal, no state) |
| `ShardDeterminationResult` | Add `shardToIndex: Map<IriTerm, IriTerm>` |
| `_determineShardsForFullIndex/GroupIndex` | Populate `shardToIndex` mapping |
| `PreloadedCandidate` | Add `indexedProperties: Map<IriTerm, Set<IriTerm>>` |
| `MergeResult` | Add `indexEntries: List<SaveIndexEntryRequest>`, `tombstonedShardIris: Set<IriTerm>` |
| `IndexManager` | New method for batched tombstone `indexIri` lookup by shard+resource, new method for batched GroupIndex existence check + creation |

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

> **Updated 2026-03-30**: Replaced implicit cache-warming approach with explicit pipeline data passing. Stage 7 splits into 7a/7b/7c. Stage 11 uses `asyncMap` with LRU cache.

### Phase 1: Pipeline Types & Stage 7a (Parse)

1. Add new sealed event types to `pipeline_types.dart`:
   - `ParsedCandidateEvent` (sealed: `ParsedCandidate`, `PhaseComplete`, `ShardComplete`)
   - `PreloadedCandidateEvent` (sealed: `PreloadedCandidate`, `PhaseComplete`, `ShardComplete`)
2. Add `ParsedCandidate` data class (fetched + decoded graphs)
3. Create `stage7a_parse.dart` — trivial `.map()` decoder
4. Wire into orchestrator between Stage 6 output and Stage 7b

### Phase 2: BatchPreloadedData & Stage 7b (Preload)

5. Define `BatchPreloadedData` class with:
   - `Map<String, MergeContract> mergeContracts`
   - `Map<IriTerm, List<CrdtIndexData>> indexConfigsByType`
   - `Map<IriTerm, StoredDocument?> indexDocuments`
6. Add `PreloadedCandidate` data class (parsed + shared preloaded data)
7. Create `stage7b_preload.dart` — `StreamTransformer` that:
   - Accumulates parsed events up to batch boundary (`PhaseComplete`/`ShardComplete`)
   - Extracts unique type IRIs + governance IRI sets from parsed graphs
   - Batch-loads: `discoverIndices(type)`, index/template docs, MergeContracts
   - GroupIndex existence checks are **not** done here — deferred to Stage 9 (see resolved design decision above)
   - Emits `PreloadedCandidate` events with shared `BatchPreloadedData`

### Phase 3: Sync Variants & Stage 7c (CRDT Merge)

8. Add sync variant to `ShardDeterminer`:
   - `ShardDeterminationResult determineShardsFromPreloaded(...)` — uses `BatchPreloadedData` maps instead of storage reads
9. Add sync variant to `DocumentShardReconciler`:
   - `ReconciledDocument reconcileFromPreloaded(...)` — uses `BatchPreloadedData` for both MergeContract and shard determination
10. Refactor `stage7_crdt_merge.dart` → `stage7c_crdt_merge.dart`:
    - Input changes from `FetchedCandidateEvent` to `PreloadedCandidateEvent`
    - All lookups use `BatchPreloadedData` maps
    - `.asyncExpand()` → `.expand()`
11. Update orchestrator pipeline composition

### Phase 4: Stage 11 (11a / 11b / 11c Split)

12. Add `prepareModifyWithContract()` to `CrdtDocumentManager`:
    - Accepts pre-loaded `MergeContract` as parameter (no internal load)
    - Skips `calculateShards()` for `IdxShard.classIri` (shards don't belong to other shards)
    - Returns sync result (no remaining I/O)
13. Create `stage11a_shard_prepare.dart` — `.map()`:
    - Extract governance IRIs from shard document (remote or local)
    - Build shard entry triples via `ShardDocumentGenerator`
    - Output: `PreparedShardEvent` with governance IRIs + assembled triples
14. Create `stage11b_shard_contract_load.dart` — `.asyncMap()`:
    - Load MergeContract via `mergeContractLoader.load()` (LRU cached)
    - Effectively sync after first hit per governance set (~2-3 distinct sets)
    - No batching needed due to high cache-hit rate
    - Output: `ContractLoadedShardEvent` with MergeContract attached
    - Note: Cannot assume single MergeContract — different Locorda versions/apps may have written shards with different governance
15. Refactor `stage11_shard_crdt_merge.dart` → `stage11c_shard_crdt_merge.dart` — `.expand()`:
    - Call `prepareModifyWithContract()` with loaded contract
    - Pure CPU: CRDT merge + encoding

### Phase 5: SyncDirection Enum Refactor (Independent)

16. Split `localOnly` → `remoteUnchanged` + `notInRemoteShard`
17. Rename `remoteRemoved` → `shardGone`
18. Add `isLocalUploadOnly` getter
19. Update all pipeline stages + `backend_pipeline.dart`

### Phase 6: Index Entry Preparation — Explicit Pipeline Data Flow

> **Updated 2026-03-31**: Replaces flush-time batching approach with explicit data passing through pipeline stages. See FIXME 3 section above for full analysis.

**Sub-phase 6a: Make indexed property extraction reusable**

20. Make `IndexPropertyResolver._extractIndexedProperties()` a **public static method** — it's pure graph traversal (no instance state), extracts `idx:indexedProperty` / `idx:trackedProperty` from index/template graph.

**Sub-phase 6b: Extend 7b to preload indexed properties**

21. In `stage7b_preload.dart`, after loading index/template documents (already loaded for `collectRequiredDocumentIris`), extract indexed properties per index/template IRI using the now-public `extractIndexedProperties`.
22. Add `indexedProperties: Map<IriTerm, Set<IriTerm>>` to `PreloadedCandidate` — maps index/template IRI → set of property IRIs to include in headers.

**Sub-phase 6c: Extend `ShardDeterminationResult` with shard→index mapping**

23. Add `shardToIndex: Map<IriTerm, IriTerm>` to `ShardDeterminationResult`.
24. Populate in `_determineShardsForFullIndex` and `_determineShardsForGroupIndex` — both already compute the index IRI alongside the shard IRI.

**Sub-phase 6d: Build active index entries in 7c**

25. After reconciliation in 7c, build `List<SaveIndexEntryRequest>` for active shards (pure CPU):
    - Shard IRIs from reconciled graph's `idx:belongsToIndexShard` triples
    - `indexIri` from `shardToIndex` mapping
    - `clockHash` from `reconciled.clock.hash` (already computed by merger)
    - Header properties extracted using preloaded `indexedProperties`
26. Extract tombstoned shard IRIs in 7c (pure CPU): reified `idx:belongsToIndexShard` statements with `crdt:deletedAt` in reconciled graph.
27. Add to `MergeResult`:
    - `indexEntries: List<SaveIndexEntryRequest>` — active shard entries
    - `tombstonedShardIris: Set<IriTerm>` — shard IRIs needing deletion entries

**Sub-phase 6e: Simplify Stage 9 to batched DB commit**

28. Stage 9 event handling becomes: `pendingIndexEntries.addAll(mergeResult.indexEntries)` + collect tombstones and resolvedGroupIndices. No per-document `await`.
29. In `_flush()`:
    - Batch-resolve tombstone `indexIri` from `IndexEntries` DB table (single query per flush, using `indexIriId` column)
    - Build tombstone `SaveIndexEntryRequest(isDeleted: true)` entries
    - Batched GroupIndex existence check: collect all `groupIndexIri` from pending `resolvedGroupIndices`, single `storage.getDocumentsByIri()`, create missing ones
    - Atomic transaction: `saveDocuments` + `saveIndexEntries` + `setRemoteETags`
30. Refactor `prepareIndexEntryWrites` to accept `resolvedGroupIndices` (instead of `missingGroupIndices`):
    - This keeps the method usable for the non-pipeline path (`IndexManager.updateIndices`)
    - Pipeline path calls the batched variant in Stage 9 instead
31. Delete `MissingGroupIndex` class — `ResolvedGroupIndex` covers all use cases
32. Remove `missingGroupIndices` from `DocumentSaveResult`, `PreparedDocumentSave`, `ShardDeterminationResult`

### Dependency Graph

```
Phase 1 (Types + 7a)        [independent]
  └── Phase 2 (7b + data)   [depends on Phase 1]
      └── Phase 3 (7c sync) [depends on Phase 2]
          └── Phase 6 (Index entry pipeline flow) [depends on Phase 2+3]
              Sub-phase 6a: Make extractIndexedProperties public [independent]
              Sub-phase 6b: Extend 7b with indexed properties [depends on 6a + Phase 2]
              Sub-phase 6c: Extend ShardDeterminationResult [independent]
              Sub-phase 6d: Build index entries in 7c [depends on 6b + 6c + Phase 3]
              Sub-phase 6e: Simplify Stage 9 [depends on 6d]

Phase 4 (Stage 11)          [independent of Phases 1-3, 6]

Phase 5 (SyncDirection)     [independent]
```

### Pipeline Composition After All Phases

```dart
.transform(_remote.resourceFetch())              // Stage 6
.map(resourceParse(rdfCore))                      // Stage 7a (CPU: decode)
.transform(preloadMergeData(                      // Stage 7b (I/O: batch preload)
    mergeContractLoader, indexDiscovery, storage))
.expand(crdtMerge(merger, reconciler))            // Stage 7c (CPU: merge)
.transform(_remote.resourceUpload())              // Stage 8
.asyncExpand(dbCommit(...))                        // Stage 9
.asyncExpand(shardEntryLoad(_storage))             // Stage 10
.map(shardPrepare(shardDocGen))                    // Stage 11a (CPU: extract + build)
.asyncMap(shardContractLoad(mergeContractLoader))  // Stage 11b (I/O: LRU-cached contracts)
.expand(shardCrdtMerge(documentManager, rdfCore))  // Stage 11c (CPU: merge + encode)
.transform(_remote.shardUpload())                  // Stage 12
.asyncExpand(shardDbCommit(_storage, _remoteId))  // Stage 13
.asyncExpand(feedback(...))                        // Stage 14
```

### Risks and Considerations

- **GroupIndex Creation During Content Phase**: Stage 9 does a batched existence check per flush for all `resolvedGroupIndices` and creates missing GroupIndex documents. This I/O stays in Stage 9 because it's a write operation that depends on the accumulated batch. GroupIndex creation only affects _subsequent_ pipeline iterations (Stage 14 feedback loop), where 7b would re-load fresh data.

- **Tombstone Index IRI Resolution**: Stage 9 resolves `indexIri` for tombstoned shards from the `IndexEntries` DB table (single batched query). This is a DB read, not a document storage read. If a tombstoned shard has no existing `IndexEntries` row (edge case: never-synced shard), the tombstone entry is skipped — the shard was never indexed, so no deletion entry needed.

- **Non-Pipeline Path**: The classical sync path continues using the existing `prepareIndexEntryWrites` method with its own I/O. Phase 6 only changes the pipeline path. The `_extractIndexedProperties` method becoming public benefits both paths.

- **First Sync (Cold Start)**: On very first sync, index-of-indices are synced in the meta phase. Stage 7b's `discoverIndices()` then finds the newly-synced indices. No special cold-start handling needed — the meta → content phase ordering guarantees data availability.

- **`_computeSave` in `CrdtDocumentManager`**: Called from both pipeline (Stage 11) and local saves (app). For local saves, `calculateShards()` remains async (no pre-loaded data available). The new `prepareModifyWithContract()` is pipeline-only; the existing `prepareModify()` stays async for app use. Note: `calculateShards()` no longer checks GroupIndex existence (deferred to `prepareIndexEntryWrites`), which reduces its I/O footprint but does not eliminate it entirely — FullIndex/Template document loads remain.

- **Testing**: Each phase should have dedicated tests. Key scenarios:
  - 7b correctly batches across diverse types and governance sets
  - 7c produces identical results to the current async Stage 7
  - Stage 11b `asyncMap` handles multiple governance versions within one batch
  - Stage 11c is pure CPU with pre-loaded contract
  - Regression: end-to-end sync produces same results before and after refactor
