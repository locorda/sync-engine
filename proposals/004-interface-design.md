# 004: Interface Design — Streaming Sync Interfaces

## Overview

This document specifies the exact interfaces needed for the streaming sync pipeline. These interfaces are designed to:
1. Be implementable incrementally alongside the existing interfaces
2. Support both file-per-resource and dataset modes
3. Enable natural backpressure through Dart Streams
4. Be testable with in-memory implementations

## Data Types

### SyncCandidate

Represents a resource that potentially needs synchronization.

```dart
/// A resource identified during shard comparison that may need sync.
///
/// Produced by the Source stage after comparing local and remote shard entries.
sealed class SyncCandidate {
  /// Document IRI (the container document, not the resource itself)
  IriTerm get documentIri;

  /// Resource IRI (the actual thing/subject)
  IriTerm get resourceIri;
}

/// Resource exists remotely but not locally → download and accept
class RemoteOnlyCandidate extends SyncCandidate {
  @override
  final IriTerm documentIri;
  @override
  final IriTerm resourceIri;
  final String remoteClockHash;

  /// Remote graph if already available (dataset mode), null otherwise
  final RdfGraph? remoteGraph;
  final String? remoteEtag;

  const RemoteOnlyCandidate({
    required this.documentIri,
    required this.resourceIri,
    required this.remoteClockHash,
    this.remoteGraph,
    this.remoteEtag,
  });
}

/// Resource exists locally but not remotely → upload
///
/// Emitted when Phase 1 shard comparison finds resources in local index
/// that have no corresponding remote entry. For the empty-remote case
/// (e.g., initial push after Matrix import), ALL resources become
/// LocalOnlyCandidates — the Merge stage skips downloads entirely.
class LocalOnlyCandidate extends SyncCandidate {
  @override
  final IriTerm documentIri;
  @override
  final IriTerm resourceIri;
  final String localClockHash;

  /// Shard IRIs already known from local index entries.
  /// Avoids redundant shard determination in the Merge stage.
  final List<IriTerm>? knownShardIris;

  const LocalOnlyCandidate({
    required this.documentIri,
    required this.resourceIri,
    required this.localClockHash,
    this.knownShardIris,
  });
}

/// Resource exists on both sides with different clock hashes → merge
class ConflictCandidate extends SyncCandidate {
  @override
  final IriTerm documentIri;
  @override
  final IriTerm resourceIri;
  final String localClockHash;
  final String remoteClockHash;

  /// Remote graph if already available (dataset mode), null otherwise
  final RdfGraph? remoteGraph;
  final String? remoteEtag;

  const ConflictCandidate({
    required this.documentIri,
    required this.resourceIri,
    required this.localClockHash,
    required this.remoteClockHash,
    this.remoteGraph,
    this.remoteEtag,
  });
}
```

### MergedResource

Represents a resource that has been merged and is ready for commit.

```dart
/// A resource that has been through the merge stage.
class MergedResource {
  final IriTerm documentIri;
  final IriTerm typeIri;
  final RdfGraph mergedGraph;
  final CurrentCrdtClock clock;
  final List<IriTerm> shardIris;
  final List<MissingGroupIndex> missingGroupIndices;

  /// ETag from remote download (for conditional upload)
  final String? remoteEtag;

  /// Local updatedAt (for optimistic locking on DB write)
  final int? localUpdatedAt;

  /// Whether this resource needs upload to remote
  /// (false for remote-only initial sync where remote already has latest)
  final bool needsUpload;

  const MergedResource({
    required this.documentIri,
    required this.typeIri,
    required this.mergedGraph,
    required this.clock,
    required this.shardIris,
    required this.missingGroupIndices,
    this.remoteEtag,
    this.localUpdatedAt,
    required this.needsUpload,
  });
}
```

### CommittedResource

Tracks what was committed for shard finalization.

```dart
/// A resource that has been committed to DB and (if needed) uploaded.
class CommittedResource {
  final IriTerm documentIri;
  final IriTerm typeIri;
  final List<IriTerm> shardIris;

  const CommittedResource({
    required this.documentIri,
    required this.typeIri,
    required this.shardIris,
  });
}
```

## Pipeline Stage Interfaces

### SourceStage

