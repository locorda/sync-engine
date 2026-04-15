import 'dart:async';

import 'package:locorda_core/src/storage/remote_storage.dart';
import 'package:locorda_core/src/sync/pipeline/backend/backend_converter.dart';
import 'package:locorda_core/src/sync/pipeline/backend/backend_pipe.dart';
import 'package:locorda_core/src/sync/pipeline/backend/remote_sync_backend.dart';
import 'package:locorda_core/src/sync/pipeline/pipeperf.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_support.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:logging/logging.dart';

/// [PipelineRemoteSyncStorage] for file-per-resource backends.
///
/// Each resource and shard lives in its own file. The four pipeline stages
/// pipe events through [RemoteSyncBackend.download] / [.upload] streams,
/// handling RDF encoding/decoding (CPU) in the adapter while the backend
/// handles only I/O.
///
/// Uses deque-based cross-shard batching: backend requests for multiple
/// shards can be in-flight simultaneously, and results are matched by
/// composite key (IRI + request ETag) rather than positional order.
/// Boundary events maintain coarse ordering between segments while
/// individual results within a segment flow as soon as they arrive.
class FilePerResourceRemoteSyncStorage implements PipelineRemoteSyncStorage {
  final _logger = Logger('FilePerResourceRemoteSyncStorage');
  final RemoteSyncBackend backend;
  final BackendGraphConverter _converter;

  FilePerResourceRemoteSyncStorage(this.backend,
      {required RdfCore rdfCore, required String contentType})
      : _converter = BackendGraphConverter(
          rdfCore: rdfCore,
          isBinary: rdfCore.contentTypeInfo(contentType)?.isBinary ?? false,
          contentType: contentType,
        );

  @override
  Future<void> finalizeSync(SyncFinalizationState state,
          {PipeperfCollector? perf}) =>
      Future.value();

  // ---------------------------------------------------------------------------
  // Stage 2: Shard Fetch
  // ---------------------------------------------------------------------------

  @override
  StreamTransformer<ShardRefEvent, FetchedShardEvent> shardFetch(
          {PipeperfCollector? perf}) =>
      StreamTransformer.fromBind((stream) => backendPipe<
              ShardRef,
              ShardRefEvent,
              FetchedShardEvent,
              RemoteDownloadRequest,
              RemoteDownloadResult<RawContent>>(
            stream: stream,
            logger: _logger,
            perf: perf,
            perfStage: 'S02.ShardFetch.FPR',
            classify: (e) => switch (e) {
              // --- Shard Events ---
              ShardRef() => BackendRequest(
                  (e.shardIri.getDocumentIri(), e.storedEtag),
                  e,
                  RemoteDownloadRequest(
                    documentIri: e.shardIri.getDocumentIri(),
                    ifNoneMatch: e.storedEtag,
                  ),
                ),

              // --- Phase Events ---
              PhaseComplete() => BackendBoundary(e),
              PhaseError() => BackendBoundary(e),
            },
            backendCall: backend.download,
            resultKey: (r) => (r.documentIri, r.requestETag),
            toOutput: (event, result) {
              if (result.notModified) {
                return ShardNotModified(event.shardIri, event.shardStorageId,
                    event.fetchPolicy, event.typeIri,
                    storedEtag: event.storedEtag);
              } else if (result.graph == null && event.storedEtag != null) {
                return ShardGone(event.shardIri, event.shardStorageId,
                    event.fetchPolicy, event.typeIri);
              } else if (result.graph == null) {
                return ShardNotFound(event.shardIri, event.shardStorageId,
                    event.fetchPolicy, event.typeIri);
              } else {
                return ShardContent(
                  event.shardIri,
                  event.shardStorageId,
                  event.fetchPolicy,
                  event.typeIri,
                  _converter.toGraphSource(result.graph!),
                  result.etag!,
                );
              }
            },
            onError: (event, error, stackTrace) =>
                ShardError(event.shardIri, error, stackTrace),
          ));

  // ---------------------------------------------------------------------------
  // Stage 6: Resource Fetch
  // ---------------------------------------------------------------------------

  @override
  StreamTransformer<LoadedCandidateEvent, FetchedCandidateEvent> resourceFetch(
          {PipeperfCollector? perf}) =>
      StreamTransformer.fromBind((stream) => backendPipe<
              LoadedCandidate,
              LoadedCandidateEvent,
              FetchedCandidateEvent,
              RemoteDownloadRequest,
              RemoteDownloadResult<RawContent>>(
            stream: stream,
            logger: _logger,
            perf: perf,
            perfStage: 'S06.ResourceFetch.FPR',
            classify: (e) => switch (e) {
              // --- Resource Events ---
              LoadedCandidate() when e.needsRemoteFetch => BackendRequest(
                  (
                    e.candidate.resourceIri.getDocumentIri(),
                    e.storedRemoteEtag
                  ),
                  e,
                  RemoteDownloadRequest(
                    documentIri: e.candidate.resourceIri.getDocumentIri(),
                    ifNoneMatch: e.storedRemoteEtag,
                  ),
                ),
              LoadedCandidate() => BackendPassThrough(
                  FetchedCandidate(e, remoteEtag: e.storedRemoteEtag),
                ),
              ResourceError() => BackendPassThrough(e),

              // --- Shard Events ---
              ShardComplete() => BackendBoundary(e),
              ShardSkipped() => BackendBoundary(e),
              ShardError() => BackendBoundary(e),

              // --- Phase Events ---
              PhaseComplete() => BackendBoundary(e),
              PhaseError() => BackendBoundary(e),
            },
            backendCall: backend.download,
            resultKey: (r) => (r.documentIri, r.requestETag),
            toOutput: (event, result) {
              if (result.graph != null) {
                return FetchedCandidate(
                  event,
                  remoteSource: _converter.toGraphSource(result.graph!),
                  remoteEtag: result.etag,
                );
              }
              if (result.notModified) {
                // 304 — remote unchanged, keep stored ETag
                return FetchedCandidate(event, remoteEtag: result.etag);
              }
              // 404/gone — resource does not exist on remote
              return FetchedCandidate(event);
            },
            onError: (event, error, stackTrace) =>
                ResourceError(event.candidate.resourceIri, error, stackTrace),
          ));

