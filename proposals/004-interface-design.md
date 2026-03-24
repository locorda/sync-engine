# 004: Interface Design — Streaming Sync Interfaces

## Overview

This document specifies the exact Dart interfaces for the stream-composition pipeline described in [002-streaming-sync-architecture.md](002-streaming-sync-architecture.md). Design goals:

1. **No orchestrator class** — the pipeline is composed stream transforms
2. **Boundary elements** flow inline through the stream for coordination
3. **RdfGraphSource** enables data to flow in its natural format — decoded only where needed, with original bytes preserved for pass-through
4. **Backend as stream transform** — each backend is `Stream<FetchRequest> → Stream<FetchResult>`
5. **Testable** — each transform is independently testable with mock streams

## Boundary Types

Shared boundary markers that flow through the pipeline. Each stage wraps them in its own event type for type safety, but the underlying `Boundary` object is the same instance.

```dart
/// Inline coordination markers emitted by Remote Discovery.
/// Flow through all downstream transforms unchanged.
sealed class Boundary {
  const Boundary();
}

/// All entries for a single shard have been emitted.
///
/// Downstream effects:
/// - Diff Transform: emits rest-query for local-only items in this shard
///   (filtered by updatedAt > lastSyncTimestamp)
/// - Commit Transform: may flush batch
/// - Shard Finalize: triggers shard document generation + upload
class ShardComplete extends Boundary {
  final IriTerm shardIri;

  /// ETag from the remote shard download (null if 404/empty).
  final String? remoteEtag;

  const ShardComplete({required this.shardIri, this.remoteEtag});
}

/// All shards for an entire index level have been emitted.
///
/// Levels correspond to the index hierarchy:
/// 1. IoI-Index level (Index-of-Indices shards)
/// 2. Index level (per-index shards)
///
/// Downstream effects:
/// - Diff Transform: emits rest-query for local-only items changed
///   since last sync (updatedAt > lastSyncTimestamp) that were not
///   seen in any shard at this level
/// - Commit Transform: flushes any remaining batch
class LevelComplete extends Boundary {
  /// Which level just completed (for logging/debugging).
  final int level;

  const LevelComplete({required this.level});
}
```

## Per-Stage Event Types

Each pipeline stage has its own event sealed class wrapping either data or a boundary. This provides type safety — you can't accidentally pass a `DiscoveryEvent` where a `FetchEvent` is expected.

```dart
// ── Remote Discovery ──

sealed class DiscoveryEvent {
  const DiscoveryEvent();
}

class DiscoveryData extends DiscoveryEvent {
  final RemoteShardEntry entry;
  const DiscoveryData(this.entry);
}

class DiscoveryBoundary extends DiscoveryEvent {
  final Boundary boundary;
  const DiscoveryBoundary(this.boundary);
}

// ── Diff Transform ──

sealed class DiffEvent {
  const DiffEvent();
}

class DiffData extends DiffEvent {
  final SyncCandidate candidate;
  const DiffData(this.candidate);
}

class DiffBoundary extends DiffEvent {
  final Boundary boundary;
  const DiffBoundary(this.boundary);
}

// ── Resource Fetch ──

sealed class FetchEvent {
  const FetchEvent();
}

class FetchData extends FetchEvent {
  final FetchedCandidate candidate;
  const FetchData(this.candidate);
}

class FetchBoundary extends FetchEvent {
  final Boundary boundary;
  const FetchBoundary(this.boundary);
}

// ── CRDT Merge ──

sealed class MergeEvent {
  const MergeEvent();
}

class MergeData extends MergeEvent {
  final MergedResource resource;
  const MergeData(this.resource);
}

class MergeBoundary extends MergeEvent {
  final Boundary boundary;
  const MergeBoundary(this.boundary);
}

// ── Upload ──

sealed class UploadEvent {
  const UploadEvent();
}

class UploadData extends UploadEvent {
  final UploadedResource resource;
  const UploadData(this.resource);
}

class UploadBoundary extends UploadEvent {
  final Boundary boundary;
  const UploadBoundary(this.boundary);
}

// ── DB Commit ──

sealed class CommitEvent {
  const CommitEvent();
}

class CommitData extends CommitEvent {
  final CommittedResource resource;
  const CommitData(this.resource);
}

class CommitBoundary extends CommitEvent {
  final Boundary boundary;
  const CommitBoundary(this.boundary);
}
```

