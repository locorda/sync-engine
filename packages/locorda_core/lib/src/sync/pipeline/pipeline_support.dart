/// Optional extension of [RemoteSyncStorage] for the streaming sync pipeline.
///
/// Provides the four backend-owned stream transformers for Stages 2, 6, 8, 12.
/// Implementations may share internal state across transformers (e.g. a
/// per-shard resource cache populated in Stage 2, consumed in Stage 6).
library;

import 'dart:async';

import 'package:locorda_core/src/mapping/iri_translator.dart';
import 'package:locorda_core/src/storage/storage_interface.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';
import 'package:locorda_rdf_core/core.dart';

/// Loads resource graphs from the local DB for dataset assembly.
///
/// Provided by Core (via the worker context) so that shard-dataset backends
/// can query locally-stored resource documents during Stage 12 upload.
/// Returns decoded graphs keyed by document IRI; null values indicate
/// missing documents.
abstract interface class ResourceGraphLoader {
  Future<Map<IriTerm, RdfGraph?>> load(Iterable<IriTerm> documentIris);
}

class ResourceGraphLoaderImpl implements ResourceGraphLoader {
  final Storage _storage;

  ResourceGraphLoaderImpl({required Storage storage}) : _storage = storage;

  Future<Map<IriTerm, RdfGraph?>> load(Iterable<IriTerm> documentIris) async {
    final docs = await _storage.getDocumentsByIri(documentIris);
    return docs.map((iri, doc) => MapEntry(iri, doc?.document));
  }
}

/// [ResourceGraphLoader] adapter for IRI-translating backends.
///
/// When [ShardDatasetRemoteSyncSupport] is wrapped inside
/// [PipelineIriTranslatingRemoteSyncStorage], it receives external IRIs from
/// the pipeline. This loader bridges back to internal storage by:
/// 1. Translating incoming external IRIs → internal before the DB query.
/// 2. Translating internal IRIs in the returned graphs → external so that the
///    caller (which works in external IRI space) can use them as named-graph keys.
class IriTranslatingResourceGraphLoader implements ResourceGraphLoader {
  final ResourceGraphLoader _inner;
  final IriTranslator _iriTranslator;

  IriTranslatingResourceGraphLoader({
    required ResourceGraphLoader inner,
    required IriTranslator iriTranslator,
  })  : _inner = inner,
        _iriTranslator = iriTranslator;

  @override
  Future<Map<IriTerm, RdfGraph?>> load(
      Iterable<IriTerm> externalDocumentIris) async {
    // Translate external → internal for the storage query.
    final internalIris =
        externalDocumentIris.map(_iriTranslator.externalToInternal).toList();

    final internalResults = await _inner.load(internalIris);

    // Re-key by external IRI and translate graph contents back to external.
    final externalResults = <IriTerm, RdfGraph?>{};
    for (var i = 0; i < internalIris.length; i++) {
      final externalIri = externalDocumentIris.elementAt(i);
      final graph = internalResults[internalIris[i]];
      externalResults[externalIri] =
          graph != null ? _iriTranslator.translateGraphToExternal(graph) : null;
    }
    return externalResults;
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
  StreamTransformer<ShardRefEvent, FetchedShardEvent> shardFetch();

  /// Stage 6: Resource Fetch — download resource graphs.
  ///
  /// Input: [LoadedCandidateEvent] ([LoadedCandidate] data + [PhaseComplete]/[ShardComplete] boundaries).
  /// Output: [FetchedCandidateEvent] ([FetchedCandidate] data + [PhaseComplete]/[ShardComplete] boundaries).
  ///
  /// `remoteOnly` / `conflictCandidate` → fetch from remote (using [LoadedCandidate.storedRemoteEtag] for conditional GET).
  /// `localOnly` / `remoteRemoved` → pass through as [FetchedCandidate] without fetch.
  StreamTransformer<LoadedCandidateEvent, FetchedCandidateEvent>
      resourceFetch();

  /// Stage 8: Resource Upload — upload merged resources.
  ///
  /// Input: [MergedResourceEvent] ([MergeResult] data + [PhaseComplete]/[ShardComplete] boundaries).
  /// Output: [UploadedResourceEvent] ([UploadResult] data + [PhaseComplete]/[ShardComplete] boundaries).
  ///
  /// `needsUpload == true` → encode and upload to remote.
  /// Otherwise → pass through as [UploadResult].
  StreamTransformer<MergedResourceEvent, UploadedResourceEvent>
      resourceUpload();

  /// Stage 12: Shard Upload — upload merged shard documents.
  ///
  /// Input: [MergedShardEvent] ([MergedShard] data + [PhaseComplete] boundary).
  /// Output: [UploadedShardEvent] ([UploadedShard] data + [PhaseComplete] boundary).
  StreamTransformer<MergedShardEvent, UploadedShardEvent> shardUpload();

  Future<void> finalizeSync();
}
