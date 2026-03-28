/// Typed events that flow through the streaming sync pipeline.
///
/// Each stage has its own input/output event type. Boundary events
/// ([ShardComplete], [PhaseComplete]) flow inline with data.
library;

import 'dart:typed_data';

import 'package:locorda_core/src/hlc_service.dart' show CurrentCrdtClock;
import 'package:locorda_core/src/index/index_config_base.dart'
    show RootResourceFetchPolicy;
import 'package:locorda_core/src/index/shard_determiner.dart'
    show MissingGroupIndex;
import 'package:locorda_core/src/storage/storage_interface.dart'
    show IndexEntryWithIri, StoredDocument;
import 'package:locorda_rdf_core/core.dart';

// ---------------------------------------------------------------------------
// IriStorageId — opaque handle for storage-internal IRI identifiers
// ---------------------------------------------------------------------------

/// Opaque storage-internal identifier for an IRI.
///
/// The concrete type is determined by the storage implementation
/// (e.g. [int] for Drift, [IriTerm] for in-memory).
/// Only the storage layer that produced this value may cast it to its
/// concrete type.
typedef IriStorageId = dynamic;

// ---------------------------------------------------------------------------
// Pipeline input
// ---------------------------------------------------------------------------

/// Per-index metadata carried in [SyncInput] for Stage 1.
class IndexInputInfo {
  final RootResourceFetchPolicy fetchPolicy;
  final IriTerm typeIri;

  const IndexInputInfo(this.fetchPolicy, this.typeIri);
}

/// A batch of index IRIs to be processed by the pipeline.
///
/// The Feedback Stage always injects exactly one [SyncInput] per phase —
/// never multiple individual items. This guarantees that Stage 1 can resolve
/// all shards for the entire batch in two bulk DB queries.
class SyncInput {
  /// Index IRIs to process in this batch.
  final List<IriTerm> indexIris;

  /// Retry counter — incremented on re-injection by the Feedback Stage.
  /// If > 4, the pipeline aborts (meta-indices are oscillating).
  final int retryCount;

  /// Per-index metadata (fetch policy, resource type IRI).
  ///
  /// Built by the pipeline orchestrator (initial input) or the Feedback Stage
  /// (re-injection / content-phase transition). Stage 1 reads this to populate
  /// [ShardRef.fetchPolicy] and [ShardRef.typeIri].
  final Map<IriTerm, IndexInputInfo> indexInfos;

  /// Clock hashes of the meta-index documents (IoI, IoGI) at the moment this
  /// meta-index-phase input was injected.
  ///
  /// The Feedback Stage compares these against the DB values after the
  /// iteration to detect whether any meta-index changed.
  /// Null for content-phase inputs (no stability check needed).
  final Map<IriTerm, String>? metaIndexClockHashes;

  const SyncInput(
    this.indexIris, {
    this.retryCount = 0,
    this.indexInfos = const {},
    this.metaIndexClockHashes,
  });

  /// Whether this input represents a meta-index phase.
  bool get isMetaIndexPhase => metaIndexClockHashes != null;
}

// ---------------------------------------------------------------------------
// Boundary events
// ---------------------------------------------------------------------------

/// Marker base for boundary events that flow inline with data.
sealed class Boundary {
  const Boundary();
}

/// All resources in this shard have been emitted / processed.
///
/// Introduced by Stage 4 (Change Detection) after the 1:N fan-out.
class ShardComplete extends Boundary {
  final IriTerm shardIri;

  /// Storage-internal identifier for the shard IRI.
  /// Propagated from [ShardRef] so Stage 10 can call
  /// `getActiveIndexEntriesForShard(shardStorageId)` without an IRI→ID lookup.
  final IriStorageId shardStorageId;

  /// The parsed remote shard graph for CRDT merging in Stage 11.
  /// Null for 304 (not modified) and gone shards — no remote merge needed.
  final DecodedGraphSource? remoteShardGraph;

  /// The new ETag from the remote fetch (for persisting after shard finalize).
  final String? newEtag;

  /// Whether this shard already exists on the remote (had a stored ETag or
  /// received a 200 response). Used by Stage 11 to decide whether an unchanged
  /// shard needs uploading (new shard → yes, existing shard → no).
  final bool existsOnRemote;