```dart
/// Produces sync candidates from shard comparison.
///
/// Downloads shard documents, compares entries with local state,
/// and emits candidates for resources that need synchronization.
abstract class SourceStage {
  /// Generate sync candidates from shards.
  ///
  /// For each shard:
  /// 1. Download shard document (or use dataset)
  /// 2. Extract entries
  /// 3. Compare with local entries
  /// 4. Emit candidates for differences
  ///
  /// **Shard-level knowledge propagation:**
  /// - If shard doc is 404 (empty remote): emit LocalOnlyCandidate for
  ///   ALL local resources in that shard — no per-resource download needed
  /// - If shard has remote entries but no local: emit RemoteOnlyCandidate
  ///   for all remote resources — no per-resource local DB lookup needed
  /// - LocalOnlyCandidates carry knownShardIris from the index entries
  ///
  /// Candidates are deduplicated across shards (same resource may appear
  /// in multiple shards). First occurrence wins.
  Stream<SyncCandidate> source({
    required List<ShardSyncSpec> shards,
    required int lastSyncTimestamp,
    required GraphSyncStorage remoteStorage,
  });
}
```

### MergeStage

```dart
/// Processes sync candidates through CRDT merge.
///
/// Uses fast paths for trivial cases and falls back to full merge
/// only when both local and remote have diverged.
abstract class MergeStage {
  /// Merge a stream of candidates, yielding merged resources.
  ///
  /// For RemoteOnlyCandidate: accept remote (fast path)
  ///   - No merge contract loading, no shard reconciliation
  ///   - Sets needsUpload: false (remote already has it)
  ///   - May fetch remote graph if not pre-attached (file-per-resource mode)
  ///
  /// For LocalOnlyCandidate: keep local (fast path)
  ///   - NO download from remote (Source stage already confirmed remote is empty)
  ///   - No merge contract loading needed
  ///   - Uses knownShardIris from index entries when available
  ///   - Sets needsUpload: true
  ///   - Reads local document from DB (batch-optimized)
  ///
  /// For ConflictCandidate: full CRDT merge (slow path)
  Stream<MergedResource> merge(
    Stream<SyncCandidate> candidates, {
    required GraphSyncStorage remoteStorage,
    required int lastSyncTimestamp,
  });
}
```

### CommitStage

```dart
/// Batches merged resources and commits to DB + remote.
///
/// Uses configurable batch sizes and pipelined encode/commit
/// for throughput optimization.
abstract class CommitStage {
  /// Consume merged resources and commit in batches.
  ///
  /// Direction-aware processing per resource:
  /// - needsUpload: false → DB write only (remote already has data)
  /// - needsUpload: true → upload to remote + DB write + ETag update
  ///
  /// For initial pull (all needsUpload: false): pure DB write, no network.
  /// For initial push (all needsUpload: true): upload + DB write, pipelined.
  ///
  /// Returns all committed resources for shard finalization.
  Future<List<CommittedResource>> commit(
    Stream<MergedResource> merged, {
    required DateTime syncTime,
    required GraphSyncStorage remoteStorage,
    required RemoteId remoteId,
    int batchSize = 1000,
  });
}
```

### FinalizeStage

```dart
/// Finalizes shard documents after all resources are committed.
abstract class FinalizeStage {
  /// Generate and upload shard documents.
  ///
  /// Groups committed resources by shard, generates shard RDF
  /// from canonical DB state, uploads, and commits metadata.
  Future<void> finalize(
    List<CommittedResource> committed, {
    required DateTime syncTime,
    required GraphSyncStorage remoteStorage,
    required RemoteId remoteId,
  });
}
```

## Extended Remote Storage Interface

```dart
/// Extension to RemoteSyncStorage for streaming-optimized operations.
///
/// Backends can implement this for better streaming performance.
/// If not implemented, the pipeline falls back to downloadMany/uploadMany.
abstract class StreamingRemoteSyncStorage extends RemoteSyncStorage {
  /// Maximum number of concurrent download operations.
  int get maxConcurrentDownloads => 10;

  /// Maximum number of concurrent upload operations.
  int get maxConcurrentUploads => 10;

  /// Download multiple resources concurrently, yielding results as they arrive.
  ///
  /// Default implementation delegates to downloadMany with chunked concurrency.
  /// Backends may override for true streaming (e.g., HTTP/2 multiplexing).
  Stream<(int index, RemoteDownloadResult<RdfGraph>)> downloadStream(
    List<RemoteDownloadRequest> requests,
  ) async* {
    // Default: chunk into concurrent windows
    for (var i = 0; i < requests.length; i += maxConcurrentDownloads) {
      final chunk = requests.sublist(
        i, min(i + maxConcurrentDownloads, requests.length));
      final results = await downloadMany(chunk);
      for (var j = 0; j < results.length; j++) {
        yield (i + j, results[j]);
      }
    }
  }
}
```