## RdfGraphSource

Data flows through the pipeline in its natural format. CPU work (decoding, encoding) stays in CPU stages; I/O stages only read and write raw bytes. The Merge stage (CPU-bound) is responsible for ensuring data is available in the DB's storage format — Commit (I/O-bound) never decodes or encodes. Backends that need CPU-intensive format transformation (e.g., aggregate-file parsing/rebuilding) compose their own internal sub-stages.

```dart
/// A reference to RDF graph content in any representation.
///
/// Hierarchy:
///   RdfGraphSource
///   ├── EncodedRdfGraphSource (not yet decoded)
///   │   ├── TextGraphSource
///   │   └── BinaryGraphSource
///   └── DecodedGraphSource (decoded, optionally preserves original)
sealed class RdfGraphSource {
  const RdfGraphSource();

  /// Decode to an RdfGraph. Uses registered rdf_core codecs.
  /// For DecodedGraphSource, returns immediately.
  Future<RdfGraph> decode();
}

/// Not-yet-decoded content with a known content type.
/// I/O stages produce and forward these without parsing.
sealed class EncodedRdfGraphSource extends RdfGraphSource {
  ContentType get contentType;
}

/// Serialized text content (e.g., Turtle, JSON-LD).
class TextGraphSource extends EncodedRdfGraphSource {
  final String content;
  @override
  final ContentType contentType;
  const TextGraphSource(this.content, this.contentType);

  @override
  Future<RdfGraph> decode() async =>
      RdfCore.instance.decode(content, contentType: contentType);
}

/// Binary content (e.g., Jelly).
class BinaryGraphSource extends EncodedRdfGraphSource {
  final Uint8List bytes;
  @override
  final ContentType contentType;
  const BinaryGraphSource(this.bytes, this.contentType);

  @override
  Future<RdfGraph> decode() async =>
      RdfCore.instance.decode(bytes, contentType: contentType);
}

/// Already-decoded graph. Preserves the original encoded source
/// so downstream I/O stages can use raw bytes directly without
/// re-encoding.
///
/// The Merge stage guarantees that [originalSource] is in the
/// DB's storage format (typically Jelly):
/// - If the decoded source was already in DB format: originalSource
///   points to the original bytes (zero-cost reuse).
/// - If the decoded source was in a different format (e.g., Turtle):
///   Merge encodes to DB format and sets that as originalSource.
/// - For conflict merges: Merge encodes the merged graph to DB format.
///
/// Commit reads [originalSource] bytes directly — no CPU work.
class DecodedGraphSource extends RdfGraphSource {
  final RdfGraph graph;

  /// The encoded form in the DB's storage format.
  /// Enables Commit stage to write bytes directly without encoding.
  final EncodedRdfGraphSource? originalSource;

  const DecodedGraphSource(this.graph, {this.originalSource});

  @override
  Future<RdfGraph> decode() async => graph;
}
```

## Data Types

### RemoteShardEntry

A single entry from a remote shard, as discovered during Remote Discovery.

```dart
/// One resource's metadata from a remote shard document.
class RemoteShardEntry {
  final IriTerm resourceIri;
  final IriTerm documentIri;
  final IriTerm shardIri;
  final String clockHash;

  const RemoteShardEntry({
    required this.resourceIri,
    required this.documentIri,
    required this.shardIri,
    required this.clockHash,
  });
}
```

### SyncCandidate

Output of the Diff Transform — a resource that needs synchronization.