  const ShardComplete(
    this.shardIri,
    this.shardStorageId, {
    this.remoteShardGraph,
    this.newEtag,
    this.existsOnRemote = false,
  });
}

/// All shards of this [SyncInput] batch have been emitted / processed.
/// Signals the end of a complete pipeline pass.
class PhaseComplete extends Boundary {
  final SyncInput source;
  final int processedShardCount;

  /// Indices from the batch that had 0 shards (safety-net candidates).
  final List<IriTerm> zeroShardIndices;

  const PhaseComplete(
    this.source,
    this.processedShardCount, {
    this.zeroShardIndices = const [],
  });
}

// ---------------------------------------------------------------------------
// RdfGraphSource hierarchy — lazy-decode graph representation
// ---------------------------------------------------------------------------

/// A graph source that may or may not be decoded yet.
///
/// Data flows through the pipeline in whatever format it naturally arrives in,
/// and is only decoded where the decoded form is actually needed.
sealed class RdfGraphSource {
  const RdfGraphSource();

  /// Decode this source into a [DecodedGraphSource].
  ///
  /// If already decoded, returns `this` without calling [rdfCore].
  DecodedGraphSource decodeWith(RdfCore rdfCore);
}

/// Raw encoded content that has not been decoded yet.
sealed class EncodedRdfGraphSource extends RdfGraphSource {
  /// Content type for decoding (e.g. 'text/turtle', 'application/x-jelly-rdf').
  String get contentType;

  const EncodedRdfGraphSource();
}

/// Text-based encoded graph (Turtle, JSON-LD, N-Triples, …).
class TextGraphSource extends EncodedRdfGraphSource {
  final String text;

  @override
  final String contentType;

  const TextGraphSource(this.text, {required this.contentType});

  @override
  DecodedGraphSource decodeWith(RdfCore rdfCore) {
    final graph = rdfCore.decode(text, contentType: contentType);
    return DecodedGraphSource(graph, originalSource: this);
  }
}

/// Binary-encoded graph (Jelly, CBOR-LD, …).
class BinaryGraphSource extends EncodedRdfGraphSource {
  final Uint8List bytes;

  @override
  final String contentType;

  const BinaryGraphSource(this.bytes, {required this.contentType});

  @override
  DecodedGraphSource decodeWith(RdfCore rdfCore) {
    final decoded = rdfCore.decodeBinary(bytes, contentType: contentType);
    return DecodedGraphSource(decoded, originalSource: this);
  }
}

/// A decoded graph, optionally preserving the original encoded form.
class DecodedGraphSource extends RdfGraphSource {
  final RdfGraph graph;

  /// The original encoded source, if available.
  /// Downstream I/O stages can use raw bytes directly (no re-encoding).
  final EncodedRdfGraphSource? originalSource;

  const DecodedGraphSource(this.graph, {this.originalSource});

  @override
  DecodedGraphSource decodeWith(RdfCore rdfCore) => this;
}

// ---------------------------------------------------------------------------
// Stage 1 output: Shard Resolution
// ---------------------------------------------------------------------------

/// Reference to a shard to be fetched by Stage 2.
class ShardRef implements ShardRefEvent {
  final IriTerm indexIri;
  final IriTerm shardIri;
  final IriStorageId shardStorageId;

  /// Fetch policy for resources in this shard's index.
  final RootResourceFetchPolicy fetchPolicy;

  /// Resource type IRI for this shard's index.
  final IriTerm typeIri;

  /// Stored ETag for conditional GET. Null if no previous fetch.
  final String? storedEtag;

  const ShardRef(
    this.indexIri,
    this.shardIri,
    this.shardStorageId,
    this.fetchPolicy,
    this.typeIri, {
    this.storedEtag,
  });
}

// ---------------------------------------------------------------------------
// Stage 2 output: Shard Fetch
// ---------------------------------------------------------------------------

/// Result of fetching a shard document from remote.
sealed class FetchedShard implements FetchedShardEvent {
  const FetchedShard();
}

/// HTTP 200: shard data available.
class ShardContent extends FetchedShard {
  final IriTerm shardIri;

