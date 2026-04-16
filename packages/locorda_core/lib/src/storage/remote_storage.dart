import 'dart:async';

import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';
import 'package:locorda_rdf_core/core.dart';

/// Result of a remote download operation with ETag support.
///
/// [documentIri] and [requestETag] echo back the request identity so the
/// pipeline can match results to requests when backends return them
/// out-of-order (cross-shard batching).
class RemoteDownloadResult<T> {
  /// The IRI of the document this result belongs to.
  final IriTerm documentIri;

  /// The `ifNoneMatch` ETag from the originating request (if any).
  final String? requestETag;

  final T? graph;
  final String? etag;
  final bool notModified; // true if 304 Not Modified

  const RemoteDownloadResult({
    required this.documentIri,
    this.requestETag,
    required this.graph,
    required this.etag,
    this.notModified = false,
  });

  factory RemoteDownloadResult.notModified({
    required IriTerm documentIri,
    String? requestETag,
    required String etag,
  }) {
    return RemoteDownloadResult<T>(
      documentIri: documentIri,
      requestETag: requestETag,
      graph: null,
      etag: etag,
      notModified: true,
    );
  }

  RemoteDownloadResult<T> copyWith({
    IriTerm? documentIri,
    String? requestETag,
    T? graph,
    String? etag,
    bool? notModified,
  }) {
    return RemoteDownloadResult<T>(
      documentIri: documentIri ?? this.documentIri,
      requestETag: requestETag ?? this.requestETag,
      graph: graph ?? this.graph,
      etag: etag ?? this.etag,
      notModified: notModified ?? this.notModified,
    );
  }
}

/// Request descriptor for conditional remote downloads.
class RemoteDownloadRequest {
  final IriTerm documentIri;
  final String? ifNoneMatch;

  const RemoteDownloadRequest({
    required this.documentIri,
    this.ifNoneMatch,
  });
}

/// Result of a remote upload operation with ETag support.
///
/// [documentIri] and [requestETag] echo back the request identity so the
/// pipeline can match results to requests when backends return them
/// out-of-order (cross-shard batching).
sealed class RemoteUploadResult {
  /// The IRI of the document this result belongs to.
  IriTerm get documentIri;

  /// The `ifMatch` ETag from the originating request (if any).
  String? get requestETag;

  const RemoteUploadResult();

  factory RemoteUploadResult.conflict({
    required IriTerm documentIri,
    String? requestETag,
  }) {
    return ConflictUploadResult(
      documentIri: documentIri,
      requestETag: requestETag,
    );
  }
  factory RemoteUploadResult.success(
    String etag, {
    required IriTerm documentIri,
    String? requestETag,
  }) {
    return SuccessUploadResult(
      etag,
      documentIri: documentIri,
      requestETag: requestETag,
    );
  }
}

final class ConflictUploadResult extends RemoteUploadResult {
  @override
  final IriTerm documentIri;
  @override
  final String? requestETag;
  const ConflictUploadResult({
    required this.documentIri,
    this.requestETag,
  });
}

final class SuccessUploadResult extends RemoteUploadResult {
  @override
  final IriTerm documentIri;
  @override
  final String? requestETag;
  final String etag;
  const SuccessUploadResult(
    this.etag, {
    required this.documentIri,
    this.requestETag,
  });
}

/// Request descriptor for conditional remote uploads.
class RemoteUploadRequest<T> {
  final IriTerm documentIri;
  final T document;
  final String? ifMatch;

  const RemoteUploadRequest({
    required this.documentIri,
    required this.document,
    this.ifMatch,
  });
}

abstract class PipelineRemoteStorage {
  /// Remote endpoint identifier for this storage backend
  RemoteId get remoteId;

  /// Check if remote storage is available/authenticated.
  ///
  /// Called before sync to determine if sync should be attempted.
  /// Returns false if backend is offline, unauthenticated, or unavailable.
  Future<bool> isAvailable();

  /// Create a new sync storage session with cached configuration state.
  ///
  /// Called once at the start of each sync cycle. The returned [RemoteSyncStorage]
  /// can cache configuration-derived state for efficient document operations.
  ///
  /// **Backend-specific setup examples:**
  /// - **GDrive**: Load/update gdrive-index.ttl, cache folder ID mappings
  /// - **Solid**: Verify Pod access, prepare IRI translators
  /// - **InMemory**: No setup needed, return lightweight wrapper
  ///
  /// The [config] provides access to all registered resource types and their
  /// index configurations.
  ///
  /// Throws if backend cannot be initialized (e.g., auth failure, missing config).
  Future<PipelineRemoteSyncStorage> createPipelineSyncStorage(
      SyncEngineConfig config);

