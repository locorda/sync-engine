import 'dart:async';

import 'package:locorda_core/src/storage/remote_storage.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_support.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:logging/logging.dart';

abstract interface class FPRBackend {
  /// Download multiple documents, returning raw/source form — no decoding.
  ///
  /// Backends return [EncodedRdfGraphSource] (raw bytes/text) or, if they
  /// already hold a decoded graph (e.g. in-memory backends), [DecodedGraphSource].
  /// Decoding is deferred to the CPU stage that first needs the parsed graph.
  Future<List<RemoteDownloadResult<RdfGraphSource>>> downloadSources(
      Iterable<RemoteDownloadRequest> requests);

  /// Upload multiple documents to remote storage, accepting source form.
  ///
  /// Callers pass [RdfGraphSource] so backends can use pre-encoded bytes
  /// (via [DecodedGraphSource.originalSource]) when available, avoiding a
  /// redundant encode/decode round-trip. In practice the source after CRDT
  /// merge is always [DecodedGraphSource]; backends that need encoded bytes
  /// must encode inside this method.
  Future<List<RemoteUploadResult>> uploadSources(
      Iterable<RemoteUploadRequest<RdfGraphSource>> requests);
}

abstract class SimpleFPRBackend implements FPRBackend {
  /// Download a single document, returning raw/source form — no decoding.
  Future<RemoteDownloadResult<RdfGraphSource>> downloadSource(
      IriTerm documentIri,
      {String? ifNoneMatch});

  /// Upload a single document from source form.
  Future<RemoteUploadResult> uploadSource(
      IriTerm documentIri, RdfGraphSource source,
      {String? ifMatch});

  /// Download multiple documents from remote storage.
  ///
  /// Default implementation maps each request to [downloadSource].
  /// Backends may override this for transport-level batching.
  @override
  Future<List<RemoteDownloadResult<RdfGraphSource>>> downloadSources(
      Iterable<RemoteDownloadRequest> requests) async {
    final results = <RemoteDownloadResult<RdfGraphSource>>[];
    for (final request in requests) {
      results.add(await downloadSource(
        request.documentIri,
        ifNoneMatch: request.ifNoneMatch,
      ));
    }
    return results;
  }

  /// Upload multiple documents from source form.
  ///
  /// Default implementation maps each request to [uploadSource].
  /// Backends may override this for transport-level batching.
  @override
  Future<List<RemoteUploadResult>> uploadSources(
      Iterable<RemoteUploadRequest<RdfGraphSource>> requests) async {
    final results = <RemoteUploadResult>[];
    for (final request in requests) {
      results.add(await uploadSource(
        request.documentIri,
        request.document,
        ifMatch: request.ifMatch,
      ));
    }
    return results;
  }
}

class FilePerResourceRemoteSyncStorage implements PipelineRemoteSyncStorage {
  final _logger = Logger('FilePerResourceRemoteSyncStorage');
  final FPRBackend backend;
  final int batchSize;

  FilePerResourceRemoteSyncStorage(
    this.backend, {
    this.batchSize = defaultPipelineBatchSize,
  });

  @override
  Future<void> finalizeSync() => Future.value();

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

    final results = await backend.downloadSources(requests);

    for (var i = 0; i < chunk.length; i++) {
      final event = chunk[i];
      final result = results[i];

      if (result.notModified) {
        yield ShardNotModified(event.shardIri, event.shardStorageId,
            event.fetchPolicy, event.typeIri,
            storedEtag: event.storedEtag);
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
          result.graph!,
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
                  if (event.candidate.direction ==
                          SyncDirection.remoteShardUnchanged ||
                      event.candidate.direction ==
                          SyncDirection.notInRemoteShard ||
                      event.candidate.direction == SyncDirection.shardGone) {
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

    final results = await backend.downloadSources(requests);

    for (var i = 0; i < chunk.length; i++) {
      final event = chunk[i];
      final result = results[i];

      if (result.graph != null) {
        yield FetchedCandidate(
          event,
          remoteSource: result.graph!,
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
    final requests = chunk.map((e) => RemoteUploadRequest<RdfGraphSource>(
          documentIri: e.resourceIri.getDocumentIri(),
          document: e.mergedGraph,
          ifMatch: e.resourceEtag,
        ));

    final results = await backend.uploadSources(requests);

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
    final requests = chunk.map((e) => RemoteUploadRequest<RdfGraphSource>(
          documentIri: e.shardIri.getDocumentIri(),
          document: e.mergedGraph,
          ifMatch: e.newEtag,
        ));

    final results = await backend.uploadSources(requests);

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