  /// Storage-internal identifier for this shard, or `null` if Stage 1 did not
  /// know about this shard (proactively injected during the content phase by
  /// an aggregating backend).
  final IriStorageId? shardStorageId;

  /// Fetch policy for resources in this shard's index.
  /// Null for backend-injected shards (where [allResourcesAvailable] is true).
  final RootResourceFetchPolicy? fetchPolicy;

  /// Resource type IRI. Null for backend-injected shards.
  final IriTerm? typeIri;

  final RdfGraphSource source;
  final String newEtag;

  /// When `true`, the backend has pre-fetched ALL resource graphs for this
  /// shard (e.g., from a dataset file). Core overrides fetch policy and
  /// processes all entries.
  final bool allResourcesAvailable;

  const ShardContent(
    this.shardIri,
    this.shardStorageId,
    this.fetchPolicy,
    this.typeIri,
    this.source,
    this.newEtag, {
    this.allResourcesAvailable = false,
  });
}

/// HTTP 304: shard unchanged.
class ShardNotModified extends FetchedShard {
  final IriTerm shardIri;
  final IriStorageId shardStorageId;
  final RootResourceFetchPolicy fetchPolicy;
  final IriTerm typeIri;

  /// Whether the shard exists on remote (true for 304, false for 404-never-existed).
  final bool existsOnRemote;

  const ShardNotModified(
      this.shardIri, this.shardStorageId, this.fetchPolicy, this.typeIri,
      {this.existsOnRemote = true});
}

/// HTTP 404/410: shard removed.
class ShardGone extends FetchedShard {
  final IriTerm shardIri;
  final IriStorageId shardStorageId;
  final RootResourceFetchPolicy fetchPolicy;
  final IriTerm typeIri;

  const ShardGone(
      this.shardIri, this.shardStorageId, this.fetchPolicy, this.typeIri);
}

// ---------------------------------------------------------------------------
// Stage 3 output: Shard Parse
// ---------------------------------------------------------------------------

/// Entry within a parsed shard document.
class ShardEntry {
  final IriTerm resourceIri;
  final String clockHash;

  const ShardEntry(this.resourceIri, this.clockHash);
}

/// Result of parsing a fetched shard.
sealed class ShardResult implements ParsedShardEvent {
  const ShardResult();
}

/// Decoded shard with extracted entries.
class ParsedShard extends ShardResult {
  final IriTerm shardIri;
  final IriStorageId shardStorageId;

  /// Fetch policy for resources in this shard's index.
  /// Null for backend-injected shards (where [allResourcesAvailable] is true).
  final RootResourceFetchPolicy? fetchPolicy;

  /// Resource type IRI. Null for backend-injected shards.
  final IriTerm? typeIri;

  final List<ShardEntry> entries;
  final DecodedGraphSource decodedGraph;
  final String newEtag;
  final bool allResourcesAvailable;

  const ParsedShard(
    this.shardIri,
    this.shardStorageId,
    this.fetchPolicy,
    this.typeIri,
    this.entries,
    this.decodedGraph,
    this.newEtag, {
    this.allResourcesAvailable = false,
  });
}

/// Shard not modified — pass-through from Stage 2.
class ShardResultNotModified extends ShardResult {
  final IriTerm shardIri;
  final IriStorageId shardStorageId;
  final RootResourceFetchPolicy fetchPolicy;
  final IriTerm typeIri;

  /// Whether the shard exists on remote (true for 304, false for 404-never-existed).
  final bool existsOnRemote;

  const ShardResultNotModified(
      this.shardIri, this.shardStorageId, this.fetchPolicy, this.typeIri,
      {this.existsOnRemote = true});
}

/// Shard gone — pass-through from Stage 2.
class ShardResultGone extends ShardResult {
  final IriTerm shardIri;
  final IriStorageId shardStorageId;
  final RootResourceFetchPolicy fetchPolicy;
  final IriTerm typeIri;

  const ShardResultGone(
      this.shardIri, this.shardStorageId, this.fetchPolicy, this.typeIri);
}

// ---------------------------------------------------------------------------
// Stage 4 output: Change Detection
// ---------------------------------------------------------------------------

/// Classification of how a resource should be synced.
enum SyncDirection {
  /// New from remote — not present locally.
  remoteOnly,

  /// Exists locally, not in remote shard — needs upload.
  localOnly,