  Future<void> dispose() async {}
}

/// Exception thrown when remote storage operations fail due to authentication or authorization issues.
///
/// This exception signals that credentials are invalid, expired, or revoked,
/// and the application should attempt to refresh tokens or re-authenticate.
///
/// Used by backends (GDrive, Solid, etc.) to indicate 401 Unauthorized or
/// similar authentication failures.
class AuthException implements Exception {
  final String message;
  final Object? cause;

  AuthException(this.message, {this.cause});

  @override
  String toString() =>
      'AuthenticationException: $message${cause != null ? ' (cause: $cause)' : ''}';
}

/// Configuration for authentication-aware retry behavior.
class AuthRetryConfig {
  /// Maximum number of retry attempts after token refresh
  final int maxRetries;

  /// Whether to rethrow authentication exceptions after all retries failed
  final bool rethrowOnFailure;

  const AuthRetryConfig({
    this.maxRetries = 1,
    this.rethrowOnFailure = true,
  });

  const AuthRetryConfig.noRetry()
      : maxRetries = 0,
        rethrowOnFailure = true;

  const AuthRetryConfig.retryOnce()
      : maxRetries = 1,
        rethrowOnFailure = true;
}

Future<T> retryOnAuthFailure<T>(
    {required AuthRetryConfig config,
    required Future<void> Function() onAuthFailure,
    required Future<T> Function() operation}) async {
  int attempts = 0;
  while (true) {
    try {
      return await operation();
    } on AuthException catch (e) {
      if (attempts >= config.maxRetries) {
        if (config.rethrowOnFailure) {
          rethrow;
        } else {
          throw Exception(
              'Authentication failed after ${attempts} retries: $e');
        }
      }

      attempts++;
      await onAuthFailure();
      // Retry after token refresh
    }
  }
}