```dart
/// A resource identified as needing sync by the Diff Transform.
sealed class SyncCandidate {
  IriTerm get documentIri;
  IriTerm get resourceIri;
}

/// Resource exists remotely but not locally → fetch and accept.
class RemoteOnlyCandidate extends SyncCandidate {
  @override
  final IriTerm documentIri;
  @override
  final IriTerm resourceIri;
  final String remoteClockHash;
  final IriTerm shardIri;

  const RemoteOnlyCandidate({
    required this.documentIri,
    required this.resourceIri,
    required this.remoteClockHash,
    required this.shardIri,
  });
}

/// Resource exists locally but not remotely → upload.
///
/// Emitted either during per-shard diff (resource in local index but
/// not in remote shard) or at boundary rest-query (locally changed
/// since last sync, not seen in any remote shard).
class LocalOnlyCandidate extends SyncCandidate {
  @override
  final IriTerm documentIri;
  @override
  final IriTerm resourceIri;
  final String localClockHash;

  /// Known shard IRIs from local index entries.
  /// Avoids redundant shard determination in the Merge stage.
  final List<IriTerm>? knownShardIris;

  const LocalOnlyCandidate({
    required this.documentIri,
    required this.resourceIri,
    required this.localClockHash,
    this.knownShardIris,
  });
}

/// Resource exists on both sides with different clock hashes → full merge.
class ConflictCandidate extends SyncCandidate {
  @override
  final IriTerm documentIri;
  @override
  final IriTerm resourceIri;
  final String localClockHash;
  final String remoteClockHash;
  final IriTerm shardIri;

  const ConflictCandidate({
    required this.documentIri,
    required this.resourceIri,
    required this.localClockHash,
    required this.remoteClockHash,
    required this.shardIri,
  });
}
```

### FetchRequest / FetchResult

Backend transform input/output for resource content retrieval.

```dart
/// Request to fetch a resource's content from the backend.
class FetchRequest {
  final IriTerm documentIri;

  /// ETag for conditional download (null for unconditional).
  final String? ifNoneMatch;

  const FetchRequest({required this.documentIri, this.ifNoneMatch});
}

/// Result of a backend fetch.
sealed class FetchResult {
  IriTerm get documentIri;
}

/// Content retrieved successfully.
class FetchSuccess extends FetchResult {
  @override
  final IriTerm documentIri;
  final EncodedRdfGraphSource content;
  final String? etag;

  const FetchSuccess({
    required this.documentIri,
    required this.content,
    this.etag,
  });
}

/// Resource not found (404).
class FetchNotFound extends FetchResult {
  @override
  final IriTerm documentIri;

  const FetchNotFound({required this.documentIri});
}

/// Resource unchanged (304 — ETag match).
class FetchUnchanged extends FetchResult {
  @override
  final IriTerm documentIri;

  const FetchUnchanged({required this.documentIri});
}
```

### FetchedCandidate

A SyncCandidate enriched with fetched content, ready for merge.

```dart
/// A sync candidate with its graph content resolved.
///
/// Produced by the Resource Fetch stage, consumed by the Merge stage.
sealed class FetchedCandidate {
  IriTerm get documentIri;
  IriTerm get resourceIri;
}

/// Remote content fetched — accept directly (fast path).
/// Merge decodes to extract metadata, preserves originalSource.
class FetchedRemoteOnly extends FetchedCandidate {
  @override
  final IriTerm documentIri;
  @override
  final IriTerm resourceIri;
  final EncodedRdfGraphSource remoteContent;
  final String? remoteEtag;

  const FetchedRemoteOnly({
    required this.documentIri,
    required this.resourceIri,
    required this.remoteContent,
    this.remoteEtag,
  });
}

/// Local content loaded as raw bytes from DB — upload (fast path).
/// Merge passes through without decoding if metadata available from index.
class FetchedLocalOnly extends FetchedCandidate {
  @override
  final IriTerm documentIri;
  @override
  final IriTerm resourceIri;
  final EncodedRdfGraphSource localContent;
  final List<IriTerm>? knownShardIris;

  const FetchedLocalOnly({
    required this.documentIri,
    required this.resourceIri,
    required this.localContent,
    this.knownShardIris,
  });
}

/// Both sides fetched — needs full CRDT merge (slow path).
/// Both are decoded in Merge; Merge encodes result to DB format
/// → DecodedGraphSource(mergedGraph, originalSource: dbFormatBytes).
class FetchedConflict extends FetchedCandidate {
  @override
  final IriTerm documentIri;
  @override
  final IriTerm resourceIri;
  final EncodedRdfGraphSource localContent;
  final EncodedRdfGraphSource remoteContent;
  final String? remoteEtag;

  const FetchedConflict({
    required this.documentIri,
    required this.resourceIri,
    required this.localContent,
    required this.remoteContent,
    this.remoteEtag,
  });
}
```