  /// Both sides have different clockHash — needs merge.
  conflictCandidate,

  /// Shard was removed remotely — local entries need cleanup.
  remoteRemoved,
}

/// A resource classified for sync by Stage 4.
class SyncCandidate implements SyncCandidateEvent {
  final IriTerm resourceIri;
  final IriStorageId shardStorageId;
  final SyncDirection direction;

  /// Resource type IRI from the index configuration.
  final IriTerm typeIri;

  final String? localClockHash;
  final String? remoteClockHash;

  const SyncCandidate(
    this.resourceIri,
    this.shardStorageId,
    this.direction,
    this.typeIri, {
    this.localClockHash,
    this.remoteClockHash,
  });
}

// ---------------------------------------------------------------------------
// Stage 5 output: Resource Fetch
// ---------------------------------------------------------------------------

/// A candidate with its remote graph source fetched.
class FetchedCandidate implements FetchedCandidateEvent {
  final SyncCandidate candidate;

  /// Remote graph source — null for [SyncDirection.localOnly].
  final RdfGraphSource? remoteSource;

  /// ETag of the remote resource, for conditional upload in Stage 8.
  /// Null for [SyncDirection.localOnly] (no remote fetch performed).
  final String? remoteEtag;

  const FetchedCandidate(this.candidate, {this.remoteSource, this.remoteEtag});
}

// ---------------------------------------------------------------------------
// Stage 6 output: Local Content Load
// ---------------------------------------------------------------------------

/// A candidate with both remote and local graph sources loaded.
class LoadedCandidate implements LoadedCandidateEvent {
  final SyncCandidate candidate;
  final RdfGraphSource? remoteSource;

  /// Local graph source — null for [SyncDirection.remoteOnly].
  final RdfGraphSource? localSource;

  /// Local document's `updatedAt` timestamp for optimistic locking in Stage 9.
  /// Null for [SyncDirection.remoteOnly] (no local document).
  final int? localUpdatedAt;

  /// ETag of the remote resource, for conditional upload in Stage 8.
  final String? remoteEtag;

  const LoadedCandidate(
    this.candidate, {
    this.remoteSource,
    this.localSource,
    this.localUpdatedAt,
    this.remoteEtag,
  });
}

// ---------------------------------------------------------------------------
// Stage 7 output: CRDT Merge
// ---------------------------------------------------------------------------

/// Result of CRDT merging a resource.
class MergeResult implements MergedResourceEvent {
  final IriTerm resourceIri;

  /// Resource type IRI, propagated for Stage 9 DB commit.
  final IriTerm typeIri;

  /// The reconciled (shard-assignment-corrected) merged graph.
  final DecodedGraphSource mergedGraph;

  /// Jelly-encoded bytes for DB commit — no further CPU in Stage 9.
  final BinaryGraphSource encodedForDb;

  /// Whether the merged result needs to be uploaded to remote.
  final bool needsUpload;

  /// Whether the merged result needs to be written to DB.
  final bool needsDbWrite;

  /// ETag from remote fetch, for upload conflict detection.
  final String? resourceEtag;

  /// Local document's `updatedAt` for optimistic locking in Stage 9.
  final int? localUpdatedAt;

  /// CRDT clock extracted from the reconciled merged document.
  /// Used by Stage 9 to set `ourPhysicalClock` in [DocumentMetadata].
  final CurrentCrdtClock clock;

  /// Missing GroupIndex documents discovered during shard reconciliation.
  /// Passed to [IndexManager.prepareIndexEntryWrites] in Stage 9.
  final List<MissingGroupIndex> missingGroupIndices;

  const MergeResult(
    this.resourceIri,
    this.typeIri,
    this.mergedGraph,
    this.encodedForDb, {
    required this.needsUpload,
    required this.needsDbWrite,
    required this.clock,
    required this.missingGroupIndices,
    this.resourceEtag,
    this.localUpdatedAt,
  });
}

// ---------------------------------------------------------------------------
// Stage 8 output: Upload
// ---------------------------------------------------------------------------

/// Result of uploading a resource to remote.
class UploadResult implements UploadedResourceEvent {
  final MergeResult mergeResult;

  /// New ETag from remote after successful upload.
  final String? newRemoteEtag;

