# 003: Implementation Plan — Streaming Sync

## Overview

This document provides a concrete implementation plan for the streaming sync pipeline described in [002-streaming-sync-architecture.md](002-streaming-sync-architecture.md). The plan is organized in phases, each delivering incremental value and testable independently.

## Phase 0: Preparation (No Behavior Change)

### 0.1: Extract Sync Primitives

Factor out reusable logic from `RemoteSyncOrchestrator` and `_DocumentSyncHelper` into focused, testable units:

- **`ShardEntryComparator`**: Compares local vs remote shard entries, produces sync candidates
- **`FastPathMerger`**: Handles the trivial merge cases (null local, null remote, same clock hash) without constructing OrganizedGraph
- **`ResourceCommitter`**: Encapsulates the save-document + save-index-entries + save-etag pattern

These extractions make the existing code more testable AND provide building blocks for the streaming pipeline.

### 0.2: Fix Concurrency Guards

The `maxConcurrent*` settings are disabled due to test failures. Before enabling concurrent I/O in the streaming pipeline, we need to understand why:

- Audit test failures when concurrency is enabled
- Likely cause: shared mutable state in storage operations or IRI ID caches
- Fix: ensure per-operation isolation or proper synchronization
- This unblocks concurrent I/O for all backends, not just streaming

### 0.3: Add Benchmarks

Create a benchmark harness for measuring sync performance:

```dart
/// benchmark/sync_benchmark.dart
///
/// Setup: populate remote with N resources, empty local
/// Measure: time for full sync cycle
/// Variants: N = 100, 1000, 5000, 15000
/// Backends: InMemory, DirBackend, (later: GDrive)
```

This gives us a baseline and a way to measure each improvement.

## Phase 1: Enable Concurrent I/O (Quick Win)

### 1.1: Implement `downloadMany`/`uploadMany` for DirBackend

Currently falls back to sequential base implementation. Override with parallel I/O:

```dart
@override
Future<List<RemoteDownloadResult<RdfGraph>>> downloadMany(
  Iterable<RemoteDownloadRequest> requests,
) async {
  final futures = requests.map((req) => download(
    req.documentIri,
    ifNoneMatch: req.ifNoneMatch,
  ));
  return Future.wait(futures);
}
```

For file I/O, `Future.wait` already provides concurrency because each `file.readAsString()` is an independent async operation.

### 1.2: Re-enable Concurrency Settings

After fixing concurrency guards (Phase 0.2), set reasonable defaults:

```dart
int get maxConcurrentDocumentSyncs => 10;
int get maxConcurrentShardSyncs => 5;
int get maxConcurrentIndexSyncs => 3;
```

**Expected improvement**: 3-5× speedup on I/O-bound operations with existing architecture.

## Phase 2: Fast Path Merge

### 2.1: Implement `FastPathMerger`