### MergedResource

```dart
/// A resource that has been through CRDT merge, ready for upload + commit.
class MergedResource {
  final IriTerm documentIri;
  final IriTerm typeIri;

  /// The graph content — may be:
  /// - DecodedGraphSource(graph, originalSource: dbFormatBytes) for remote-only
  ///   (Merge decoded + ensured DB format in originalSource)
  /// - EncodedRdfGraphSource (pass-through) for local-only upload
  ///   (already in DB format from the DB itself)
  /// - DecodedGraphSource(mergedGraph, originalSource: dbFormatBytes) for conflict
  ///   (Merge encoded result to DB format)
  ///
  /// Invariant: DB Commit can always extract DB-ready bytes without encoding.
  /// For DecodedGraphSource: originalSource!.bytes
  /// For EncodedRdfGraphSource: bytes directly
  final RdfGraphSource graphSource;

  final CurrentCrdtClock clock;
  final List<IriTerm> shardIris;
  final List<MissingGroupIndex> missingGroupIndices;

  /// ETag from remote download (for conditional upload).
  final String? remoteEtag;

  /// Whether this resource needs upload to remote.
  /// Determined by Merge — no other stage second-guesses this.
  /// false for remote-only (remote already has latest).
  final bool needsUpload;

  const MergedResource({
    required this.documentIri,
    required this.typeIri,
    required this.graphSource,
    required this.clock,
    required this.shardIris,
    required this.missingGroupIndices,
    this.remoteEtag,
    required this.needsUpload,
  });
}
```

### UploadedResource

```dart
/// A resource that has been through the Upload stage.
/// For needsUpload resources: upload completed, uploadEtag captured.
/// For non-upload resources: passed through unchanged.
class UploadedResource {
  final IriTerm documentIri;
  final IriTerm typeIri;

  /// Same graphSource as MergedResource — DB Commit reads bytes from here.
  final RdfGraphSource graphSource;

  final CurrentCrdtClock clock;
  final List<IriTerm> shardIris;
  final List<MissingGroupIndex> missingGroupIndices;

  /// ETag from upload response (for needsUpload items),
  /// or original remoteEtag from download (for non-upload items).
  final String? etag;

  const UploadedResource({
    required this.documentIri,
    required this.typeIri,
    required this.graphSource,
    required this.clock,
    required this.shardIris,
    required this.missingGroupIndices,
    this.etag,
  });
}
```

### CommittedResource

```dart
/// A resource that has been committed to DB (and previously uploaded if needed).
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

## Remote Index Mirror: Backend-Owned with Callback

The mirror is **owned by the Remote Backend**, not by Core. Core provides a callback mechanism so the backend can persist its mirror data atomically within Core's commit transaction.

### Mirror Callback Interface

```dart
/// Callback invoked by Core's DB Commit stage within the commit transaction.
/// The backend uses this to persist whatever mirror data it needs.
///
/// Runs inside the same Drift transaction as Core's document/index/ETag writes.
/// If the callback throws, the entire transaction rolls back — both Core state
/// and mirror data stay consistent.
typedef CommitCallback = Future<void> Function(List<UploadedResource> batch);
```

### Convenience Mirror Services

Core provides optional services that backends can use within their `CommitCallback`:

```dart
/// Standard index mirror — stores (resourceIri, shardIri, clockHash).
/// Sufficient for backends that only need to track what exists remotely.
abstract class RemoteIndexMirrorService {
  /// Get mirror entries for multiple shards in a single query.
  Future<Map<IriTerm, List<RemoteMirrorEntry>>> getEntries(
    RemoteId remoteId,
    Iterable<IriTerm> shardIris,
  );