  const UploadResult(this.mergeResult, {this.newRemoteEtag});
}

// ---------------------------------------------------------------------------
// Stage 9 output: DB Commit
// ---------------------------------------------------------------------------

/// Result of committing a resource to the local DB.
class CommitResult implements CommittedResourceEvent {
  final IriTerm resourceIri;

  const CommitResult(this.resourceIri);
}

// ---------------------------------------------------------------------------
// Stage 10 output: Shard Entry Load
// ---------------------------------------------------------------------------

/// Loaded shard entries and shard document for CRDT merge in Stage 11.
class LoadedShardEntries implements LoadedShardEntriesEvent {
  final IriTerm shardIri;
  final IriStorageId shardStorageId;
  final List<IndexEntryWithIri> entries;

  /// Existing local shard document (may be absent for new shards).
  ///
  /// Carries both the decoded [RdfGraph] and [DocumentMetadata], which Stage 11
  /// needs to pass to [CrdtDocumentManager.prepareModify] for correct HLC
  /// clock handling and optimistic locking.
  final StoredDocument? localDoc;

  /// Remote shard graph from Stage 2's HTTP response.
  final DecodedGraphSource? remoteShardGraph;

  /// New ETag from Stage 2, for conditional PUT in Stage 12.
  final String? newEtag;

  /// Whether this shard already exists on the remote.
  final bool existsOnRemote;

  const LoadedShardEntries(
    this.shardIri,
    this.shardStorageId,
    this.entries, {
    this.localDoc,
    this.remoteShardGraph,
    this.newEtag,
    this.existsOnRemote = false,
  });
}

// ---------------------------------------------------------------------------
// Stage 11 output: Shard CRDT Merge
// ---------------------------------------------------------------------------

/// Result of CRDT merging a shard document.
class MergedShard implements MergedShardEvent {
  final IriTerm shardIri;
  final DecodedGraphSource mergedGraph;

  /// Jelly-encoded bytes for DB commit.
  final BinaryGraphSource encodedForDb;

  /// New ETag from remote fetch, for conditional PUT in Stage 12.
  final String? newEtag;

  /// Whether this shard needs to be uploaded.
  final bool needsUpload;

  /// Physical clock time from the CRDT merge result.
  /// Used by Stage 13 for [DocumentMetadata.ourPhysicalClock].
  final int ourPhysicalClock;

  const MergedShard(
    this.shardIri,
    this.mergedGraph,
    this.encodedForDb, {
    this.newEtag,
    required this.needsUpload,
    required this.ourPhysicalClock,
  });
}

// ---------------------------------------------------------------------------
// Stage 12 output: Shard Upload
// ---------------------------------------------------------------------------

/// Result of uploading a shard document to remote.
class UploadedShard implements UploadedShardEvent {
  final IriTerm shardIri;
  final MergedShard mergedShard;

  /// New ETag from remote after successful upload.
  final String? newRemoteEtag;

  const UploadedShard(this.shardIri, this.mergedShard, {this.newRemoteEtag});
}

// ---------------------------------------------------------------------------
// Stage 13 output: Shard DB Commit
// ---------------------------------------------------------------------------

/// Result of committing a shard document to the local DB.
class ShardCommitResult implements CommittedShardEvent {
  final IriTerm shardIri;

  const ShardCommitResult(this.shardIri);
}

// ---------------------------------------------------------------------------
// Per-stage sealed event hierarchies
//
// Each stage has a dedicated sealed event type for the stream it produces.
// Data events implement their stage's event type directly (zero overhead).
// Boundary events ([ShardComplete], [PhaseComplete]) are wrapped in a
// stage-specific boundary class that carries the original [Boundary] instance,
// allowing downstream stages to pattern-match exhaustively without casts.
// ---------------------------------------------------------------------------

/// Stream elements emitted by Stage 1 (Shard Resolution) — input to Stage 2.
sealed class ShardRefEvent {}

/// Boundary wrapper for [ShardRefEvent] streams.
final class ShardRefBoundary implements ShardRefEvent {
  final Boundary boundary;
  const ShardRefBoundary(this.boundary);
}

/// Stream elements emitted by Stage 2 (Shard Fetch) — input to Stage 3.
sealed class FetchedShardEvent {}