```dart
class FastPathMerger {
  final RemoteDocumentMerger _fullMerger;
  final HlcService _hlcService;
  final ShardDeterminer _shardDeterminer;

  /// Try fast-path merge, falling back to full merge.
  ///
  /// Note: mergeContract parameter is only needed for the slow path.
  /// Fast paths skip merge contract loading entirely.
  Future<MergedResource?> merge({
    required IriTerm documentIri,
    required RdfGraph? localGraph,
    required RdfGraph? remoteGraph,
    required String? localClockHash,
    required String? remoteClockHash,
    required Future<MergeContract> Function() mergeContractLoader,
  }) async {
    // Fast path 1: No local state → accept remote
    // (Initial pull: 100% of resources hit this path)
    if (localGraph == null && remoteGraph != null) {
      return _acceptRemote(documentIri, remoteGraph, needsUpload: false);
    }

    // Fast path 2: No remote state → keep local (upload only)
    // (Initial push: 100% of resources hit this path)
    if (remoteGraph == null && localGraph != null) {
      return _keepLocal(documentIri, localGraph, needsUpload: true);
    }

    // Fast path 3: Same clock hash → skip
    if (localClockHash != null &&
        localClockHash == remoteClockHash) {
      return null; // already in sync
    }

    // Slow path: full CRDT merge (only for actual conflicts)
    final mergeContract = await mergeContractLoader();
    return _fullMerge(documentIri, localGraph!, remoteGraph!, mergeContract);
  }

  MergedResource _acceptRemote(
    IriTerm documentIri,
    RdfGraph remoteGraph, {
    required bool needsUpload,
  }) {
    // Skip OrganizedGraph, ClockComparison, per-property merge, merge contract
    final typeIri = _extractTypeIri(remoteGraph, documentIri);
    final clock = _hlcService.getCurrentClock(remoteGraph, documentIri);
    final shards = _shardDeterminer.determineShards(...);
    return MergedResource(..., needsUpload: needsUpload);
  }

  MergedResource _keepLocal(
    IriTerm documentIri,
    RdfGraph localGraph, {
    required bool needsUpload,
  }) {
    // Skip merge contract loading, OrganizedGraph, per-property merge
    final typeIri = _extractTypeIri(localGraph, documentIri);
    final clock = _hlcService.getCurrentClock(localGraph, documentIri);
    final shards = _shardDeterminer.determineShards(...);
    return MergedResource(..., needsUpload: needsUpload);
  }
}
```

**Expected improvement**: 2-4× speedup on CRDT merge for initial sync in either direction. For initial push (empty remote), also eliminates merge contract loading for all 15K resources.

### 2.2: Skip Redundant Downloads for Empty Remote

Before Phase 2 starts per-resource processing, check if Phase 1 already established that the remote shard is empty. If so, skip `downloadMany` entirely:

```dart
// In _syncContentResourceTypes, after Phase 1:
final emptyRemoteShardIris = phase1Results
    .where((r) => r.remoteShardDocument == null)
    .map((r) => r.shardIri)
    .toSet();

// Phase 2: For candidates from empty-remote shards, skip download
// and use a NullGraphSyncStorage or pass a flag
```

**Expected improvement**: Eliminates ~3-5s of wasted 404 requests for initial push.

### 2.3: Integrate Fast Path into Existing Orchestrator

Before building the full streaming pipeline, integrate `FastPathMerger` into `_DocumentSyncHelper.downloadAndMerge()`. This gives immediate benefit with minimal architectural change.

## Phase 3: Streaming Source Stage

### 3.1: Create `ShardSourceStream`

```dart
/// Produces a stream of sync candidates from shard downloads
class ShardSourceStream {
  Stream<SyncCandidate> source(
    List<ShardSyncSpec> shards,
    int lastSyncTimestamp, {
    required StreamingRemoteSyncStorage remote,
    required Storage local,
  }) async* {
    // Pre-fetch all local index entries
    final localEntries = await local.getActiveIndexEntriesForShards(
      shards.map((s) => s.shardIri),
    );

    // Download shard documents concurrently
    for (final shard in shards) {
      final shardDoc = await remote.download(shard.shardIri.getDocumentIri());
      if (shardDoc.graph == null) continue;

      // Extract entries and compare with local
      final remoteEntries = _extractEntries(shardDoc.graph!);
      final localShardEntries = localEntries[shard.shardIri] ?? [];

      for (final entry in _diffEntries(remoteEntries, localShardEntries)) {
        yield entry;
      }
    }
  }
}
```

### 3.2: Create `StreamingRemoteSyncStorage` Interface

Define the new interface (see [002](002-streaming-sync-architecture.md) for details) and implement for `DirSyncStorage`:

```dart
class StreamingDirSyncStorage extends DirSyncStorage
    implements StreamingRemoteSyncStorage {
  @override
  Stream<(RemoteDownloadRequest, RemoteDownloadResult<RdfGraph>)>
    downloadStream(Iterable<RemoteDownloadRequest> requests) async* {
    // Simple implementation: bounded concurrent downloads
    // using async generator with sliding window
  }
}
```

## Phase 4: Streaming Commit Stage

### 4.1: Create `BatchCommitter`