  /// Bulk upsert mirror entries. Call within CommitCallback.
  Future<void> saveEntries(
    RemoteId remoteId,
    List<SaveRemoteMirrorEntryRequest> entries,
  );

  /// Remove mirror entries for deleted resources.
  Future<void> deleteEntries(
    RemoteId remoteId,
    List<({IriTerm resourceIri, IriTerm shardIri})> entries,
  );
}

/// Content mirror — stores full resource content per shard.
/// For backends like GDrive that benefit from local copies of aggregated data.
abstract class RemoteContentMirrorService {
  Future<EncodedRdfGraphSource?> getContent(
    RemoteId remoteId,
    IriTerm documentIri,
  );

  Future<void> saveContent(
    RemoteId remoteId,
    IriTerm documentIri,
    EncodedRdfGraphSource content,
  );

  Future<void> deleteContent(
    RemoteId remoteId,
    IriTerm documentIri,
  );
}
```

### Mirror Data Types

```dart
/// Last known view of one resource's presence in one shard on a remote.
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

### Backend Example

```dart
// A Solid backend uses only the index mirror:
class SolidBackend {
  final RemoteIndexMirrorService _indexMirror;

  CommitCallback get onCommit => (batch) async {
    final entries = batch.map((r) => SaveRemoteMirrorEntryRequest(
      resourceIri: r.documentIri,
      shardIri: r.shardIris.first,
      clockHash: r.clock.hash,
    )).toList();
    await _indexMirror.saveEntries(remoteId, entries);
  };
}

// A GDrive backend stores full content too:
class GDriveBackend {
  final RemoteIndexMirrorService _indexMirror;
  final RemoteContentMirrorService _contentMirror;

  CommitCallback get onCommit => (batch) async {
    // Index mirror
    final entries = batch.map((r) => SaveRemoteMirrorEntryRequest(
      resourceIri: r.documentIri,
      shardIri: r.shardIris.first,
      clockHash: r.clock.hash,
    )).toList();
    await _indexMirror.saveEntries(remoteId, entries);

    // Content mirror — store full resource data
    for (final r in batch) {
      if (r.graphSource case EncodedRdfGraphSource source) {
        await _contentMirror.saveContent(remoteId, r.documentIri, source);
      } else if (r.graphSource case DecodedGraphSource(originalSource: final src?)
          when src != null) {
        await _contentMirror.saveContent(remoteId, r.documentIri, src);
      }
    }
  };
}
```

## Pipeline Transform Signatures

The pipeline is composed of pure functions returning `StreamTransformer`s. No orchestrator class.

### Remote Discovery

```dart
/// Creates the root stream: traverses the index hierarchy top-down,
/// emitting entries + boundaries.
///
/// Internal traversal:
///   IoI-Index → IoI-Shards → Indices → Shards → Entries
///   ETag-conditional downloads; 304 → skip shard, 404 → empty shard
///
/// Output:
///   DiscoveryData(entry) for each resource in each changed shard
///   DiscoveryBoundary(ShardComplete) after all entries of a shard
///   DiscoveryBoundary(LevelComplete) after all shards of a level
Stream<DiscoveryEvent> remoteDiscovery({
  required RemoteConfig remoteConfig,
  required RemoteSyncStateReader syncState,
});
```

### Diff Transform