/// Boundary wrapper for [FetchedShardEvent] streams.
final class FetchedShardBoundary implements FetchedShardEvent {
  final Boundary boundary;
  const FetchedShardBoundary(this.boundary);
}

/// Stream elements emitted by Stage 3 (Shard Parse) — input to Stage 4.
sealed class ParsedShardEvent {}

/// Boundary wrapper for [ParsedShardEvent] streams.
final class ParsedShardBoundary implements ParsedShardEvent {
  final Boundary boundary;
  const ParsedShardBoundary(this.boundary);
}

/// Stream elements emitted by Stage 4 (Change Detection) — input to Stage 5.
sealed class SyncCandidateEvent {}

/// Boundary wrapper for [SyncCandidateEvent] streams.
final class SyncCandidateBoundary implements SyncCandidateEvent {
  final Boundary boundary;
  const SyncCandidateBoundary(this.boundary);
}

/// Stream elements emitted by Stage 5 (Resource Fetch) — input to Stage 6.
sealed class FetchedCandidateEvent {}

/// Boundary wrapper for [FetchedCandidateEvent] streams.
final class FetchedCandidateBoundary implements FetchedCandidateEvent {
  final Boundary boundary;
  const FetchedCandidateBoundary(this.boundary);
}

/// Stream elements emitted by Stage 6 (Local Content Load) — input to Stage 7.
sealed class LoadedCandidateEvent {}

/// Boundary wrapper for [LoadedCandidateEvent] streams.
final class LoadedCandidateBoundary implements LoadedCandidateEvent {
  final Boundary boundary;
  const LoadedCandidateBoundary(this.boundary);
}

/// Stream elements emitted by Stage 7 (CRDT Merge) — input to Stage 8.
sealed class MergedResourceEvent {}

/// Boundary wrapper for [MergedResourceEvent] streams.
final class MergedResourceBoundary implements MergedResourceEvent {
  final Boundary boundary;
  const MergedResourceBoundary(this.boundary);
}

/// Stream elements emitted by Stage 8 (Resource Upload) — input to Stage 9.
sealed class UploadedResourceEvent {}

/// Boundary wrapper for [UploadedResourceEvent] streams.
final class UploadedResourceBoundary implements UploadedResourceEvent {
  final Boundary boundary;
  const UploadedResourceBoundary(this.boundary);
}

/// Stream elements emitted by Stage 9 (DB Commit) — input to Stage 10.
sealed class CommittedResourceEvent {}

/// Boundary wrapper for [CommittedResourceEvent] streams.
final class CommittedResourceBoundary implements CommittedResourceEvent {
  final Boundary boundary;
  const CommittedResourceBoundary(this.boundary);
}

/// Stream elements emitted by Stage 10 (Shard Entry Load) — input to Stage 11.
sealed class LoadedShardEntriesEvent {}

/// Boundary wrapper for [LoadedShardEntriesEvent] streams.
final class LoadedShardEntriesBoundary implements LoadedShardEntriesEvent {
  final Boundary boundary;
  const LoadedShardEntriesBoundary(this.boundary);
}

/// Stream elements emitted by Stage 11 (Shard CRDT Merge) — input to Stage 12.
sealed class MergedShardEvent {}

/// Boundary wrapper for [MergedShardEvent] streams.
final class MergedShardBoundary implements MergedShardEvent {
  final Boundary boundary;
  const MergedShardBoundary(this.boundary);
}

/// Stream elements emitted by Stage 12 (Shard Upload) — input to Stage 13.
sealed class UploadedShardEvent {}

/// Boundary wrapper for [UploadedShardEvent] streams.
final class UploadedShardBoundary implements UploadedShardEvent {
  final Boundary boundary;
  const UploadedShardBoundary(this.boundary);
}

/// Stream elements emitted by Stage 13 (Shard DB Commit) — input to Stage 14.
/// Also the terminal output type of the pipeline (Stage 14 is a pass-through).
sealed class CommittedShardEvent {}

/// Boundary wrapper for [CommittedShardEvent] streams.
final class CommittedShardBoundary implements CommittedShardEvent {
  final Boundary boundary;
  const CommittedShardBoundary(this.boundary);
}