/// Decorates a [PipelineRemoteSyncStorage] with IRI translation between
/// Locorda-internal (`tag:locorda.org,2025:l:…`) and backend-specific IRIs.
///
/// **Translation invariant:** Every event carrying an [IriTerm] or an
/// [RdfGraph]/[RdfDataset] must be translated — not just the "primary" data
/// events, but also boundary events ([ShardComplete], [ResourceError],
/// [ShardError], [ConflictedShard]).
///
/// Why boundary events must be translated too:
/// - **Input side:** The delegate implementation receives events with IRIs and
///   may inspect them (e.g., for logging, error tracking, or accumulator
///   lookups keyed by IRI). If boundary IRIs remain internal while data IRIs
///   are external, the delegate sees an inconsistent IRI space.
/// - **Output side:** The delegate may *create* new boundary events (e.g., a
///   [ResourceError] from a failed resource fetch, or a [ConflictedShard] from
///   an ETag mismatch). Those IRIs will be in external form and must be
///   translated back to internal.
///
/// [PhaseComplete] is the sole exception — it carries pipeline-internal
/// [SyncInput] metadata (index IRIs, retry counts) that are never
/// backend-specific and therefore need no translation.
class PipelineIriTranslatingRemoteSyncStorage
    implements PipelineRemoteSyncStorage {
  final PipelineRemoteSyncStorage _remote;
  final RdfCore _rdfCore;
  final IriTranslator _iriTranslator;
  PipelineIriTranslatingRemoteSyncStorage({
    required PipelineRemoteSyncStorage remote,
    required IriTranslator iriTranslator,
    required RdfCore rdfCore,
  })  : _remote = remote,
        _rdfCore = rdfCore,
        _iriTranslator = iriTranslator;

  // ---------------------------------------------------------------------------
  // Stage transformers — wrap delegate with IRI translation on both sides.
  //
  // Every event carrying an IriTerm (or a graph/dataset containing IRIs) is
  // translated:
  //   Input:  internal → external  (so the delegate sees backend-native IRIs)
  //   Output: external → internal  (so the rest of the pipeline sees internal)
  //
  // PhaseComplete is the only exception — it carries pipeline metadata
  // (SyncInput) that is never backend-specific.
  // ---------------------------------------------------------------------------

  /// Translates decoded graph sources, leaving encoded sources as-is
  /// (FPR pipeline always produces [DecodedGraphSource]).
  RdfGraphSource _translateSource(
          RdfGraphSource source, RdfGraph Function(RdfGraph) translate) =>
      switch (source) {
        DecodedGraphSource(:final graph) => DecodedGraphSource(
            translate(graph),
            // graph was changed, so original source is no longer valid for caching
            originalSource: null,
          ),
        EncodedRdfGraphSource() => DecodedGraphSource(
            translate(source.decodeWith(_rdfCore).graph),
            // graph was changed, so original source is no longer valid for caching
            originalSource: null,
          ),
      };

  IriTerm _toExternal(IriTerm iri) => _iriTranslator.internalToExternal(iri);

  IriTerm _toInternal(IriTerm iri) => _iriTranslator.externalToInternal(iri);

  DecodedGraphSource _graphToExternal(DecodedGraphSource s) =>
      DecodedGraphSource(_iriTranslator.translateGraphToExternal(s.graph));

  DecodedGraphSource _graphToInternal(DecodedGraphSource s) =>
      DecodedGraphSource(_iriTranslator.translateGraphToInternal(s.graph));

  StreamTransformer<T, R> _wrap<T, R>(
    StreamTransformer<T, R> stageTransformer,
    T Function(T) translateInput,
    R Function(R) translateOutput, {
    PipeperfCollector? perf,
    String? perfStage,
  }) {
    T timedInput(T e) {
      if (perf == null) return translateInput(e);
      final sw = perf.start(perfStage!);
      try {
        return translateInput(e);
      } finally {
        sw.stop();
      }
    }

    R timedOutput(R e) {
      if (perf == null) return translateOutput(e);
      final sw = perf.start(perfStage!);
      try {
        return translateOutput(e);
      } finally {
        sw.stop();
      }
    }

    return StreamTransformer.fromBind((stream) => stageTransformer
        .bind(stream.map(timedInput)) // Translate input IRIs to external
        .map(timedOutput)); // Translate output IRIs/graphs
  }

  // --- Stage 2: Shard Fetch ---

  @override
  StreamTransformer<ShardRefEvent, FetchedShardEvent> shardFetch(
          {PipeperfCollector? perf}) =>
      _wrap(
        _remote.shardFetch(perf: perf),
        (e) => switch (e) {
          ShardRef() => e.copyWith(
              shardIri: _toExternal(e.shardIri),
              indexIri: _toExternal(e.indexIri),
              typeIri: _toExternal(e.typeIri),
            ),
          PhaseComplete() => e,
          PhaseError() => e,
        },
        (e) => switch (e) {
          ShardContent() => e.copyWith(
              shardIri: _toInternal(e.shardIri),
              typeIri: e.typeIri != null ? _toInternal(e.typeIri!) : null,
              source: _translateSource(
                  e.source, _iriTranslator.translateGraphToInternal),
            ),
          ShardNotModified() => e.copyWith(
              shardIri: _toInternal(e.shardIri),
              typeIri: _toInternal(e.typeIri),
            ),
          ShardNotFound() => e.copyWith(
              shardIri: _toInternal(e.shardIri),
              typeIri: _toInternal(e.typeIri),
            ),
          ShardGone() => e.copyWith(
              shardIri: _toInternal(e.shardIri),
              typeIri: _toInternal(e.typeIri),
            ),
          ShardError() => e.copyWith(shardIri: _toInternal(e.shardIri)),
          PhaseComplete() => e,
          PhaseError() => e,
        },
        perf: perf,
        perfStage: 'S02.IriXlat',
      );

  // --- Stage 6: Resource Fetch ---

  @override
  StreamTransformer<LoadedCandidateEvent, FetchedCandidateEvent> resourceFetch(
          {PipeperfCollector? perf}) =>
      _wrap(
        _remote.resourceFetch(perf: perf),
        (e) => switch (e) {
          LoadedCandidate() => e.copyWith(
                candidate: e.candidate.copyWith(
              resourceIri: _toExternal(e.candidate.resourceIri),
              typeIri: _toExternal(e.candidate.typeIri),
            )),
          ResourceError() =>
            e.copyWith(resourceIri: _toExternal(e.resourceIri)),
          ShardError() => e.copyWith(shardIri: _toExternal(e.shardIri)),
          ShardComplete() => e.copyWith(shardIri: _toExternal(e.shardIri)),
          ShardSkipped() => e.copyWith(shardIri: _toExternal(e.shardIri)),
          PhaseComplete() => e,
          PhaseError() => e,
        },
        (e) => switch (e) {
          FetchedCandidate() => e.copyWith(
              loaded: e.loaded.copyWith(
                  candidate: e.loaded.candidate.copyWith(
                resourceIri: _toInternal(e.loaded.candidate.resourceIri),
                typeIri: _toInternal(e.loaded.candidate.typeIri),
              )),
              remoteSource: e.remoteSource != null
                  ? _translateSource(
                      e.remoteSource!, _iriTranslator.translateGraphToInternal)
                  : null,
            ),
          ResourceError() =>
            e.copyWith(resourceIri: _toInternal(e.resourceIri)),
          ShardError() => e.copyWith(shardIri: _toInternal(e.shardIri)),
          ShardComplete() => e.copyWith(shardIri: _toInternal(e.shardIri)),
          ShardSkipped() => e.copyWith(shardIri: _toInternal(e.shardIri)),
          PhaseComplete() => e,
          PhaseError() => e,
        },
        perf: perf,
        perfStage: 'S06.IriXlat',
      );

  // --- Stage 8: Resource Upload ---

  @override
  StreamTransformer<MergedResourceEvent, UploadedResourceEvent> resourceUpload(
          {PipeperfCollector? perf}) =>
      _wrap(
        _remote.resourceUpload(perf: perf),
        (e) => switch (e) {
          MergeResult() => e.copyWith(
              resourceIri: _toExternal(e.resourceIri),
              typeIri: _toExternal(e.typeIri),
              mergedGraph: _graphToExternal(e.mergedGraph),
            ),
          ResourceError() =>
            e.copyWith(resourceIri: _toExternal(e.resourceIri)),
          ShardError() => e.copyWith(shardIri: _toExternal(e.shardIri)),
          ShardComplete() => e.copyWith(shardIri: _toExternal(e.shardIri)),
          ShardSkipped() => e.copyWith(shardIri: _toExternal(e.shardIri)),
          PhaseComplete() => e,
          PhaseError() => e,
        },
        (e) => switch (e) {
          UploadResult() => e.copyWith(
                mergeResult: e.mergeResult.copyWith(
              resourceIri: _toInternal(e.mergeResult.resourceIri),
              typeIri: _toInternal(e.mergeResult.typeIri),
              mergedGraph: _graphToInternal(e.mergeResult.mergedGraph),
            )),
          ConflictedResource() => e.copyWith(
              resourceIri: _toInternal(e.resourceIri),
              mergeResult: e.mergeResult.copyWith(
                resourceIri: _toInternal(e.mergeResult.resourceIri),
                typeIri: _toInternal(e.mergeResult.typeIri),
                mergedGraph: _graphToInternal(e.mergeResult.mergedGraph),
              ),
            ),
          ResourceError() =>
            e.copyWith(resourceIri: _toInternal(e.resourceIri)),
          ShardError() => e.copyWith(shardIri: _toInternal(e.shardIri)),
          ShardComplete() => e.copyWith(shardIri: _toInternal(e.shardIri)),
          ShardSkipped() => e.copyWith(shardIri: _toInternal(e.shardIri)),
          PhaseComplete() => e,
          PhaseError() => e,
        },
        perf: perf,
        perfStage: 'S08.IriXlat',
      );

  // --- Stage 12: Shard Upload ---

  @override
  StreamTransformer<MergedShardEvent, UploadedShardEvent> shardUpload(
          {PipeperfCollector? perf}) =>
      _wrap(
        _remote.shardUpload(perf: perf),
        (e) => switch (e) {
          MergedShard() => e.copyWith(
              shardIri: _toExternal(e.shardIri),
              mergedGraph: _graphToExternal(e.mergedGraph),
            ),
          ConflictedShard() => e.copyWith(shardIri: _toExternal(e.shardIri)),
          ShardError() => e.copyWith(shardIri: _toExternal(e.shardIri)),
          ShardSkipped() => e.copyWith(shardIri: _toExternal(e.shardIri)),
          PhaseComplete() => e,
          PhaseError() => e,
        },
        (e) => switch (e) {
          UploadedShard() => e.copyWith(
              shardIri: _toInternal(e.shardIri),
              mergedShard: e.mergedShard.copyWith(
                shardIri: _toInternal(e.mergedShard.shardIri),
                mergedGraph: _graphToInternal(e.mergedShard.mergedGraph),
              ),
            ),
          ConflictedShard() => e.copyWith(shardIri: _toInternal(e.shardIri)),
          ShardError() => e.copyWith(shardIri: _toInternal(e.shardIri)),
          ShardSkipped() => e.copyWith(shardIri: _toInternal(e.shardIri)),
          PhaseComplete() => e,
          PhaseError() => e,
        },
        perf: perf,
        perfStage: 'S12.IriXlat',
      );

  @override
  Future<void> finalizeSync(SyncFinalizationState state,
          {PipeperfCollector? perf}) =>
      _remote.finalizeSync(state, perf: perf);
}