```dart
/// Collects merged resources and commits in batches
class BatchCommitter {
  static const batchSize = 1000;

  final Storage _storage;
  final RemoteId _remoteId;

  /// Consume merged resources, commit in batches
  Future<List<CommittedResource>> commit(
    Stream<MergedResource> merged,
    DateTime syncTime, {
    required StreamingRemoteSyncStorage remote,
  }) async {
    final committed = <CommittedResource>[];
    var batch = <MergedResource>[];

    await for (final resource in merged) {
      batch.add(resource);
      if (batch.length >= batchSize) {
        committed.addAll(await _commitBatch(batch, syncTime, remote));
        batch = [];
      }
    }

    if (batch.isNotEmpty) {
      committed.addAll(await _commitBatch(batch, syncTime, remote));
    }

    return committed;
  }

  Future<List<CommittedResource>> _commitBatch(
    List<MergedResource> batch,
    DateTime syncTime,
    StreamingRemoteSyncStorage remote,
  ) async {
    // 1. Pre-encode all documents (Jelly binary)
    final requests = batch.map((r) => SaveDocumentRequest(...)).toList();
    final preEncoded = _storage.preEncodeDocuments(requests);

    // 2. Upload to remote (concurrent)
    final uploadResults = await remote.uploadMany(
      batch.map((r) => RemoteUploadRequest(...)),
    );

    // 3. Commit to DB in transaction
    await _storage.saveBatch(SaveBatch(
      documents: requests,
      indexEntries: _buildIndexEntries(batch),
      etagUpdates: _buildEtags(batch, uploadResults),
      preEncodedContents: preEncoded,
    ));

    return batch.map((r) => CommittedResource(...)).toList();
  }
}
```

### 4.2: Pipeline Encode/Commit

Same as current chunked commit, but with streaming input:

```dart
// Encode chunk N+1 while committing chunk N
var nextPreEncoded = _storage.preEncodeDocuments(chunks.first);
for (var i = 0; i < chunks.length; i++) {
  final commitFuture = _commitChunk(chunks[i], preEncoded: nextPreEncoded);
  nextPreEncoded = (i + 1 < chunks.length)
    ? _storage.preEncodeDocuments(chunks[i + 1])
    : null;
  await commitFuture;
}
```

## Phase 5: Full Streaming Pipeline

### 5.1: Create `StreamingSyncFunction`

Wire all stages together:

```dart
class StreamingSyncFunction {
  Future<void> call(DateTime syncTime) async {
    // Phase 0: Same as current (shard generation)
    await _prepareSync(syncTime);

    // Streaming sync
    for (final backend in _backends) {
      for (final remote in backend.remotes) {
        await _streamingSync(remote, syncTime);
      }
    }
  }

  Future<void> _streamingSync(RemoteStorage remote, DateTime syncTime) async {
    final config = await _configService.currentConfig;
    final syncStorage = await remote.createSyncStorage(config);
    final lastSync = await _storage.getLastRemoteSyncTimestamp(remote.remoteId);

    try {
      // 1. Sync meta-types (index-of-indices) — same as current
      await _syncMetaTypes(syncStorage, config, lastSync, syncTime);

      // 2. Collect all shard specs
      final shardSpecs = await _collectAllShardSpecs(config);

      // 3. Streaming pipeline for content resources
      final candidates = _sourceStream.source(shardSpecs, lastSync,
        remote: syncStorage, local: _storage);
      final merged = _mergeStream(candidates, lastSync);
      final committed = await _batchCommitter.commit(merged, syncTime,
        remote: syncStorage);

      // 4. Finalize shards
      await _finalizeShards(committed, syncTime, syncStorage);

      await _storage.updateLastRemoteSyncTimestamp(
        remote.remoteId, syncTime.millisecondsSinceEpoch);
    } finally {
      await syncStorage.finalizeSync();
    }
  }
}
```

### 5.2: Integration Testing

- Run both old `SyncFunction` and new `StreamingSyncFunction` on same test suite
- Compare resulting DB state for equivalence
- Benchmark both on 100, 1000, 5000, 15000 resource counts
- Profile with Dart DevTools to verify I/O overlap

