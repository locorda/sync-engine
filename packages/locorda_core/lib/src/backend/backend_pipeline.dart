import 'dart:async';

import 'package:locorda_core/src/storage/remote_storage.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_support.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:logging/logging.dart';

abstract interface class FPRBackend {
  Future<List<RemoteDownloadResult<RdfGraph>>> downloadMany(
      Iterable<RemoteDownloadRequest> requests);

  /// Upload multiple documents to remote storage.
  ///
  /// Default implementation maps each request to [upload].
  /// Backends may override this for transport-level batching.
  Future<List<RemoteUploadResult>> uploadMany(
      Iterable<RemoteUploadRequest<RdfGraph>> requests);
}

abstract class SimpleFPRBackend implements FPRBackend {
  Future<RemoteDownloadResult<RdfGraph>> download(IriTerm documentIri,
      {String? ifNoneMatch});
  Future<RemoteUploadResult> upload(IriTerm documentIri, RdfGraph graph,
      {String? ifMatch});

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

class FilePerResourceRemoteSyncSupport implements RemoteSyncPipelineSupport {
  final _logger = Logger('FilePerResourceRemoteSyncSupport');
  final FPRBackend backend;
  final int batchSize;

  FilePerResourceRemoteSyncSupport(
    this.backend, {
    this.batchSize = defaultPipelineBatchSize,
  });

  @override
  StreamTransformer<ShardRefEvent, FetchedShardEvent> shardFetch() =>
      StreamTransformer.fromBind((stream) async* {
        final buffer = <ShardRef>[];

        await for (final event in stream) {
          switch (event) {
            case ShardRef():
              buffer.add(event);
              if (buffer.length >= batchSize) {
                yield* _fetchShardChunk(buffer);
                buffer.clear();
              }
            case PhaseComplete():
              if (buffer.isNotEmpty) {
                yield* _fetchShardChunk(buffer);
                buffer.clear();
              }
              yield event;
          }
        }
      });

  Stream<FetchedShardEvent> _fetchShardChunk(List<ShardRef> chunk) async* {
    final requests = chunk.map((e) => RemoteDownloadRequest(
          documentIri: e.shardIri.getDocumentIri(),
          ifNoneMatch: e.storedEtag,
        ));

    final results = await backend.downloadMany(requests);

    for (var i = 0; i < chunk.length; i++) {
      final event = chunk[i];
      final result = results[i];

      if (result.notModified) {
        yield ShardNotModified(event.shardIri, event.shardStorageId,
            event.fetchPolicy, event.typeIri);
      } else if (result.graph == null && event.storedEtag != null) {
        yield ShardGone(event.shardIri, event.shardStorageId, event.fetchPolicy,
            event.typeIri);
      } else if (result.graph == null) {
        yield ShardNotModified(event.shardIri, event.shardStorageId,
            event.fetchPolicy, event.typeIri,
            existsOnRemote: false);
      } else {
        yield ShardContent(
          event.shardIri,
          event.shardStorageId,
          event.fetchPolicy,
          event.typeIri,
          DecodedGraphSource(result.graph!),
          result.etag!,
        );
      }
    }
  }

  @override
  StreamTransformer<LoadedCandidateEvent, FetchedCandidateEvent>
      resourceFetch() => StreamTransformer.fromBind((stream) async* {
            final buffer = <LoadedCandidate>[];
            final passThrough = <LoadedCandidate>[];

            await for (final event in stream) {
              switch (event) {
                case LoadedCandidate():
                  if (event.candidate.direction == SyncDirection.localOnly ||
                      event.candidate.direction ==
                          SyncDirection.remoteRemoved) {
                    passThrough.add(event);
                  } else {
                    buffer.add(event);
                  }
                  if (buffer.length >= batchSize) {
                    yield* _yieldPassThrough(passThrough);
                    yield* _fetchResourceChunk(buffer);
                    buffer.clear();
                    passThrough.clear();
                  }
                case ShardComplete():
                  if (buffer.isNotEmpty || passThrough.isNotEmpty) {
                    yield* _yieldPassThrough(passThrough);
                    yield* _fetchResourceChunk(buffer);
                    buffer.clear();
                    passThrough.clear();
                  }
                  yield event;
                case PhaseComplete():
                  if (buffer.isNotEmpty || passThrough.isNotEmpty) {
                    yield* _yieldPassThrough(passThrough);
                    yield* _fetchResourceChunk(buffer);
                    buffer.clear();
                    passThrough.clear();
                  }
                  yield event;
              }
            }
          });

  Stream<FetchedCandidateEvent> _yieldPassThrough(
      List<LoadedCandidate> items) async* {
    for (final event in items) {
      yield FetchedCandidate(event, remoteEtag: event.storedRemoteEtag);
    }
  }