## Streaming Pipeline Orchestrator

```dart
/// Main streaming sync pipeline.
///
/// Wires together Source → Merge → Commit → Finalize stages
/// with configurable concurrency and batch sizes.
class StreamingSyncPipeline {
  final SourceStage _source;
  final MergeStage _merge;
  final CommitStage _commit;
  final FinalizeStage _finalize;
  final Perflog _perflog;

  const StreamingSyncPipeline({
    required SourceStage source,
    required MergeStage merge,
    required CommitStage commit,
    required FinalizeStage finalize,
    required Perflog perflog,
  }) : _source = source,
       _merge = merge,
       _commit = commit,
       _finalize = finalize,
       _perflog = perflog;

  /// Execute full streaming sync for content resource types.
  ///
  /// Meta-types (index-of-indices) are still synced sequentially
  /// before this method is called.
  Future<void> syncContent({
    required List<ShardSyncSpec> shards,
    required int lastSyncTimestamp,
    required DateTime syncTime,
    required GraphSyncStorage remoteStorage,
    required RemoteId remoteId,
  }) async {
    // Stage 1: Source
    final candidates = _perflog.measureStream(
      'streaming.source',
      _source.source(
        shards: shards,
        lastSyncTimestamp: lastSyncTimestamp,
        remoteStorage: remoteStorage,
      ),
    );

    // Stage 2: Merge
    final merged = _perflog.measureStream(
      'streaming.merge',
      _merge.merge(
        candidates,
        remoteStorage: remoteStorage,
        lastSyncTimestamp: lastSyncTimestamp,
      ),
    );

    // Stage 3: Commit
    final committed = await _perflog.measure(
      'streaming.commit',
      () => _commit.commit(
        merged,
        syncTime: syncTime,
        remoteStorage: remoteStorage,
        remoteId: remoteId,
      ),
    );

    // Stage 4: Finalize
    await _perflog.measure(
      'streaming.finalize',
      () => _finalize.finalize(
        committed,
        syncTime: syncTime,
        remoteStorage: remoteStorage,
        remoteId: remoteId,
      ),
    );
  }
}
```

## Configuration

```dart
/// Configuration for the streaming sync pipeline.
class StreamingSyncConfig {
  /// Number of resources to batch in a single DB transaction
  final int commitBatchSize;

  /// Maximum concurrent downloads
  final int maxConcurrentDownloads;

  /// Maximum concurrent uploads
  final int maxConcurrentUploads;

  /// Whether to use the streaming pipeline (vs. legacy)
  final bool useStreamingSync;

  const StreamingSyncConfig({
    this.commitBatchSize = 1000,
    this.maxConcurrentDownloads = 10,
    this.maxConcurrentUploads = 10,
    this.useStreamingSync = false,
  });
}
```

## Testing Strategy

### Unit Tests per Stage

Each stage is independently testable with mock inputs:

```dart
test('SourceStage emits candidates for changed resources', () async {
  // Setup: mock remote with shard containing entries
  // Setup: local with subset of entries
  // Verify: stream emits correct candidate types
});

test('MergeStage takes fast path for remote-only', () async {
  // Setup: stream of RemoteOnlyCandidate
  // Verify: no full merge invoked, output is accepted remote graph
});

test('CommitStage batches and pipelines', () async {
  // Setup: stream of 5000 MergedResources
  // Verify: committed in batches, total count matches
});
```

### Integration Tests

```dart
test('StreamingSyncPipeline produces same result as legacy', () async {
  // Setup: populate remote with test data
  // Run: legacy sync to empty DB A
  // Run: streaming sync to empty DB B
  // Verify: DB A == DB B (document contents, index entries, ETags)
});
```

### Benchmark Tests

```dart
test('StreamingSyncPipeline is faster than legacy', () async {
  // Setup: 15,000 resources in remote
  // Measure: legacy sync time
  // Measure: streaming sync time
  // Assert: streaming < legacy / 3
});
```