  // ---------------------------------------------------------------------------
  // Stage 8: Resource Upload
  // ---------------------------------------------------------------------------

  @override
  StreamTransformer<MergedResourceEvent, UploadedResourceEvent> resourceUpload(
          {PipeperfCollector? perf}) =>
      StreamTransformer.fromBind((stream) => backendPipe<
              MergeResult,
              MergedResourceEvent,
              UploadedResourceEvent,
              RemoteUploadRequest<RawContent>,
              RemoteUploadResult>(
            stream: stream,
            logger: _logger,
            perf: perf,
            perfStage: 'S08.ResourceUpload.FPR',
            classify: (e) => switch (e) {
              // --- Resource Events ---
              MergeResult() when e.needsUpload => BackendRequest(
                  (e.resourceIri.getDocumentIri(), e.resourceEtag),
                  e,
                  RemoteUploadRequest<RawContent>(
                    documentIri: e.resourceIri.getDocumentIri(),
                    document: _converter.encodeGraph(e.mergedGraph),
                    ifMatch: e.resourceEtag,
                  ),
                ),
              MergeResult() => BackendPassThrough(UploadResult(e)),
              ResourceError() => BackendPassThrough(e),

              // --- Shard Events ---
              ShardComplete() => BackendBoundary(e),
              ShardSkipped() => BackendBoundary(e),
              ShardError() => BackendBoundary(e),

              // --- Phase Events ---
              PhaseComplete() => BackendBoundary(e),
              PhaseError() => BackendBoundary(e),
            },
            backendCall: backend.upload,
            resultKey: (r) => (r.documentIri, r.requestETag),
            toOutput: (event, result) => switch (result) {
              SuccessUploadResult(:final etag) =>
                UploadResult(event, newRemoteEtag: etag),
              ConflictUploadResult() => () {
                  final docIri = event.resourceIri.getDocumentIri();
                  _logger.info(
                      'Upload conflict for ${docIri.debug} (If-Match: ${result.requestETag ?? 'none'}) — will retry');
                  return ConflictedResource(event.resourceIri,
                      mergeResult: event,
                      message: 'Upload conflict for ${docIri.debug}');
                }(),
            },
            onError: (event, error, stackTrace) =>
                ResourceError(event.resourceIri, error, stackTrace),
          ));

  // ---------------------------------------------------------------------------
  // Stage 12: Shard Upload
  // ---------------------------------------------------------------------------

  @override
  StreamTransformer<MergedShardEvent, UploadedShardEvent> shardUpload(
          {PipeperfCollector? perf}) =>
      StreamTransformer.fromBind((stream) => backendPipe<
              MergedShard,
              MergedShardEvent,
              UploadedShardEvent,
              RemoteUploadRequest<RawContent>,
              RemoteUploadResult>(
            stream: stream,
            logger: _logger,
            perf: perf,
            perfStage: 'S12.ShardUpload.FPR',
            classify: (e) => switch (e) {
              // --- Shard Events ---
              MergedShard() when e.needsUpload => BackendRequest(
                  (e.shardIri.getDocumentIri(), e.newEtag),
                  e,
                  RemoteUploadRequest<RawContent>(
                    documentIri: e.shardIri.getDocumentIri(),
                    document: _converter.encodeGraph(e.mergedGraph),
                    ifMatch: e.newEtag,
                  ),
                ),
              MergedShard() => BackendPassThrough(UploadedShard(e.shardIri, e)),
              ConflictedShard() => BackendPassThrough(e),
              ShardError() => BackendPassThrough(e),
              ShardSkipped() => BackendPassThrough(e),

              // --- Phase Events ---
              PhaseComplete() => BackendBoundary(e),
              PhaseError() => BackendBoundary(e),
            },
            backendCall: backend.upload,
            resultKey: (r) => (r.documentIri, r.requestETag),
            toOutput: (event, result) => switch (result) {
              SuccessUploadResult(:final etag) =>
                UploadedShard(event.shardIri, event, newRemoteEtag: etag),
              ConflictUploadResult() => () {
                  final docIri = event.shardIri.getDocumentIri();
                  _logger.info(
                      'Shard upload conflict for ${docIri.debug} (If-Match: ${result.requestETag ?? 'none'}) — will retry');
                  return ConflictedShard(event.shardIri,
                      trigger: event,
                      message: 'Shard upload conflict for ${docIri.debug}');
                }(),
            },
            onError: (event, error, stackTrace) =>
                ShardError(event.shardIri, error, stackTrace),
          ));
}
