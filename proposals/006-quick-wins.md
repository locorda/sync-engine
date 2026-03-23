# 006: Quick Wins — Immediate Performance Improvements

## Overview

These improvements can be made to the **existing** architecture with minimal risk, each providing measurable speedup. They should be implemented before or in parallel with the streaming rewrite.

## Quick Win 1: Enable Concurrent File I/O for DirBackend

**Effort**: Low | **Impact**: High (3-5× for file I/O bound operations)

The `DirSyncStorage` class doesn't override `downloadMany` or `uploadMany`, so it falls back to the sequential default in `RemoteSyncStorage`. File I/O operations are inherently parallelizable.

```dart
// In DirSyncStorage:

@override
Future<List<RemoteDownloadResult<RdfGraph>>> downloadMany(
  Iterable<RemoteDownloadRequest> requests,
) => Future.wait(
  requests.map((req) => download(req.documentIri, ifNoneMatch: req.ifNoneMatch)),
);

@override
Future<List<RemoteUploadResult>> uploadMany(
  Iterable<RemoteUploadRequest<RdfGraph>> requests,
) => Future.wait(
  requests.map((req) => upload(req.documentIri, req.document, ifMatch: req.ifMatch)),
);

// Same for dataset variants
```

**Note**: This is safe for file I/O because each operation writes to a different file. No shared state.

## Quick Win 2: Fix Concurrency Settings

**Effort**: Low-Medium | **Impact**: High (enables concurrent shard processing)

The `maxConcurrent*` settings are all 1 with FIXMEs about test failures. These need investigation and fixing:

```dart
// Current (remote_storage.dart):
int get maxConcurrentDocumentSyncs => 1; //10;
int get maxConcurrentShardSyncs => 1; //5;
int get maxConcurrentIndexSyncs => 1; //3;
```

**Action**: Run tests with concurrency enabled, identify failures, fix root causes. Common causes:
- Shared mutable state in IRI ID caches (need per-operation isolation or atomic access)
- Test ordering dependencies
- Race conditions in index entry writes

## Quick Win 3: Skip CRDT Merge for Trivial Cases (Both Directions)

**Effort**: Low | **Impact**: Medium-High (2-4× merge speedup for initial sync in either direction)

### Accept-Remote (empty local)

In `RemoteDocumentMerger.merge()`, when `localGraph == null`:

```dart
// Current:
if (localGraph == null) {
  return MergeResult(mergedGraph: remoteGraph!);
}
```

This already short-circuits. But the **caller** (`downloadAndMerge`) still does unnecessary work:
- Loads local document from DB (always null for initial sync)
- Loads merge contract
- Calls reconcileDocumentShards (needed, but could be simpler)

### Keep-Local (empty remote)

When `downloadResult.graph == null` (remote returns 404), the code still:
- Loads merge contract (unnecessary — nothing to merge)
- Calls reconcileDocumentShards (recomputes shards we already know)

### Combined optimization

Add fast paths in `syncDocumentsBatch` for both directions:

```dart
// In syncDocumentsBatch merge loop:
if (localDocument == null && downloadResult.graph != null) {
  // Fast path: accept remote, no merge needed
  final remoteGraph = downloadResult.graph!;
  final typeIri = _extractTypeIri(remoteGraph, documentIri);
  final clock = _hlcService.getCurrentClock(remoteGraph, documentIri);
  final shards = await _shardDeterminer.determineShards(...);
  // Skip: merge contract loading, OrganizedGraph, property-level merge
  // Set needsUpload: false (remote already has it)
  prepared.add((...));
  continue;
}
if (localDocument != null && downloadResult.graph == null) {
  // Fast path: keep local, just upload
  final typeIri = _extractTypeIri(localDocument, documentIri);
  final clock = _hlcService.getCurrentClock(localDocument, documentIri);
  // Skip: merge contract loading, OrganizedGraph, property-level merge
  // Set needsUpload: true
  prepared.add((...));
  continue;
}
```

## Quick Win 4: Skip Downloads When Remote Shard is Empty

**Effort**: Low | **Impact**: High (eliminates ~3-5s of wasted 404s for initial push)

When pushing to an empty remote (e.g., after Matrix import), Phase 1 downloads all shard documents and gets 404 for each. But Phase 2 (`syncDocumentsBatch`) then calls `downloadMany` for all 15K individual resources — **all of which also return 404**. This is pure waste.

The fix: propagate shard-level "remote is empty" knowledge from Phase 1 to Phase 2.

