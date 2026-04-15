/// Optional extension of [RemoteSyncStorage] for the streaming sync pipeline.
///
/// Provides the four backend-owned stream transformers for Stages 2, 6, 8, 12.
/// Implementations may share internal state across transformers (e.g. a
/// per-shard resource cache populated in Stage 2, consumed in Stage 6).
library;

import 'dart:async';

import 'package:locorda_core/src/mapping/iri_translator.dart';
import 'package:locorda_core/src/storage/remote_id.dart';
import 'package:locorda_core/src/storage/storage_interface.dart';
import 'package:locorda_core/src/sync/pipeline/pipeperf.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';
import 'package:locorda_rdf_core/core.dart';

/// Bridge between pipeline backends and the local storage layer.
///
/// Provides resource graph loading for dataset assembly (Stage 12) and
/// remote ETag management for conditional HTTP requests (Stages 2, 12).
/// The [RemoteId] is bound internally so backends don't need to track it.
abstract interface class BackendStorageAccess {
  /// Load resource graphs from the local DB for dataset assembly.
  ///
  /// Returns decoded graphs keyed by document IRI; null values indicate
  /// missing documents.
  Future<Map<IriTerm, RdfGraph?>> loadResourceGraphs(
      Iterable<IriTerm> documentIris);

  /// Load stored remote ETags for the given document IRIs.
  ///
  /// Returns a map with null values for documents without a stored ETag.
  Future<Map<IriTerm, String?>> getRemoteETags(
      Iterable<IriTerm> documentIris);

  /// Persist remote ETags after successful download or upload.
  Future<void> setRemoteETags(Map<IriTerm, String> etagsByDocument);
}

/// Factory for creating [RemoteId]-bound [BackendStorageAccess] instances.
///
/// Backends receive this factory (instead of a pre-bound access object)
/// and call [forRemote] with their own [RemoteId] to obtain an instance
/// scoped to the correct remote.
abstract interface class BackendStorageAccessFactory {
  BackendStorageAccess forRemote(RemoteId remoteId);
}

/// Default [BackendStorageAccessFactory] backed by a [Storage] instance.
class BackendStorageAccessFactoryImpl implements BackendStorageAccessFactory {
  final Storage _storage;

  BackendStorageAccessFactoryImpl({required Storage storage})
      : _storage = storage;

  @override
  BackendStorageAccess forRemote(RemoteId remoteId) =>
      BackendStorageAccessImpl(storage: _storage, remoteId: remoteId);
}

class BackendStorageAccessImpl implements BackendStorageAccess {
  final Storage _storage;
  final RemoteId _remoteId;

  BackendStorageAccessImpl({
    required Storage storage,
    required RemoteId remoteId,
  })  : _storage = storage,
        _remoteId = remoteId;

  @override
  Future<Map<IriTerm, RdfGraph?>> loadResourceGraphs(
      Iterable<IriTerm> documentIris) async {
    final docs = await _storage.getDocumentsByIri(documentIris);
    return docs.map((iri, doc) => MapEntry(iri, doc?.document));
  }

  @override
  Future<Map<IriTerm, String?>> getRemoteETags(
          Iterable<IriTerm> documentIris) =>
      _storage.getRemoteETags(_remoteId, documentIris);

  @override
  Future<void> setRemoteETags(Map<IriTerm, String> etagsByDocument) =>
      _storage.setRemoteETags(_remoteId, etagsByDocument);
}

/// [BackendStorageAccess] adapter for IRI-translating backends.
///
/// Bridges between external IRI space (used by pipeline) and internal IRI
/// space (used by local storage) by:
/// 1. Translating incoming external IRIs → internal before DB queries.
/// 2. Translating internal IRIs in returned graphs → external for callers.
class IriTranslatingBackendStorageAccess implements BackendStorageAccess {
  final BackendStorageAccess _inner;
  final IriTranslator _iriTranslator;

  IriTranslatingBackendStorageAccess({
    required BackendStorageAccess inner,
    required IriTranslator iriTranslator,
  })  : _inner = inner,
        _iriTranslator = iriTranslator;

  @override
  Future<Map<IriTerm, RdfGraph?>> loadResourceGraphs(
      Iterable<IriTerm> externalDocumentIris) async {
    final internalIris =
        externalDocumentIris.map(_iriTranslator.externalToInternal).toList();

    final internalResults = await _inner.loadResourceGraphs(internalIris);

    final externalResults = <IriTerm, RdfGraph?>{};
    for (var i = 0; i < internalIris.length; i++) {
      final externalIri = externalDocumentIris.elementAt(i);
      final graph = internalResults[internalIris[i]];
      externalResults[externalIri] =
          graph != null ? _iriTranslator.translateGraphToExternal(graph) : null;
    }
    return externalResults;
  }

