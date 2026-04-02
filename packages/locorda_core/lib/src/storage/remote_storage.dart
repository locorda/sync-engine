import 'dart:async';

import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';
import 'package:locorda_core/src/sync/pipeline/pipeperf.dart';
import 'package:locorda_rdf_core/core.dart';

/// Result of a remote download operation with ETag support.
class RemoteDownloadResult<T> {
  final T? graph;
  final String? etag;
  final bool notModified; // true if 304 Not Modified

  const RemoteDownloadResult({
    required this.graph,
    required this.etag,
    this.notModified = false,
  });

  factory RemoteDownloadResult.notModified({required String etag}) {
    return RemoteDownloadResult<T>(
      graph: null,
      etag: etag,
      notModified: true,
    );
  }

  RemoteDownloadResult<T> copyWith({
    T? graph,
    String? etag,
    bool? notModified,
  }) {
    return RemoteDownloadResult<T>(
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
sealed class RemoteUploadResult {
  const RemoteUploadResult();

  factory RemoteUploadResult.conflict() {
    return const ConflictUploadResult();
  }
  factory RemoteUploadResult.success(String etag) {
    return SuccessUploadResult(etag);
  }
}

final class ConflictUploadResult extends RemoteUploadResult {
  const ConflictUploadResult();
}

final class SuccessUploadResult extends RemoteUploadResult {
  final String etag;
  const SuccessUploadResult(this.etag);
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

/// Session-specific sync storage with cached state.
///
/// Created per sync session by [RemoteStorage.createSyncStorage].
/// Holds configuration-derived state (e.g., type mappings, folder IDs) for
/// efficient document operations during sync.
///
/// **Lifecycle:**
/// 1. Created before sync via [RemoteStorage.createSyncStorage]
/// 2. Used for all [upload]/[download] operations during sync
/// 3. [finalizeSync] called after sync completion (success or failure)
/// 4. Discarded after sync
///
/// **Important IRI Semantics:**
/// All operations work with **Locorda internal resource IRIs** using the
/// `tag:locorda.org,2025:l:` URI scheme. These are framework-standardized
/// identifiers used throughout Locorda for resource identification, hash
/// calculations, and CRDT operations.
///
/// Backend implementations may or may not transform these internal IRIs to
/// backend-specific locations (e.g., Solid backends transform to Pod-specific URLs)
/// internally. When transformation occurs, the RdfGraph content uses the same
/// internal IRIs and must also be transformed accordingly.
///
/// **Transformation Contract (when applicable):**
/// - **Upload**: Transform internal tag IRIs → backend-specific IRIs before sending
/// - **Download**: Transform backend-specific IRIs → internal tag IRIs before returning
/// - **Round-trip guarantee**: Data flowing in/out ALWAYS uses internal tag IRIs
///
/// **HTTP Semantics:**
/// Implementations should support:
/// - Conditional GET (If-None-Match header for ETags)
/// - Conditional PUT (If-Match header for ETags)
/// - HTTP status codes: 200, 304 Not Modified, 412 Precondition Failed
@Deprecated('non-pipeline')
abstract class RemoteSyncStorage extends GraphSyncStorage {
  Future<RemoteUploadResult> uploadDataset(
          IriTerm documentIri, RdfDataset dataset,
          {String? ifMatch}) =>
      throw UnimplementedError();

  Future<RemoteDownloadResult<RdfDataset>> downloadDataset(IriTerm documentIri,
          {String? ifNoneMatch}) =>
      throw UnimplementedError();

  /// Download multiple datasets from remote storage.
  ///
  /// Default implementation maps each request to [downloadDataset].
  /// Backends may override this for transport-level batching.
  Future<List<RemoteDownloadResult<RdfDataset>>> downloadManyDatasets(
      Iterable<RemoteDownloadRequest> requests) async {
    final results = <RemoteDownloadResult<RdfDataset>>[];
    for (final request in requests) {
      results.add(await downloadDataset(
        request.documentIri,
        ifNoneMatch: request.ifNoneMatch,
      ));
    }
    return results;
  }

  /// Upload multiple datasets to remote storage.
  ///
  /// Default implementation maps each request to [uploadDataset].
  /// Backends may override this for transport-level batching.
  Future<List<RemoteUploadResult>> uploadManyDatasets(
      Iterable<RemoteUploadRequest<RdfDataset>> requests) async {
    final results = <RemoteUploadResult>[];
    for (final request in requests) {
      results.add(await uploadDataset(
        request.documentIri,
        request.document,
        ifMatch: request.ifMatch,
      ));
    }
    return results;
  }

  /// Finalize sync operations and perform cleanup.
  ///
  /// Called after sync completion (success or failure). Implementations can:
  /// - Flush pending operations
  /// - Update metadata or statistics
  /// - Release resources
  ///
  /// This is optional - default implementation does nothing.
  Future<void> finalizeSync() async {}

  // FIXME: concurrent synchronization currently leads to concurrency issues in tests (for example save_36)
  int get maxConcurrentDocumentSyncs => 1; //10;

  // FIXME: concurrent synchronization currently leads to concurrency issues in tests (for example save_36)
  int get maxConcurrentShardSyncs => 1; //5;

  // FIXME: concurrent synchronization currently leads to concurrency issues in tests (for example save_36)
  int get maxConcurrentIndexSyncs => 1; //3;
}

abstract class GraphSyncStorage {
  /// Upload a document to remote storage.
  ///
  /// The implementation may transform the internal document IRI and RDF graph
  /// to backend-specific format before uploading.
  ///
  /// **Conditional Upload Semantics:**
  /// - `ifMatch: null` → Use "If-None-Match: *" (create only, fail if exists)
  /// - `ifMatch: "<etag>"` → Use "If-Match: <etag>" (update only, fail if changed)
  ///
  /// Parameters:
  /// - [documentIri]: Internal Locorda document IRI (tag:locorda.org,2025:l:...)
  /// - [graph]: RDF graph using internal IRIs
  /// - [ifMatch]: ETag for conditional upload, or null for create-only semantics
  ///
  /// Returns upload result with new ETag, or conflict=true on 409/412.
  Future<RemoteUploadResult> upload(IriTerm documentIri, RdfGraph graph,
      {String? ifMatch});

  /// Download a document from remote storage.
  ///
  /// The implementation may transform backend-specific IRIs back to internal
  /// Locorda document IRIs before returning the graph.
  ///
  /// Parameters:
  /// - [documentIri]: Internal Locorda document IRI (tag:locorda.org,2025:l:...)
  /// - [ifNoneMatch]: Optional ETag for conditional download (304 if unchanged)
  ///
  /// Returns download result with graph using internal IRIs, plus ETag.
  Future<RemoteDownloadResult<RdfGraph>> download(IriTerm documentIri,
      {String? ifNoneMatch});

  /// Download multiple documents from remote storage.
  ///
  /// Default implementation maps each request to [download].
  /// Backends may override this for transport-level batching.
  Future<List<RemoteDownloadResult<RdfGraph>>> downloadMany(
      Iterable<RemoteDownloadRequest> requests) async {
    final results = <RemoteDownloadResult<RdfGraph>>[];
    for (final request in requests) {
      results.add(await download(
        request.documentIri,
        ifNoneMatch: request.ifNoneMatch,
      ));
    }
    return results;
  }

  /// Upload multiple documents to remote storage.
  ///
  /// Default implementation maps each request to [upload].
  /// Backends may override this for transport-level batching.
  Future<List<RemoteUploadResult>> uploadMany(
      Iterable<RemoteUploadRequest<RdfGraph>> requests) async {
    final results = <RemoteUploadResult>[];
    for (final request in requests) {
      results.add(await upload(
        request.documentIri,
        request.document,
        ifMatch: request.ifMatch,
      ));
    }
    return results;
  }
}

/// Abstract interface for remote storage backend setup.
///
/// **Lifecycle:**
/// 1. [isAvailable] - Check if backend is accessible/authenticated
/// 2. [createSyncStorage] - Create session-specific storage before each sync
///
/// **Purpose:**
/// This interface handles backend initialization and creates stateful
/// [RemoteSyncStorage] instances that cache configuration-derived state
/// (e.g., type index mappings, folder IDs) for efficient sync operations.
@Deprecated('non-pipeline')
abstract interface class RemoteStorage {
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
  Future<RemoteSyncStorage> createSyncStorage(SyncEngineConfig config);

  /// Whether this remote storage uses shard datasets (all resources in one file per shard).
  ///
  /// **Important Implications:**
  /// - When true: All RootResourceFetchPolicy must be Prefetch() (lazy loading impossible)
  /// - When true: All index entries must have corresponding documents in storage
  /// - Backend switch: Can only switch to dataset mode if storage is complete
  ///
  /// This is a global flag (not per-type) to simplify the experimental phase.
  bool get useShardDatasets => false;

  Future<void> dispose() async {}
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

  /// Whether this remote storage uses shard datasets (all resources in one file per shard).
  ///
  /// **Important Implications:**
  /// - When true: All RootResourceFetchPolicy must be Prefetch() (lazy loading impossible)
  /// - When true: All index entries must have corresponding documents in storage
  /// - Backend switch: Can only switch to dataset mode if storage is complete
  ///
  /// This is a global flag (not per-type) to simplify the experimental phase.
  bool get useShardDatasets => false;

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

/// Wraps a [RemoteStorage] to automatically handle authentication failures.
///
/// Intercepts [AuthException]s thrown by the underlying storage,
/// triggers token refresh via [onAuthFailure], and retries the operation.
///
/// **Usage:**
/// ```dart
/// final authAwareRemote = AuthAwareRemoteStorage(
///   inner: gdriveRemote,
///   onAuthFailure: () async {
///     await authProvider.refreshToken();
///   },
///   config: AuthRetryConfig.retryOnce(),
/// );
/// ```
class AuthAwareRemoteStorage implements RemoteStorage {
  final RemoteStorage _inner;
  final Future<void> Function() _onAuthFailure;
  final AuthRetryConfig _config;

  AuthAwareRemoteStorage({
    required RemoteStorage inner,
    required Future<void> Function() onAuthFailure,
    AuthRetryConfig config = const AuthRetryConfig.retryOnce(),
  })  : _inner = inner,
        _onAuthFailure = onAuthFailure,
        _config = config;

  @override
  RemoteId get remoteId => _inner.remoteId;

  @override
  Future<bool> isAvailable() => _retryOnAuthFailure(
      config: _config,
      onAuthFailure: _onAuthFailure,
      operation: _inner.isAvailable);

  @override
  Future<RemoteSyncStorage> createSyncStorage(SyncEngineConfig config) async {
    final syncStorage = await _retryOnAuthFailure(
      config: _config,
      onAuthFailure: _onAuthFailure,
      operation: () => _inner.createSyncStorage(config),
    );
    return AuthAwareSyncStorage(
      inner: syncStorage,
      onAuthFailure: _onAuthFailure,
      config: _config,
    );
  }

  @override
  bool get useShardDatasets => _inner.useShardDatasets;

  @override
  Future<void> dispose() => _inner.dispose();

  @override
  String toString() => 'AuthAware(${_inner.toString()})';
}

/// Wraps a [RemoteSyncStorage] to automatically handle authentication failures.
///
/// Used internally by [AuthAwareRemoteStorage] to wrap the sync storage session.
class AuthAwareSyncStorage implements RemoteSyncStorage {
  final RemoteSyncStorage _inner;
  final Future<void> Function() _onAuthFailure;
  final AuthRetryConfig _config;

  AuthAwareSyncStorage({
    required RemoteSyncStorage inner,
    required Future<void> Function() onAuthFailure,
    required AuthRetryConfig config,
  })  : _inner = inner,
        _onAuthFailure = onAuthFailure,
        _config = config;

  @override
  Future<RemoteUploadResult> upload(
    IriTerm documentIri,
    RdfGraph graph, {
    String? ifMatch,
  }) =>
      _retryOnAuthFailure(
          config: _config,
          onAuthFailure: _onAuthFailure,
          operation: () => _inner.upload(documentIri, graph, ifMatch: ifMatch));

  @override
  Future<RemoteDownloadResult<RdfGraph>> download(
    IriTerm documentIri, {
    String? ifNoneMatch,
  }) =>
      _retryOnAuthFailure(
          config: _config,
          onAuthFailure: _onAuthFailure,
          operation: () =>
              _inner.download(documentIri, ifNoneMatch: ifNoneMatch));

  @override
  Future<List<RemoteDownloadResult<RdfGraph>>> downloadMany(
          Iterable<RemoteDownloadRequest> requests) =>
      _retryOnAuthFailure(
          config: _config,
          onAuthFailure: _onAuthFailure,
          operation: () => _inner.downloadMany(requests));

  @override
  Future<RemoteUploadResult> uploadDataset(
    IriTerm documentIri,
    RdfDataset dataset, {
    String? ifMatch,
  }) =>
      _retryOnAuthFailure(
          config: _config,
          onAuthFailure: _onAuthFailure,
          operation: () =>
              _inner.uploadDataset(documentIri, dataset, ifMatch: ifMatch));

  @override
  Future<RemoteDownloadResult<RdfDataset>> downloadDataset(
    IriTerm documentIri, {
    String? ifNoneMatch,
  }) =>
      _retryOnAuthFailure(
          config: _config,
          onAuthFailure: _onAuthFailure,
          operation: () =>
              _inner.downloadDataset(documentIri, ifNoneMatch: ifNoneMatch));

  @override
  Future<List<RemoteUploadResult>> uploadMany(
          Iterable<RemoteUploadRequest<RdfGraph>> requests) =>
      _retryOnAuthFailure(
          config: _config,
          onAuthFailure: _onAuthFailure,
          operation: () => _inner.uploadMany(requests));

  @override
  Future<List<RemoteDownloadResult<RdfDataset>>> downloadManyDatasets(
          Iterable<RemoteDownloadRequest> requests) =>
      _retryOnAuthFailure(
          config: _config,
          onAuthFailure: _onAuthFailure,
          operation: () => _inner.downloadManyDatasets(requests));

  @override
  Future<List<RemoteUploadResult>> uploadManyDatasets(
          Iterable<RemoteUploadRequest<RdfDataset>> requests) =>
      _retryOnAuthFailure(
          config: _config,
          onAuthFailure: _onAuthFailure,
          operation: () => _inner.uploadManyDatasets(requests));

  @override
  Future<void> finalizeSync() => _inner.finalizeSync();

  @override
  int get maxConcurrentDocumentSyncs => _inner.maxConcurrentDocumentSyncs;

  @override
  int get maxConcurrentShardSyncs => _inner.maxConcurrentShardSyncs;

  @override
  int get maxConcurrentIndexSyncs => _inner.maxConcurrentIndexSyncs;

  @override
  String toString() => 'AuthAware(${_inner.toString()})';
}

Future<T> _retryOnAuthFailure<T>(
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

@Deprecated('non-pipeline')
class IriTranslatingRemoteSyncStorage extends RemoteSyncStorage {
  final RemoteSyncStorage _storage;
  final IriTranslator _iriTranslator;

  IriTranslatingRemoteSyncStorage({
    required RemoteSyncStorage storage,
    required IriTranslator iriTranslator,
  })  : _storage = storage,
        _iriTranslator = iriTranslator;

  @override
  Future<RemoteDownloadResult<RdfGraph>> download(IriTerm documentIri,
      {String? ifNoneMatch}) async {
    final result = await _storage.download(
      _iriTranslator.internalToExternal(documentIri),
      ifNoneMatch: ifNoneMatch,
    );
    return result.copyWith(
      graph: result.graph != null
          ? _iriTranslator.translateGraphToInternal(result.graph!)
          : null,
    );
  }

  @override
  Future<RemoteDownloadResult<RdfDataset>> downloadDataset(IriTerm documentIri,
      {String? ifNoneMatch}) async {
    final result = await _storage.downloadDataset(
      _iriTranslator.internalToExternal(documentIri),
      ifNoneMatch: ifNoneMatch,
    );
    return result.copyWith(
      graph: result.graph != null
          ? _iriTranslator.translateDatasetToInternal(result.graph!)
          : null,
    );
  }

  @override
  Future<RemoteUploadResult> upload(IriTerm documentIri, RdfGraph graph,
          {String? ifMatch}) =>
      _storage.upload(
        _iriTranslator.internalToExternal(documentIri),
        _iriTranslator.translateGraphToExternal(graph),
        ifMatch: ifMatch,
      );

  @override
  Future<RemoteUploadResult> uploadDataset(
          IriTerm documentIri, RdfDataset dataset,
          {String? ifMatch}) =>
      _storage.uploadDataset(
        _iriTranslator.internalToExternal(documentIri),
        _iriTranslator.translateDatasetToExternal(dataset),
        ifMatch: ifMatch,
      );

  @override
  Future<void> finalizeSync() async {
    await _storage.finalizeSync();
  }
}

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
  // RemoteSyncPipelineSupport — wraps _pipelineSupport with IRI translation.
  //
  // Input events: translate locorda-internal IRIs → external (backend) IRIs
  // Output events: translate external IRIs/graphs → locorda-internal IRIs
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
      final sw = Stopwatch()..start();
      try {
        return translateInput(e);
      } finally {
        perf.record(perfStage!, sw.elapsedMicroseconds);
      }
    }

    R timedOutput(R e) {
      if (perf == null) return translateOutput(e);
      final sw = Stopwatch()..start();
      try {
        return translateOutput(e);
      } finally {
        perf.record(perfStage!, sw.elapsedMicroseconds);
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
          ShardRef() => e.copyWith(shardIri: _toExternal(e.shardIri)),
          PhaseComplete() => e,
        },
        (e) => switch (e) {
          ShardContent() => e.copyWith(
              shardIri: _toInternal(e.shardIri),
              source: _translateSource(
                  e.source, _iriTranslator.translateGraphToInternal),
            ),
          ShardNotModified() => e.copyWith(shardIri: _toInternal(e.shardIri)),
          ShardGone() => e.copyWith(shardIri: _toInternal(e.shardIri)),
          PhaseComplete() => e,
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
              candidate: e.candidate
                  .copyWith(resourceIri: _toExternal(e.candidate.resourceIri))),
          ShardComplete() => e,
          PhaseComplete() => e,
        },
        (e) => switch (e) {
          FetchedCandidate() => e.copyWith(
              loaded: e.loaded.copyWith(
                  candidate: e.loaded.candidate.copyWith(
                      resourceIri:
                          _toInternal(e.loaded.candidate.resourceIri))),
              remoteSource: e.remoteSource != null
                  ? _translateSource(
                      e.remoteSource!, _iriTranslator.translateGraphToInternal)
                  : null,
            ),
          ShardComplete() => e,
          PhaseComplete() => e,
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
              mergedGraph: _graphToExternal(e.mergedGraph),
            ),
          ShardComplete() => e,
          PhaseComplete() => e,
        },
        (e) => switch (e) {
          UploadResult() => e.copyWith(
                mergeResult: e.mergeResult.copyWith(
              resourceIri: _toInternal(e.mergeResult.resourceIri),
              mergedGraph: _graphToInternal(e.mergeResult.mergedGraph),
            )),
          ShardComplete() => e,
          PhaseComplete() => e,
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
          PhaseComplete() => e,
        },
        (e) => switch (e) {
          UploadedShard() => e.copyWith(
              shardIri: _toInternal(e.shardIri),
              mergedShard: e.mergedShard.copyWith(
                shardIri: _toInternal(e.mergedShard.shardIri),
                mergedGraph: _graphToInternal(e.mergedShard.mergedGraph),
              ),
            ),
          PhaseComplete() => e,
        },
        perf: perf,
        perfStage: 'S12.IriXlat',
      );

  @override
  Future<void> finalizeSync() => _remote.finalizeSync();
}