```dart
/// Compares remote entries against local + mirror state.
///
/// Per DiscoveryData:
///   DB lookup for local index entry + mirror entry
///   → RemoteOnly / Conflict / skip (same hash)
///
/// Per ShardComplete boundary:
///   Query local index for items in this shard changed since last sync
///   (updatedAt > lastSyncTimestamp) that were NOT seen in the remote
///   → emit LocalOnlyCandidate for each
///
/// Per LevelComplete boundary:
///   Query local items changed since last sync not seen in ANY shard
///   → emit LocalOnlyCandidate for remainder
///
/// Deduplication: tracks seen resourceIris across all shards.
StreamTransformer<DiscoveryEvent, DiffEvent> diffTransform({
  required Storage storage,
  required RemoteId remoteId,
  required int lastSyncTimestamp,
});
```

### Resource Fetch Transform

```dart
/// Resolves SyncCandidates to FetchedCandidates with graph content.
///
/// For RemoteOnlyCandidate / ConflictCandidate:
///   Sends FetchRequest through backend transform → EncodedRdfGraphSource
///
/// For LocalOnlyCandidate:
///   Loads raw bytes from DB → BinaryGraphSource (no decoding)
///
/// All content stays in its natural format — no preemptive decoding.
/// Batches requests for concurrent I/O.
/// Forwards boundaries unchanged.
StreamTransformer<DiffEvent, FetchEvent> fetchTransform({
  required StreamTransformer<FetchRequest, FetchResult> backendFetch,
  required Storage storage,
});
```

### Backend Fetch Transform

```dart
/// Backend-specific content retrieval.
///
/// Each backend implements this differently:
/// - Solid: individual HTTP requests → BinaryGraphSource
/// - DirBackend: file reads (or internal shard cache) → TextGraphSource / BinaryGraphSource
/// - GDrive: internal aggregate cache → BinaryGraphSource
///
/// Always returns EncodedRdfGraphSource — never decodes.
/// Backends that need CPU-intensive operations (parsing aggregate files,
/// format conversion for uploads) compose their own internal sub-stages
/// to keep CPU and I/O separated.
/// The pipeline doesn't know or care which strategy is used.
/// Backend-internal caching and sub-stages are invisible to the pipeline.
StreamTransformer<FetchRequest, FetchResult> backendFetchTransform(
  BackendConfig backend,
);
```

### CRDT Merge Transform

```dart
/// Applies CRDT merge, decoding RdfGraphSource only where needed.
/// Ensures output is ready for I/O-only stages (no CPU in I/O stages).
///
/// For FetchedRemoteOnly: decode to extract metadata (typeIri, clock,
///   shards). Ensure originalSource is in DB format (reuse remote bytes
///   if already Jelly, otherwise encode to Jelly).
/// For FetchedLocalOnly: pass EncodedRdfGraphSource through without
///   decoding — metadata comes from index entry (knownShardIris, etc.)
///   Content is already in DB format (loaded from DB).
/// For FetchedConflict: full CRDT merge (decode both sides), encode
///   merged result to DB format.
///
/// Backends handle their own upload format needs internally.
/// Forwards boundaries unchanged.
StreamTransformer<FetchEvent, MergeEvent> mergeTransform({
  required FastPathMerger merger,
});
```

### Upload Transform

```dart
/// Uploads resources that need it; passes others through unchanged.
/// **Pure Remote I/O — no DB access, no decoding or encoding.**
///
/// For needsUpload: true → upload content to backend, capture ETag
/// For needsUpload: false → wrap in UploadedResource, pass through
///
/// Content for upload: raw bytes from MergedResource.graphSource.
/// Backends with complex upload formats (e.g., GDrive aggregate files)
/// handle format transformation internally.
///
/// Batches for concurrent uploads (configurable).
/// Forwards boundaries after batch flush.
StreamTransformer<MergeEvent, UploadEvent> uploadTransform({
  required BackendConfig backend,
  int maxConcurrentUploads = 10,
});
```

### DB Commit Transform