## Phase 6: Advanced Optimizations

### 6.1: Byte-Level Pass-Through

For initial sync (accept-remote fast path), the remote graph doesn't need to be re-encoded for DB storage. If the remote provides Jelly-encoded bytes, pass them directly to `saveDocument`:

```dart
// Instead of: decode → RdfGraph → encode → save
// Do: raw bytes → save (with metadata extracted separately)
```

This requires a new storage method that accepts pre-encoded content.

### 6.2: Streaming Dataset Extraction

For dataset mode (useShardDatasets), stream individual named graphs out of the TriG/Jelly dataset as they're parsed, rather than parsing the full dataset into memory first.

### 6.3: Incremental Shard Finalization

Instead of waiting for ALL resources to commit before finalizing shards:
- Track per-shard resource completion
- Finalize each shard as soon as all its resources are committed
- Overlap shard finalization with resource processing for other shards

### 6.4: Smart Batch Sizing

Dynamically adjust batch size based on throughput:
- If DB writes are fast, use larger batches (fewer transactions)
- If DB writes are slow, use smaller batches (more responsive)
- Measure and adapt during sync

## Dependency Graph

```
Phase 0 ──────────────────────────────────────────────┐
  0.1: Extract primitives                              │
  0.2: Fix concurrency guards      ─────────────┐     │
  0.3: Add benchmarks                            │     │
                                                 │     │
Phase 1 ◀────────────────────────────────────────┘     │
  1.1: DirBackend downloadMany/uploadMany              │
  1.2: Re-enable concurrency                           │
                                                       │
Phase 2 ◀──────────────────────────────────────────────┘
  2.1: FastPathMerger (both directions)
  2.2: Skip redundant downloads for empty remote
  2.3: Integrate into existing orchestrator

Phase 3 (can start after Phase 0)
  3.1: ShardSourceStream
  3.2: StreamingRemoteSyncStorage interface

Phase 4 (can start after Phase 0)
  4.1: BatchCommitter
  4.2: Pipeline encode/commit

Phase 5 (requires Phases 2, 3, 4)
  5.1: StreamingSyncFunction
  5.2: Integration testing

Phase 6 (after Phase 5 is stable)
  6.1-6.4: Advanced optimizations
```

## Effort Estimates

| Phase | Complexity | Value | Risk |
|-------|-----------|-------|------|
| Phase 0 | Low | Foundation | Low |
| Phase 1 | Low | **High** (3-5× I/O speedup) | Low |
| Phase 2 | Medium | **High** (2-4× merge speedup) | Low |
| Phase 3 | Medium | Medium (enables streaming) | Medium |
| Phase 4 | Medium | Medium (enables batching) | Low |
| Phase 5 | High | **Very High** (full pipeline) | Medium |
| Phase 6 | High | Medium (diminishing returns) | High |

**Recommendation**: Phases 1 and 2 alone should achieve a 4-8× improvement with minimal risk. Phase 5 (full streaming) is needed for the theoretical maximum but involves more architectural change.

## Files to Create/Modify

### New Files
- `lib/src/sync/streaming_sync_function.dart` — Main streaming orchestrator
- `lib/src/sync/fast_path_merger.dart` — Fast-path CRDT merge
- `lib/src/sync/shard_source_stream.dart` — Streaming shard entry extraction
- `lib/src/sync/batch_committer.dart` — Batched commit with pipelining
- `lib/src/sync/sync_candidate.dart` — Data types for pipeline
- `lib/src/storage/streaming_remote_storage.dart` — Extended remote interface

### Modified Files
- `lib/src/storage/remote_storage.dart` — Add `StreamingRemoteSyncStorage`
- `packages/locorda_dir/lib/src/backend/dir_backend.dart` — Override downloadMany/uploadMany
- `lib/src/sync/remote_document_merger.dart` — Extract fast-path logic
- `lib/src/standard_sync_engine.dart` — Wire up StreamingSyncFunction option
- `lib/src/sync_engine.dart` — Configuration for streaming vs. legacy sync
