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

## Remote Index Mirror Types

```dart
/// A single entry in the remote index mirror.
///
/// Represents our last known view of one resource's presence
/// in one shard on a specific remote.
class RemoteMirrorEntry {
  final IriTerm resourceIri;
  final IriTerm shardIri;
  final String clockHash;

  const RemoteMirrorEntry({
    required this.resourceIri,
    required this.shardIri,
    required this.clockHash,
  });
}

/// Request to upsert a mirror entry during commit.
class SaveRemoteMirrorEntryRequest {
  final IriTerm resourceIri;
  final IriTerm shardIri;
  final String clockHash;

  const SaveRemoteMirrorEntryRequest({
    required this.resourceIri,
    required this.shardIri,
    required this.clockHash,
  });
}
```

## Remote Discovery Types

```dart
/// Result of downloading and parsing a single shard document
/// during remote discovery.
sealed class RemoteShardResult {
  IriTerm get shardIri;
}

/// Shard was downloaded (new ETag) and contains entries.
class RemoteShardEntries extends RemoteShardResult {
  @override
  final IriTerm shardIri;
  final List<RemoteMirrorEntry> entries;
  final String etag;

  RemoteShardEntries({
    required this.shardIri,
    required this.entries,
    required this.etag,
  });
}

/// Shard returned 404 — no remote data for this shard.
class RemoteShardEmpty extends RemoteShardResult {
  @override
  final IriTerm shardIri;

  RemoteShardEmpty({required this.shardIri});
}
```

## Pipeline Stage Interfaces

### DiscoveryAndDiffStage

```dart
/// Discovers what needs synchronization by traversing the remote
/// index hierarchy top-down and diffing against local + mirror state.
///
/// Replaces the old SourceStage which took a flat list of shards.
/// Instead, this stage starts from the Index-of-Indices and uses
/// hierarchical stream unfolding to discover shards on-the-fly.
abstract class DiscoveryAndDiffStage {
  /// Discover and diff all resources for a given remote.
  ///
  /// **Remote Discovery** (network, async):
  /// 1. Fetch Index-of-Indices (FullIndex + GroupIndexTemplate)
  ///    with ETag-conditional download
  /// 2. Hierarchical stream unfold: each index triggers its shard
  ///    downloads as soon as it's known (no phase barriers)
  /// 3. Parse entries from changed shards (304 → skip, 404 → empty)
  ///
  /// **Local Discovery** (DB-only, fast):
  /// 1. Query local index entries for discovered shards
  /// 2. Query remote mirror entries for discovered shards
  ///
  /// **Diff / Join**:
  /// Per-shard set comparison producing SyncCandidate records:
  /// - Remote entry with no local match → RemoteOnlyCandidate
  /// - Local entry with no remote match → LocalOnlyCandidate
  /// - Both exist, different clockHash → ConflictCandidate
  /// - Both exist, same clockHash → skip (already in sync)
  ///
  /// **Shard-level knowledge propagation:**
  /// - Shard 404 (empty remote): all local entries → LocalOnlyCandidate
  /// - Shard 304 (unchanged): only check for local-only changes
  ///   (mirror already has correct remote state from previous sync)
  ///
  /// Candidates are deduplicated across shards (same resource may
  /// appear in multiple shards). First occurrence wins.
  Stream<SyncCandidate> discover({
    required RemoteId remoteId,
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
///
/// **Mirror update**: Each commit transaction atomically updates
/// the remote index mirror alongside documents, index entries,
/// and ETags. This guarantees crash safety — the mirror is never
/// ahead of committed local state.
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
  /// Each batch transaction includes:
  /// 1. Save documents + index entries
  /// 2. Update ETags
  /// 3. **Update remote index mirror entries** (upsert/delete)
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

## Remote Index Mirror Interface

```dart
/// Persists minimal known remote state per shard.
///
/// Stores (resourceIri, shardIri, clockHash) per remote — the minimum
/// needed to know what exists remotely and at what CRDT version.
/// Updated atomically in the commit transaction for crash safety.
abstract class RemoteIndexMirror {
  /// Get mirror entries for multiple shards in a single query.
  ///
  /// Returns: Map from shard IRI to list of mirror entries.
  Future<Map<IriTerm, List<RemoteMirrorEntry>>> getRemoteIndexEntries(
    RemoteId remoteId,
    Iterable<IriTerm> shardIris,
  );