```dart
/// Batches uploaded resources, commits to DB with backend mirror callback.
/// **Pure DB I/O — no remote calls, no decoding or encoding.**
///
/// Reads DB-ready bytes from UploadedResource.graphSource:
///   - EncodedRdfGraphSource: .bytes directly
///   - DecodedGraphSource: .originalSource!.bytes (Merge guaranteed DB format)
///
/// Collects UploadData into bounded batch.
/// Flush triggers:
///   - Batch full (configurable size)
///   - Any boundary event
///
/// Each flush runs a single atomic DB transaction:
///   1. Documents (raw bytes)
///   2. Index entries
///   3. ETags (including upload ETags from Upload stage)
///   4. backend.onCommit(batch) — backend-owned mirror callback
///
/// The backend callback runs inside the same Drift transaction.
/// Core has no knowledge of what the backend persists — it could be
/// minimal metadata, full resource content, or nothing at all.
///
/// Forwards boundaries after flush completes.
StreamTransformer<UploadEvent, CommitEvent> dbCommitTransform({
  required Storage storage,
  required RemoteId remoteId,
  required CommitCallback backendOnCommit,
  required DateTime syncTime,
  int batchSize = 1000,
});
```

### Shard Finalize Transform

```dart
/// Terminal transform: generates and uploads shard documents.
///
/// Tracks committed resources per shard.
/// At ShardComplete boundary:
///   - Generate shard document from DB (canonical state)
///   - Upload to remote
///   - Commit shard metadata
///
/// At LevelComplete boundary:
///   - (Future: generate index documents if needed)
///
/// This is a terminal transform — downstream is drain().
StreamTransformer<CommitEvent, void> finalizeTransform({
  required Storage storage,
  required BackendConfig backend,
  required RemoteId remoteId,
  required DateTime syncTime,
});
```

## Pipeline Composition

```dart
/// Full pipeline — no orchestrator class, just composed transforms.
Future<void> streamingSync({
  required RemoteConfig remote,
  required Storage storage,
  required BackendConfig backend,
  required DateTime syncTime,
}) async {
  final lastSyncTimestamp = await storage.getLastRemoteSyncTimestamp(remote.id);

  final pipeline = remoteDiscovery(
    remoteConfig: remote,
    syncState: storage.remoteSyncState,
  )
  .transform(diffTransform(
    storage: storage,
    remoteId: remote.id,
    lastSyncTimestamp: lastSyncTimestamp,
  ))
  .transform(fetchTransform(
    backendFetch: backendFetchTransform(backend),
    storage: storage,
  ))
  .transform(mergeTransform(
    merger: FastPathMerger(...),
  ))
  .transform(uploadTransform(
    backend: backend,
  ))
  .transform(dbCommitTransform(
    storage: storage,
    remoteId: remote.id,
    backendOnCommit: backend.onCommit,
    syncTime: syncTime,
  ))
  .transform(finalizeTransform(
    storage: storage,
    backend: backend,
    remoteId: remote.id,
    syncTime: syncTime,
  ));

  await pipeline.drain();

  await storage.updateLastRemoteSyncTimestamp(
    remote.id, syncTime.millisecondsSinceEpoch);
}
```

## Configuration

```dart
/// Configuration for the streaming sync pipeline.
class StreamingSyncConfig {
  /// Resources per DB transaction in the DB Commit stage.
  final int commitBatchSize;

  /// Maximum concurrent resource fetches via backend transform.
  final int maxConcurrentFetches;

  /// Maximum concurrent uploads in the Upload stage.
  final int maxConcurrentUploads;

  /// Whether to use the streaming pipeline (vs. legacy).
  final bool useStreamingSync;

  const StreamingSyncConfig({
    this.commitBatchSize = 1000,
    this.maxConcurrentFetches = 10,
    this.maxConcurrentUploads = 10,
    this.useStreamingSync = false,
  });
}
```

## Testing Strategy

### Unit Tests per Transform

Each transform is independently testable with synthetic input streams:

```dart
test('diffTransform emits RemoteOnlyCandidate for new remote entries', () async {
  final input = Stream.fromIterable([
    DiscoveryData(RemoteShardEntry(
      resourceIri: IriTerm('urn:test:1'),
      documentIri: IriTerm('urn:doc:1'),
      shardIri: shardIri,
      clockHash: 'abc123',
    )),
    DiscoveryBoundary(ShardComplete(shardIri: shardIri)),
  ]);

  final output = await input.transform(diffTransform(
    storage: mockStorage, // empty local
    remoteId: remoteId,
    lastSyncTimestamp: 0,
  )).toList();

  expect(output, [
    isA<DiffData>().having((d) => d.candidate, 'candidate',
        isA<RemoteOnlyCandidate>()),
    isA<DiffBoundary>(),
  ]);
});

test('diffTransform emits LocalOnlyCandidate at ShardComplete for changed items', () async {
  // Setup: local item changed since last sync, not in remote shard
  final input = Stream.fromIterable([
    DiscoveryBoundary(ShardComplete(shardIri: shardIri)),
  ]);

  // storage.getLocalChangedSince(lastSyncTimestamp, shardIri) returns [item]
  final output = await input.transform(diffTransform(
    storage: mockStorageWithChangedItem,
    remoteId: remoteId,
    lastSyncTimestamp: lastSync,
  )).toList();

  expect(output, [
    isA<DiffData>().having((d) => d.candidate, 'candidate',
        isA<LocalOnlyCandidate>()),
    isA<DiffBoundary>(),
  ]);
});

test('mergeTransform takes fast path for remote-only', () async {
  final input = Stream.fromIterable([
    FetchData(FetchedRemoteOnly(
      documentIri: docIri,
      resourceIri: resIri,
      remoteContent: TextGraphSource(turtleContent, ContentType.turtle),
    )),
  ]);

  final output = await input.transform(mergeTransform(
    merger: fastPathMerger,
  )).toList();

  // Verify: no full CRDT merge invoked
  expect(output.single, isA<MergeData>()
      .having((m) => m.resource.needsUpload, 'needsUpload', false));
});

test('dbCommitTransform flushes batch at boundary', () async {
  final input = Stream.fromIterable([
    UploadData(uploadedResource1),
    UploadData(uploadedResource2),
    UploadBoundary(ShardComplete(shardIri: shardIri)),
  ]);

  final output = await input.transform(dbCommitTransform(
    storage: mockStorage,
    remoteId: remoteId,
    backendOnCommit: mockBackend.onCommit,
    syncTime: now,
    batchSize: 1000, // larger than 2
  )).toList();

  // Verify: batch flushed at boundary despite batch not being full
  expect(output.whereType<CommitData>(), hasLength(2));
  verify(mockStorage.saveBatch(any)).called(1); // single transaction
  verify(mockBackend.onCommit(any)).called(1); // backend callback in same tx
});

test('boundaries flow through entire pipeline', () async {
  // Verify: ShardComplete emitted by Discovery arrives at Finalize
  final discoveryStream = Stream.fromIterable([
    DiscoveryBoundary(ShardComplete(shardIri: shardIri)),
  ]);

  // Each transform should forward the boundary
  final afterDiff = await discoveryStream.transform(diffTransform(...)).toList();
  expect(afterDiff.single, isA<DiffBoundary>());

  // ... and so on through fetch, merge, upload, dbCommit
});
```

### Integration Tests

```dart
test('streaming pipeline produces same result as legacy', () async {
  // Populate remote with test data
  // Legacy sync → DB A
  // Streaming sync → DB B
  // Assert: DB A == DB B (documents, index entries, ETags, mirror)
});

test('remote index mirror is consistent after sync', () async {
  // Streaming sync
  // Verify: mirror entries == actual remote shard contents
});

test('crash recovery: partial sync resumes correctly', () async {
  // Interrupt pipeline after N commits
  // Mirror reflects only committed resources
  // Resume sync → remaining resources synced, no duplicates
  // (CRDT idempotency guarantees correctness even without perfect crash recovery)
});
```

### Benchmark Tests

```dart
test('streaming pipeline outperforms legacy on 15k resources', () async {
  // 15,000 resources in remote (initial pull)
  // Legacy: measure time
  // Streaming: measure time
  // Assert: streaming < legacy / 3
});
```