```dart
// In _createSyncCandidates or _syncContentResourceTypes:
// If Phase 1 shard download returned 404 (no remote shard doc),
// skip the per-resource download entirely in Phase 2.

// Option A: Pass a flag to syncDocumentsBatch
if (phase1Result.remoteShardDocument == null) {
  // Remote shard is empty — all resources are local-only
  // Skip downloadMany entirely, just upload + commit
  for (final candidate in phase1Result.syncCandidates) {
    // Load local doc, skip merge, go straight to upload
    final localDoc = localDocumentsByIri[candidate.documentIri];
    if (localDoc == null) continue;
    prepared.add((...));
  }
}

// Option B: Use a NullGraphSyncStorage that returns 404 instantly
// (avoids 15K network roundtrips)
class EmptyRemoteGraphSyncStorage implements GraphSyncStorage {
  @override
  Future<RemoteDownloadResult<RdfGraph>> download(
    IriTerm documentIri, {String? ifNoneMatch}
  ) async => RemoteDownloadResult.notFound();
  // ...
}
```

**Also applies to**: Skip uploads when remote already has the data (empty-local pull case). Currently `syncDocumentsBatch` uploads the merged document back to remote even for accept-remote merges. Add a `needsUpload` flag.

## Quick Win 5: Batch ETag Lookups

**Effort**: Low | **Impact**: Low-Medium

Currently in `syncDocumentsBatch`, ETags are fetched in a batch already. But in the shard path, individual ETag lookups still happen. Pre-fetch all ETags for all shard documents at the start of content sync.

This is already partially implemented with `cachedEtagsByIri` in Phase 1, but could be extended to cover all paths.

## Quick Win 6: Reduce Graph Object Allocations

**Effort**: Medium | **Impact**: Medium

In the merge pipeline, many intermediate RdfGraph objects are created:
- `OrganizedGraph.fromGraph()` creates subgraphs
- `MergeResults.join()` creates merged triple sets
- `_buildResultDocument()` creates preliminary graph + final graph with `.withTriples()`
- `reconcileDocumentShards()` calls `_localDocumentMerger.replaceInDocument()` creating another graph

For the accept-remote fast path, ALL of these can be skipped — the remote graph IS the result.

## Quick Win 7: Profile and Measure

**Effort**: Low | **Impact**: Diagnostic

Use the existing `Perflog` system to add timing measurements at critical points:

```
sync.total
├── sync.phase0
├── sync.remote
│   ├── sync.metaPhase
│   └── sync.contentPhase
│       ├── content.collectSpecs
│       ├── content.phase1Download
│       │   ├── phase1.downloadManyShards   ← new
│       │   ├── phase1.parseShardDocs       ← new
│       │   └── phase1.buildCandidates      ← new
│       ├── content.phase2GlobalMerge
│       │   ├── phase2.downloadResources    ← new
│       │   ├── phase2.crdtMerge            ← new
│       │   └── phase2.uploadResources      ← new
│       ├── content.phase2Commit
│       │   ├── phase2.encode               ← new
│       │   └── phase2.dbWrite              ← new
│       └── content.phase3Finalize
│           ├── phase3.buildShardDocs       ← new
│           └── phase3.uploadShards         ← new
```

This data will tell us exactly where the 18 seconds is spent and validate our optimization targets.

## Quick Win 8: Avoid Redundant Shard Determination

**Effort**: Low | **Impact**: Low

`reconcileDocumentShards` calls `_shardDeterminer.determineShards()` for every resource, which involves regex matching and hash computation. For the initial sync case, shard assignments could be pre-computed from the remote shard entries (we already know which shard each resource belongs to from the shard document).

```dart
// Instead of recomputing shards:
if (candidate.existingShardIris != null) {
  // Use shard assignments from remote shard entries
  return (typeIri, document, clock, []);
}
```

## Implementation Order

1. **Quick Win 7** (Profiling) — Do this first to establish baseline for both sync directions
2. **Quick Win 1** (Concurrent file I/O) — Biggest bang for least effort
3. **Quick Win 4** (Skip downloads when remote empty) — Eliminates ~3-5s for initial push
4. **Quick Win 3** (Fast path merge) — Significant for initial sync in both directions
5. **Quick Win 2** (Fix concurrency) — Unblocks all parallelism
6. **Quick Win 5-6** (Batching, allocations) — Incremental improvements
7. **Quick Win 8** (Shard determination) — Nice to have

Expected combined impact: **4-8× improvement** on the 18-second initial sync in either direction (empty local pull or empty remote push), bringing it down to ~3-5 seconds without the full streaming rewrite.