  /// Bulk upsert mirror entries. Called within the commit transaction.
  Future<void> saveRemoteIndexEntries(
    RemoteId remoteId,
    List<SaveRemoteMirrorEntryRequest> entries,
  );

  /// Remove mirror entries for resources deleted from the remote.
  Future<void> deleteRemoteIndexEntries(
    RemoteId remoteId,
    List<({IriTerm resourceIri, IriTerm shardIri})> entries,
  );
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
/// Wires together Discovery&Diff → Merge → Commit → Finalize stages
/// with configurable concurrency and batch sizes.
///
/// No explicit "list of shards" input — the pipeline discovers what
/// to sync by traversing the index hierarchy from the top.
class StreamingSyncPipeline {
  final DiscoveryAndDiffStage _discovery;
  final MergeStage _merge;
  final CommitStage _commit;
  final FinalizeStage _finalize;
  final Perflog _perflog;

  const StreamingSyncPipeline({
    required DiscoveryAndDiffStage discovery,
    required MergeStage merge,
    required CommitStage commit,
    required FinalizeStage finalize,
    required Perflog perflog,
  }) : _discovery = discovery,
       _merge = merge,
       _commit = commit,
       _finalize = finalize,
       _perflog = perflog;

  /// Execute full streaming sync.
  ///
  /// The Discovery stage handles index hierarchy traversal internally
  /// (Index-of-Indices → Indices → Shards → Entries), so no prior
  /// meta-type sync phase is required.
  Future<void> sync({
    required RemoteId remoteId,
    required int lastSyncTimestamp,
    required DateTime syncTime,
    required GraphSyncStorage remoteStorage,
  }) async {
    // Stage 1: Discovery & Diff
    final candidates = _perflog.measureStream(
      'streaming.discovery',
      _discovery.discover(
        remoteId: remoteId,
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

    // Stage 3: Commit (includes mirror update)
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
test('DiscoveryAndDiffStage emits RemoteOnlyCandidate for new remote entries', () async {
  // Setup: mock remote with shard containing entries
  // Setup: empty mirror + empty local index
  // Verify: stream emits RemoteOnlyCandidate for each remote entry
});

test('DiscoveryAndDiffStage emits LocalOnlyCandidate for 404 shards', () async {
  // Setup: mock remote returns 404 for shard
  // Setup: local index has entries for that shard
  // Verify: stream emits LocalOnlyCandidate for each local entry
});

test('DiscoveryAndDiffStage skips unchanged shards (304)', () async {
  // Setup: mock remote returns 304 for all shards
  // Setup: mirror matches local index
  // Verify: stream emits zero candidates
});

test('DiscoveryAndDiffStage deduplicates across shards', () async {
  // Setup: same resource in FullIndex shard + GroupIndex shard
  // Verify: only one candidate emitted for that resource
});

test('MergeStage takes fast path for remote-only', () async {
  // Setup: stream of RemoteOnlyCandidate
  // Verify: no full merge invoked, output is accepted remote graph
});

test('CommitStage batches and updates mirror atomically', () async {
  // Setup: stream of 5000 MergedResources
  // Verify: committed in batches, mirror entries match committed state
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

test('Remote index mirror is consistent after sync', () async {
  // Setup: populate remote with test data
  // Run: streaming sync
  // Verify: mirror entries match actual remote shard contents
});

test('Mirror survives crash and enables correct re-sync', () async {
  // Setup: partial sync (interrupt after N commits)
  // Verify: mirror reflects only committed resources
  // Run: resume sync
  // Verify: remaining resources synced correctly without duplicates
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
