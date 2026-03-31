/// Typed events that flow through the streaming sync pipeline.
///
/// Each stage has its own input/output event type. Boundary events
/// ([ShardComplete], [PhaseComplete]) flow inline with data.
library;

import 'dart:typed_data';

import 'package:locorda_core/src/config/sync_engine_config.dart'
    show CrdtIndexData;
import 'package:locorda_core/src/hlc_service.dart' show CurrentCrdtClock;
import 'package:locorda_core/src/index/index_config_base.dart'
    show RootResourceFetchPolicy;
import 'package:locorda_core/src/index/shard_determiner.dart'
    show ResolvedGroupIndex;
import 'package:locorda_core/src/mapping/merge_contract.dart'
    show MergeContract;
import 'package:locorda_core/src/storage/storage_interface.dart'
    show IndexEntryWithIri, SaveIndexEntryRequest, StoredDocument;
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
/// Flows from Stage 4 through Stage 9, then consumed by Stage 10.
class ShardComplete extends Boundary
    implements
        SyncCandidateEvent,
        FetchedCandidateEvent,
        DecodedCandidateEvent,
        PreloadedCandidateEvent,
        LoadedCandidateEvent,
        MergedResourceEvent,
        UploadedResourceEvent,
        CommittedResourceEvent {
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
/// Flows through all 13 stage boundaries unchanged.
class PhaseComplete extends Boundary
    implements
        ShardRefEvent,
        FetchedShardEvent,
        ParsedShardEvent,
        SyncCandidateEvent,
        FetchedCandidateEvent,
        DecodedCandidateEvent,
        PreloadedCandidateEvent,
        LoadedCandidateEvent,
        MergedResourceEvent,
        UploadedResourceEvent,
        CommittedResourceEvent,
        LoadedShardEntriesEvent,
        PreparedShardEvent,
        ContractLoadedShardEvent,
        MergedShardEvent,
        UploadedShardEvent,
        CommittedShardEvent {
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
    return DecodedGraphSource(
      graph,
      originalSource: this,
    );
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
    return DecodedGraphSource(
      decoded,
      originalSource: this,
    );
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

  ShardRef copyWith({
    IriTerm? indexIri,
    IriTerm? shardIri,
    IriStorageId? shardStorageId,
    RootResourceFetchPolicy? fetchPolicy,
    IriTerm? typeIri,
    String? storedEtag,
  }) =>
      ShardRef(
        indexIri ?? this.indexIri,
        shardIri ?? this.shardIri,
        shardStorageId ?? this.shardStorageId,
        fetchPolicy ?? this.fetchPolicy,
        typeIri ?? this.typeIri,
        storedEtag: storedEtag ?? this.storedEtag,
      );
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

  ShardContent copyWith({
    IriTerm? shardIri,
    RdfGraphSource? source,
  }) =>
      ShardContent(
        shardIri ?? this.shardIri,
        shardStorageId,
        fetchPolicy,
        typeIri,
        source ?? this.source,
        newEtag,
        allResourcesAvailable: allResourcesAvailable,
      );
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

  ShardNotModified copyWith({IriTerm? shardIri}) => ShardNotModified(
      shardIri ?? this.shardIri, shardStorageId, fetchPolicy, typeIri,
      existsOnRemote: existsOnRemote);
}

/// HTTP 404/410: shard removed.
class ShardGone extends FetchedShard {
  final IriTerm shardIri;
  final IriStorageId shardStorageId;
  final RootResourceFetchPolicy fetchPolicy;
  final IriTerm typeIri;

  const ShardGone(
      this.shardIri, this.shardStorageId, this.fetchPolicy, this.typeIri);

  ShardGone copyWith({IriTerm? shardIri}) => ShardGone(
      shardIri ?? this.shardIri, shardStorageId, fetchPolicy, typeIri);
}

// ---------------------------------------------------------------------------
// Stage 3 output: Shard Parse
// ---------------------------------------------------------------------------

/// Entry within a parsed shard document.
class ShardEntry {
  final IriTerm entryIri;
  final IriTerm resourceIri;
  final String clockHash;

  const ShardEntry(this.entryIri, this.resourceIri, this.clockHash);
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
///
/// These values describe the relationship between a resource's local state
/// and its presence in a specific remote shard. Note that a resource may
/// exist in multiple shards — these classifications are always relative to
/// the shard currently being processed.
enum SyncDirection {
  /// New from remote — not present locally.
  remoteOnly,

  /// Remote shard unchanged (HTTP 304), but resource was locally modified
  /// since last sync. The resource itself may have been changed remotely in
  /// a different shard — this only indicates *this* shard has not changed.
  remoteShardUnchanged,

  /// Resource exists locally but not in this remote shard's entries
  /// (parsed HTTP 200). Could be a new local resource never synced,
  /// a resource that moved shards, or a resource removed from this shard
  /// by another installation.
  notInRemoteShard,

  /// Both sides have different clockHash — needs merge.
  conflictCandidate,

  /// Entire shard was removed remotely (HTTP 404/410).
  /// The resource itself may still exist in other shards.
  shardGone,
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

  SyncCandidate copyWith({IriTerm? resourceIri}) => SyncCandidate(
        resourceIri ?? this.resourceIri,
        shardStorageId,
        direction,
        typeIri,
        localClockHash: localClockHash,
        remoteClockHash: remoteClockHash,
      );
}

// ---------------------------------------------------------------------------
// Stage 5 output: Local Content Load
// ---------------------------------------------------------------------------

/// A candidate with local graph content and stored remote ETag loaded from DB.
class LoadedCandidate implements LoadedCandidateEvent {
  final SyncCandidate candidate;

  /// Local graph source — null for [SyncDirection.remoteOnly].
  final RdfGraphSource? localSource;

  /// Local document's `updatedAt` timestamp for optimistic locking in Stage 9.
  /// Null for [SyncDirection.remoteOnly] (no local document).
  final int? localUpdatedAt;

  /// Stored remote ETag from DB, for conditional GET in Stage 6 and
  /// conditional upload in Stage 8 (for `localOnly` resources).
  final String? storedRemoteEtag;

  const LoadedCandidate(
    this.candidate, {
    this.localSource,
    this.localUpdatedAt,
    this.storedRemoteEtag,
  });

  LoadedCandidate copyWith({SyncCandidate? candidate}) => LoadedCandidate(
        candidate ?? this.candidate,
        localSource: localSource,
        localUpdatedAt: localUpdatedAt,
        storedRemoteEtag: storedRemoteEtag,
      );
}

// ---------------------------------------------------------------------------
// Stage 6 output: Resource Fetch
// ---------------------------------------------------------------------------

/// A candidate with its remote graph source fetched, wrapping the local data
/// from Stage 5.
class FetchedCandidate implements FetchedCandidateEvent {
  /// The local-loaded candidate from Stage 5.
  final LoadedCandidate loaded;

  /// Remote graph source — null for [SyncDirection.remoteShardUnchanged],
  /// [SyncDirection.notInRemoteShard], and [SyncDirection.shardGone].
  final RdfGraphSource? remoteSource;

  /// ETag of the remote resource from the HTTP response, for conditional
  /// upload in Stage 8. For non-fetch directions, this carries the stored
  /// ETag from [LoadedCandidate.storedRemoteEtag].
  final String? remoteEtag;

  const FetchedCandidate(this.loaded, {this.remoteSource, this.remoteEtag});

  FetchedCandidate copyWith({
    LoadedCandidate? loaded,
    RdfGraphSource? remoteSource,
  }) =>
      FetchedCandidate(
        loaded ?? this.loaded,
        remoteSource: remoteSource ?? this.remoteSource,
        remoteEtag: remoteEtag,
      );
}

// ---------------------------------------------------------------------------
// Stage 7a output: Decode & Classify
// ---------------------------------------------------------------------------

/// A candidate with decoded graphs and classified sync direction.
class DecodedCandidate implements DecodedCandidateEvent {
  final IriTerm resourceIri;
  final IriTerm documentIri;
  final IriTerm typeIri;
  final RdfGraph? localGraph;
  final RdfGraph? remoteGraph;

  /// Direction after upgrade (e.g. remoteOnly → conflictCandidate when local
  /// graph exists).
  final SyncDirection effectiveDirection;

  /// Governance IRIs extracted from local/remote graphs.
  final List<IriTerm> governanceIris;

  final int? localUpdatedAt;
  final String? remoteEtag;

  /// Clock hash from the local shard index entry (Stage 4).
  final String? localClockHash;

  /// Clock hash from the remote shard index entry (Stage 4).
  final String? remoteClockHash;

  const DecodedCandidate({
    required this.resourceIri,
    required this.documentIri,
    required this.typeIri,
    required this.localGraph,
    required this.remoteGraph,
    required this.effectiveDirection,
    required this.governanceIris,
    this.localUpdatedAt,
    this.remoteEtag,
    this.localClockHash,
    this.remoteClockHash,
  });
}

// ---------------------------------------------------------------------------
// Stage 7b output: Preload
// ---------------------------------------------------------------------------

/// A decoded candidate enriched with pre-loaded merge contract and index data.
class PreloadedCandidate implements PreloadedCandidateEvent {
  final DecodedCandidate decoded;
  final MergeContract mergeContract;

  /// Index configurations for this resource type (from [IndexDiscovery]).
  final Iterable<CrdtIndexData> indexConfigs;

  /// Pre-loaded index documents for sync [ShardDeterminer.determineShards].
  final Map<IriTerm, StoredDocument?> documents;

  /// Pre-extracted indexed property IRIs per index/template resource IRI.
  ///
  /// Keyed by FullIndex or GroupIndexTemplate resource IRI (with fragment).
  /// Values are the set of `idx:trackedProperty` IRIs to include in
  /// index entry headers — extracted from the already-loaded documents in 7b.
  final Map<IriTerm, Set<IriTerm>> indexedProperties;

  const PreloadedCandidate({
    required this.decoded,
    required this.mergeContract,
    required this.indexConfigs,
    required this.documents,
    required this.indexedProperties,
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

  /// Resolved GroupIndex documents discovered during shard reconciliation.
  /// Passed to [IndexManager.prepareIndexEntryWrites] in Stage 9 for
  /// batched existence check and on-demand creation.
  final List<ResolvedGroupIndex> resolvedGroupIndices;

  /// Pre-built index entry requests for active shards of this resource.
  ///
  /// Built in Stage 7c from pre-loaded data (no I/O). Entries have
  /// `updatedAt: 0` — Stage 9 stamps them with the actual commit timestamp
  /// via [SaveIndexEntryRequest.withUpdatedAt].
  final List<SaveIndexEntryRequest> indexEntries;

  /// Shard IRIs with CRDT deletion tombstones, extracted in Stage 7c.
  ///
  /// Stage 9 resolves the corresponding `indexIri` from the IndexShards
  /// DB table (batched query per flush) and builds tombstone
  /// [SaveIndexEntryRequest]s with `isDeleted: true`.
  final Set<IriTerm> tombstonedShardIris;

  const MergeResult(
    this.resourceIri,
    this.typeIri,
    this.mergedGraph,
    this.encodedForDb, {
    required this.needsUpload,
    required this.needsDbWrite,
    required this.clock,
    required this.resolvedGroupIndices,
    required this.indexEntries,
    this.tombstonedShardIris = const {},
    this.resourceEtag,
    this.localUpdatedAt,
  });

  MergeResult copyWith({
    IriTerm? resourceIri,
    DecodedGraphSource? mergedGraph,
  }) =>
      MergeResult(
        resourceIri ?? this.resourceIri,
        typeIri,
        mergedGraph ?? this.mergedGraph,
        encodedForDb,
        needsUpload: needsUpload,
        needsDbWrite: needsDbWrite,
        clock: clock,
        resolvedGroupIndices: resolvedGroupIndices,
        indexEntries: indexEntries,
        tombstonedShardIris: tombstonedShardIris,
        resourceEtag: resourceEtag,
        localUpdatedAt: localUpdatedAt,
      );
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

  /// The ETag to persist for this resource after Stage 9.
  ///
  /// Prefers the post-upload ETag ([newRemoteEtag]); falls back to the
  /// pre-upload remote ETag ([MergeResult.resourceEtag]) for remoteOnly
  /// resources that were not uploaded but must still record the remote
  /// ETag for future conditional PUTs.
  String? get remoteEtag => newRemoteEtag ?? mergeResult.resourceEtag;

  UploadResult copyWith({MergeResult? mergeResult}) => UploadResult(
        mergeResult ?? this.mergeResult,
        newRemoteEtag: newRemoteEtag,
      );
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
// Stage 11a output: Prepare Shard
// ---------------------------------------------------------------------------

/// A shard with pre-computed entry triples and extracted governance IRIs,
/// ready for merge contract loading.
class PreparedShard implements PreparedShardEvent {
  final IriTerm shardIri;
  final IriStorageId shardStorageId;
  final StoredDocument? localDoc;

  /// Index IRI this shard belongs to (from remote or local shard graph).
  final IriTerm indexIri;

  /// New RDF triples for shard entries (from [ShardDocumentGenerator]).
  final Iterable<Triple> entryTriples;

  /// Governance IRIs for merge contract loading in Stage 11b.
  final List<IriTerm> governanceIris;

  final String? newEtag;
  final bool existsOnRemote;

  const PreparedShard({
    required this.shardIri,
    required this.shardStorageId,
    required this.localDoc,
    required this.indexIri,
    required this.entryTriples,
    required this.governanceIris,
    this.newEtag,
    this.existsOnRemote = false,
  });
}

// ---------------------------------------------------------------------------
// Stage 11b output: Shard Contract Load
// ---------------------------------------------------------------------------

/// A prepared shard enriched with its merge contract.
class ContractLoadedShard implements ContractLoadedShardEvent {
  final PreparedShard prepared;
  final MergeContract mergeContract;

  const ContractLoadedShard({
    required this.prepared,
    required this.mergeContract,
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

  MergedShard copyWith({
    IriTerm? shardIri,
    DecodedGraphSource? mergedGraph,
  }) =>
      MergedShard(
        shardIri ?? this.shardIri,
        mergedGraph ?? this.mergedGraph,
        encodedForDb,
        newEtag: newEtag,
        needsUpload: needsUpload,
        ourPhysicalClock: ourPhysicalClock,
      );
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

  /// The ETag to persist for this shard after Stage 13.
  ///
  /// Prefers the post-upload ETag ([newRemoteEtag]); falls back to the
  /// pre-upload remote ETag ([MergedShard.newEtag]) for shards that were
  /// not uploaded but must still record the remote ETag.
  String? get remoteEtag => newRemoteEtag ?? mergedShard.newEtag;

  UploadedShard copyWith({
    IriTerm? shardIri,
    MergedShard? mergedShard,
  }) =>
      UploadedShard(
        shardIri ?? this.shardIri,
        mergedShard ?? this.mergedShard,
        newRemoteEtag: newRemoteEtag,
      );
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
// Boundary events ([ShardComplete], [PhaseComplete]) implement every event
// interface they flow through, so they pass through stage switches as-is —
// no wrapper allocations, no casts.
//
// [ShardComplete] implements stages 4–9 (introduced at 4, consumed at 10).
// [PhaseComplete] implements all 13 stage event types.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Shared batch-size default for all pipeline stages that support chunking.
// ---------------------------------------------------------------------------

/// Default batch size for pipeline stages that buffer events before flushing.
///
/// Chosen to stay within SQLite's default SQLITE_MAX_VARIABLE_NUMBER (999)
/// with headroom, while also being a reasonable chunk for remote I/O stages.
/// Individual stages accept an optional `batchSize` parameter to override.
const defaultPipelineBatchSize = 990;

/// Stream elements emitted by Stage 1 (Shard Resolution) — input to Stage 2.
sealed class ShardRefEvent {}

/// Stream elements emitted by Stage 2 (Shard Fetch) — input to Stage 3.
sealed class FetchedShardEvent {}

/// Stream elements emitted by Stage 3 (Shard Parse) — input to Stage 4.
sealed class ParsedShardEvent {}

/// Stream elements emitted by Stage 4 (Change Detection) — input to Stage 5.
sealed class SyncCandidateEvent {}

/// Stream elements emitted by Stage 5 (Local Content Load) — input to Stage 6.
sealed class LoadedCandidateEvent {}

/// Stream elements emitted by Stage 6 (Resource Fetch) — input to Stage 7a.
sealed class FetchedCandidateEvent {}

/// Stream elements emitted by Stage 7a (Decode) — input to Stage 7b.
sealed class DecodedCandidateEvent {}

/// Stream elements emitted by Stage 7b (Preload) — input to Stage 7c.
sealed class PreloadedCandidateEvent {}

/// Stream elements emitted by Stage 7c (CRDT Merge) — input to Stage 8.
sealed class MergedResourceEvent {}

/// Stream elements emitted by Stage 8 (Resource Upload) — input to Stage 9.
sealed class UploadedResourceEvent {}

/// Stream elements emitted by Stage 9 (DB Commit) — input to Stage 10.
sealed class CommittedResourceEvent {}

/// Stream elements emitted by Stage 10 (Shard Entry Load) — input to Stage 11a.
sealed class LoadedShardEntriesEvent {}

/// Stream elements emitted by Stage 11a (Prepare Shard) — input to Stage 11b.
sealed class PreparedShardEvent {}

/// Stream elements emitted by Stage 11b (Contract Load) — input to Stage 11c.
sealed class ContractLoadedShardEvent {}

/// Stream elements emitted by Stage 11c (Shard CRDT Merge) — input to Stage 12.
sealed class MergedShardEvent {}

/// Stream elements emitted by Stage 12 (Shard Upload) — input to Stage 13.
sealed class UploadedShardEvent {}

/// Stream elements emitted by Stage 13 (Shard DB Commit) — input to Stage 14.
/// Also the terminal output type of the pipeline (Stage 14 is a pass-through).
sealed class CommittedShardEvent {}