  @override
  Future<Map<IriTerm, String?>> getRemoteETags(
      Iterable<IriTerm> externalDocumentIris) {
    final internalIris =
        externalDocumentIris.map(_iriTranslator.externalToInternal).toList();
    return _inner.getRemoteETags(internalIris).then((result) {
      final externalResults = <IriTerm, String?>{};
      for (var i = 0; i < internalIris.length; i++) {
        externalResults[externalDocumentIris.elementAt(i)] =
            result[internalIris[i]];
      }
      return externalResults;
    });
  }

  @override
  Future<void> setRemoteETags(Map<IriTerm, String> etagsByDocument) {
    final internalEtags = etagsByDocument.map((externalIri, etag) =>
        MapEntry(_iriTranslator.externalToInternal(externalIri), etag));
    return _inner.setRemoteETags(internalEtags);
  }
}

/// Base class for [RemoteSyncStorage] implementations that support
/// the streaming sync pipeline.
///
/// Backends implement this alongside [RemoteSyncStorage]. The pipeline
/// orchestrator checks for this interface at runtime to select the streaming
/// pipeline over the legacy orchestrator.
///
/// ## Stream element types
///
/// Each transformer receives a stream where data events are the documented
/// input type and [Boundary] events ([ShardComplete], [PhaseComplete]) flow
/// inline. Backend stages must:
/// - Pass [Boundary] events through unchanged (after flushing any in-flight
///   operations when receiving boundaries).
/// - Process only events of the documented input type.
abstract interface class PipelineRemoteSyncStorage {
  /// Stage 2: Shard Fetch — conditionally download shard documents.
  ///
  /// Input: [ShardRefEvent] ([ShardRef] data + [PhaseComplete] boundary).
  /// Output: [FetchedShardEvent] ([FetchedShard] variants + [PhaseComplete] boundary).
  ///
  /// Must buffer boundary events until all in-flight fetches complete, then forward.
  StreamTransformer<ShardRefEvent, FetchedShardEvent> shardFetch(
      {PipeperfCollector? perf});

  /// Stage 6: Resource Fetch — download resource graphs.
  ///
  /// Input: [LoadedCandidateEvent] ([LoadedCandidate] data + [PhaseComplete]/[ShardComplete] boundaries).
  /// Output: [FetchedCandidateEvent] ([FetchedCandidate] data + [PhaseComplete]/[ShardComplete] boundaries).
  ///
  /// `remoteOnly` / `conflictCandidate` → fetch from remote (using [LoadedCandidate.storedRemoteEtag] for conditional GET).
  /// `localOnly` / `remoteRemoved` → pass through as [FetchedCandidate] without fetch.
  StreamTransformer<LoadedCandidateEvent, FetchedCandidateEvent> resourceFetch(
      {PipeperfCollector? perf});

  /// Stage 8: Resource Upload — upload merged resources.
  ///
  /// Input: [MergedResourceEvent] ([MergeResult] data + [PhaseComplete]/[ShardComplete] boundaries).
  /// Output: [UploadedResourceEvent] ([UploadResult] data + [PhaseComplete]/[ShardComplete] boundaries).
  ///
  /// `needsUpload == true` → encode and upload to remote.
  /// Otherwise → pass through as [UploadResult].
  StreamTransformer<MergedResourceEvent, UploadedResourceEvent> resourceUpload(
      {PipeperfCollector? perf});

  /// Stage 12: Shard Upload — upload merged shard documents.
  ///
  /// Input: [MergedShardEvent] ([MergedShard] data + [PhaseComplete] boundary).
  /// Output: [UploadedShardEvent] ([UploadedShard] data + [PhaseComplete] boundary).
  StreamTransformer<MergedShardEvent, UploadedShardEvent> shardUpload(
      {PipeperfCollector? perf});

  /// Called after all pipeline phases complete (or on error).
  ///
  /// Backends that defer work (e.g. single-file upload) should commit on
  /// [SyncFinalizationSuccess] and clean up without uploading on
  /// [SyncFinalizationFailure].
  Future<void> finalizeSync(SyncFinalizationState state,
      {PipeperfCollector? perf});
}