  Stream<FetchedCandidateEvent> _fetchResourceChunk(
      List<LoadedCandidate> chunk) async* {
    if (chunk.isEmpty) return;
    final requests = chunk.map((e) => RemoteDownloadRequest(
          documentIri: e.candidate.resourceIri.getDocumentIri(),
          ifNoneMatch: e.storedRemoteEtag,
        ));

    final results = await backend.downloadMany(requests);

    for (var i = 0; i < chunk.length; i++) {
      final event = chunk[i];
      final result = results[i];

      if (result.graph != null) {
        yield FetchedCandidate(
          event,
          remoteSource: DecodedGraphSource(result.graph!),
          remoteEtag: result.etag,
        );
      } else {
        yield FetchedCandidate(event, remoteEtag: event.storedRemoteEtag);
      }
    }
  }

  @override
  StreamTransformer<MergedResourceEvent, UploadedResourceEvent>
      resourceUpload() => StreamTransformer.fromBind((stream) async* {
            final buffer = <MergeResult>[];
            final passThrough = <MergeResult>[];

            await for (final event in stream) {
              switch (event) {
                case MergeResult():
                  if (!event.needsUpload) {
                    passThrough.add(event);
                  } else {
                    buffer.add(event);
                  }
                  if (buffer.length >= batchSize) {
                    yield* _yieldUploadPassThrough(passThrough);
                    yield* _uploadResourceChunk(buffer);
                    buffer.clear();
                    passThrough.clear();
                  }
                case ShardComplete():
                  if (buffer.isNotEmpty || passThrough.isNotEmpty) {
                    yield* _yieldUploadPassThrough(passThrough);
                    yield* _uploadResourceChunk(buffer);
                    buffer.clear();
                    passThrough.clear();
                  }
                  yield event;
                case PhaseComplete():
                  if (buffer.isNotEmpty || passThrough.isNotEmpty) {
                    yield* _yieldUploadPassThrough(passThrough);
                    yield* _uploadResourceChunk(buffer);
                    buffer.clear();
                    passThrough.clear();
                  }
                  yield event;
              }
            }
          });

  Stream<UploadedResourceEvent> _yieldUploadPassThrough(
      List<MergeResult> items) async* {
    for (final event in items) {
      yield UploadResult(event);
    }
  }

  Stream<UploadedResourceEvent> _uploadResourceChunk(
      List<MergeResult> chunk) async* {
    if (chunk.isEmpty) return;
    final requests = chunk.map((e) => RemoteUploadRequest<RdfGraph>(
          documentIri: e.resourceIri.getDocumentIri(),
          document: e.mergedGraph.graph,
          ifMatch: e.resourceEtag,
        ));

    final results = await backend.uploadMany(requests);

    for (var i = 0; i < chunk.length; i++) {
      final event = chunk[i];
      final result = results[i];

      if (result is SuccessUploadResult) {
        yield UploadResult(event, newRemoteEtag: result.etag);
      } else {
        final docIri = event.resourceIri.getDocumentIri();
        _logger.warning('Upload conflict for ${docIri.debug} — skipping');
        yield UploadResult(event);
      }
    }
  }

  @override
  StreamTransformer<MergedShardEvent, UploadedShardEvent> shardUpload() =>
      StreamTransformer.fromBind((stream) async* {
        final buffer = <MergedShard>[];
        final passThrough = <MergedShard>[];

        await for (final event in stream) {
          switch (event) {
            case MergedShard():
              if (!event.needsUpload) {
                passThrough.add(event);
              } else {
                buffer.add(event);
              }
              if (buffer.length >= batchSize) {
                yield* _yieldShardUploadPassThrough(passThrough);
                yield* _uploadShardChunk(buffer);
                buffer.clear();
                passThrough.clear();
              }
            case PhaseComplete():
              if (buffer.isNotEmpty || passThrough.isNotEmpty) {
                yield* _yieldShardUploadPassThrough(passThrough);
                yield* _uploadShardChunk(buffer);
                buffer.clear();
                passThrough.clear();
              }
              yield event;
          }
        }
      });

  Stream<UploadedShardEvent> _yieldShardUploadPassThrough(
      List<MergedShard> items) async* {
    for (final event in items) {
      yield UploadedShard(event.shardIri, event);
    }
  }

  Stream<UploadedShardEvent> _uploadShardChunk(List<MergedShard> chunk) async* {
    if (chunk.isEmpty) return;
    final requests = chunk.map((e) => RemoteUploadRequest<RdfGraph>(
          documentIri: e.shardIri.getDocumentIri(),
          document: e.mergedGraph.graph,
          ifMatch: e.newEtag,
        ));

    final results = await backend.uploadMany(requests);

    for (var i = 0; i < chunk.length; i++) {
      final event = chunk[i];
      final result = results[i];

      if (result is SuccessUploadResult) {
        yield UploadedShard(event.shardIri, event, newRemoteEtag: result.etag);
      } else {
        final docIri = event.shardIri.getDocumentIri();
        _logger.warning('Shard upload conflict for ${docIri.debug} — skipping');
        yield UploadedShard(event.shardIri, event);
      }
    }
  }
}
