import 'dart:async';

import 'package:locorda_core/src/storage/remote_storage.dart';
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
/// Boundary events ([PhaseComplete], [ShardComplete]) are never sent to
/// the backend — the adapter drains outstanding results before forwarding
/// boundaries downstream.
class FilePerResourceRemoteSyncStorage implements PipelineRemoteSyncStorage {
  final _logger = Logger('FilePerResourceRemoteSyncStorage');
  final RemoteSyncBackend backend;
  final RdfCore _rdfCore;
  final String _contentType;
  final bool _isBinary;

  FilePerResourceRemoteSyncStorage(this.backend,
      {required RdfCore rdfCore, required String contentType, bool? isBinary})
      : _rdfCore = rdfCore,
        _contentType = contentType,
        _isBinary = isBinary ?? isBinaryContentType(contentType);

  @override
  Future<void> finalizeSync() => Future.value();

  // ---------------------------------------------------------------------------
  // Encoding helpers
  // ---------------------------------------------------------------------------

  /// Convert [RawContent] from backend to pipeline [RdfGraphSource].
  RdfGraphSource _toGraphSource(RawContent raw) => switch (raw) {
        TextContent(:final text, :final contentType) =>
          TextGraphSource(text, contentType: contentType),
        BinaryContent(:final bytes, :final contentType) =>
          BinaryGraphSource(bytes, contentType: contentType),
      };

  /// Encode a [DecodedGraphSource] to [RawContent] for the backend.
  RawContent _encodeGraph(DecodedGraphSource source) {
    // If already encoded in the target content type, reuse raw bytes.
    final orig = source.originalSource;
    if (orig != null && orig.contentType == _contentType) {
      return switch (orig) {
        TextGraphSource(:final text, :final contentType) =>
          TextContent(text, contentType: contentType),
        BinaryGraphSource(:final bytes, :final contentType) =>
          BinaryContent(bytes, contentType: contentType),
      };
    }
    // Encode graph to target content type.
    if (_isBinary) {
      final encodedBytes =
          _rdfCore.encodeBinary(source.graph, contentType: _contentType);
      return BinaryContent(encodedBytes, contentType: _contentType);
    }

    final encoded = _rdfCore.encode(source.graph, contentType: _contentType);
    return TextContent(encoded, contentType: _contentType);
  }

  // ---------------------------------------------------------------------------
  // Stage 2: Shard Fetch
  // ---------------------------------------------------------------------------

  @override
  StreamTransformer<ShardRefEvent, FetchedShardEvent> shardFetch(
          {PipeperfCollector? perf}) =>
      StreamTransformer.fromBind((stream) async* {
        yield* _pipeDownload<ShardRef, ShardRefEvent, FetchedShardEvent>(
          stream,
          perf: perf,
          perfStage: 'S02.ShardFetch',
          extract: (e) => switch (e) {
            ShardRef() => e,
            PhaseComplete() => null,
          },
          toRequest: (e) => RemoteDownloadRequest(
            documentIri: e.shardIri.getDocumentIri(),
            ifNoneMatch: e.storedEtag,
          ),
          toOutput: (event, result) {
            if (result.notModified) {
              return ShardNotModified(event.shardIri, event.shardStorageId,
                  event.fetchPolicy, event.typeIri,
                  storedEtag: event.storedEtag);
            } else if (result.graph == null && event.storedEtag != null) {
              return ShardGone(event.shardIri, event.shardStorageId,
                  event.fetchPolicy, event.typeIri);
            } else if (result.graph == null) {
              return ShardNotModified(event.shardIri, event.shardStorageId,
                  event.fetchPolicy, event.typeIri,
                  existsOnRemote: false);
            } else {
              return ShardContent(
                event.shardIri,
                event.shardStorageId,
                event.fetchPolicy,
                event.typeIri,
                _toGraphSource(result.graph!),
                result.etag!,
              );
            }
          },
          passBoundary: (e) => e as FetchedShardEvent,
        );
      });

  // ---------------------------------------------------------------------------
  // Stage 6: Resource Fetch
  // ---------------------------------------------------------------------------

  @override
  StreamTransformer<LoadedCandidateEvent, FetchedCandidateEvent> resourceFetch(
          {PipeperfCollector? perf}) =>
      StreamTransformer.fromBind((stream) async* {
        yield* _pipeDownload<LoadedCandidate, LoadedCandidateEvent,
            FetchedCandidateEvent>(
          stream,
          perf: perf,
          perfStage: 'S06.ResourceFetch',
          extract: (e) => switch (e) {
            LoadedCandidate() => _needsResourceFetch(e) ? e : null,
            ShardComplete() => null,
            PhaseComplete() => null,
          },
          toRequest: (e) => RemoteDownloadRequest(
            documentIri: e.candidate.resourceIri.getDocumentIri(),
            ifNoneMatch: e.storedRemoteEtag,
          ),
          toOutput: (event, result) {
            if (result.graph != null) {
              return FetchedCandidate(
                event,
                remoteSource: _toGraphSource(result.graph!),
                remoteEtag: result.etag,
              );
            }
            return FetchedCandidate(event, remoteEtag: event.storedRemoteEtag);
          },
          passBoundary: (e) => switch (e) {
            LoadedCandidate() =>
              FetchedCandidate(e, remoteEtag: e.storedRemoteEtag),
            ShardComplete() => e,
            PhaseComplete() => e,
          },
        );
      });

  bool _needsResourceFetch(LoadedCandidate e) =>
      e.candidate.direction != SyncDirection.remoteShardUnchanged &&
      e.candidate.direction != SyncDirection.notInRemoteShard &&
      e.candidate.direction != SyncDirection.shardGone;

  // ---------------------------------------------------------------------------
  // Stage 8: Resource Upload
  // ---------------------------------------------------------------------------

  @override
  StreamTransformer<MergedResourceEvent, UploadedResourceEvent> resourceUpload(
          {PipeperfCollector? perf}) =>
      StreamTransformer.fromBind((stream) async* {
        yield* _pipeUpload<MergeResult, MergedResourceEvent,
            UploadedResourceEvent>(
          stream,
          perf: perf,
          perfStage: 'S08.ResourceUpload',
          extract: (e) => switch (e) {
            MergeResult() => e.needsUpload ? e : null,
            ShardComplete() => null,
            PhaseComplete() => null,
          },
          toRequest: (e) => RemoteUploadRequest<RawContent>(
            documentIri: e.resourceIri.getDocumentIri(),
            document: _encodeGraph(e.mergedGraph),
            ifMatch: e.resourceEtag,
          ),
          toOutput: (event, result) {
            if (result is SuccessUploadResult) {
              return UploadResult(event, newRemoteEtag: result.etag);
            }
            final docIri = event.resourceIri.getDocumentIri();
            _logger.warning('Upload conflict for ${docIri.debug} — skipping');
            return UploadResult(event);
          },
          passBoundary: (e) => switch (e) {
            MergeResult() => UploadResult(e),
            ShardComplete() => e,
            PhaseComplete() => e,
          },
        );
      });

  // ---------------------------------------------------------------------------
  // Stage 12: Shard Upload
  // ---------------------------------------------------------------------------

  @override
  StreamTransformer<MergedShardEvent, UploadedShardEvent> shardUpload(
          {PipeperfCollector? perf}) =>
      StreamTransformer.fromBind((stream) async* {
        yield* _pipeUpload<MergedShard, MergedShardEvent, UploadedShardEvent>(
          stream,
          perf: perf,
          perfStage: 'S12.ShardUpload',
          extract: (e) => switch (e) {
            MergedShard() => e.needsUpload ? e : null,
            PhaseComplete() => null,
          },
          toRequest: (e) => RemoteUploadRequest<RawContent>(
            documentIri: e.shardIri.getDocumentIri(),
            document: _encodeGraph(e.mergedGraph),
            ifMatch: e.newEtag,
          ),
          toOutput: (event, result) {
            if (result is SuccessUploadResult) {
              return UploadedShard(event.shardIri, event,
                  newRemoteEtag: result.etag);
            }
            final docIri = event.shardIri.getDocumentIri();
            _logger.warning(
                'Shard upload conflict for ${docIri.debug} — skipping');
            return UploadedShard(event.shardIri, event);
          },
          passBoundary: (e) => switch (e) {
            MergedShard() => UploadedShard(e.shardIri, e),
            PhaseComplete() => e,
          },
        );
      });

  // ---------------------------------------------------------------------------
  // Generic stream-piping helpers
  // ---------------------------------------------------------------------------

  /// Pipes download requests through [backend.download], draining at
  /// boundaries.
  ///
  /// [extract] returns the data item if the event should be fetched, or null
  /// for pass-through/boundary events. [passBoundary] converts non-fetched
  /// events (boundaries and pass-throughs) to output type.
  Stream<TOut> _pipeDownload<TData, TIn, TOut>(
    Stream<TIn> stream, {
    required TData? Function(TIn) extract,
    required RemoteDownloadRequest Function(TData) toRequest,
    required TOut Function(TData, RemoteDownloadResult<RawContent>) toOutput,
    required TOut Function(TIn) passBoundary,
    PipeperfCollector? perf,
    String? perfStage,
  }) async* {
    // Buffer data events between boundaries, then send them as a batch
    // stream through backend.download and zip results with originals.
    final buffer = <TData>[];
    final passThrough = <TIn>[];

    Future<void> drain() async {
      // nothing to do
    }

    Stream<TOut> flush() async* {
      if (buffer.isNotEmpty) {
        final sw = perf != null ? (Stopwatch()..start()) : null;
        final requests = buffer.map(toRequest);
        final resultStream = backend.download(Stream.fromIterable(requests));
        final results = await resultStream.toList();
        if (sw != null) perf!.record(perfStage!, sw.elapsedMicroseconds);

        for (var i = 0; i < buffer.length; i++) {
          yield toOutput(buffer[i], results[i]);
        }
        buffer.clear();
      }

      for (final e in passThrough) {
        yield passBoundary(e);
      }
      passThrough.clear();
    }

    await for (final event in stream) {
      final data = extract(event);
      if (data != null) {
        buffer.add(data);
      } else {
        passThrough.add(event);
      }

      // At boundaries: drain backend, then forward boundary.
      if (data == null) {
        yield* flush();
      }
    }

    // Flush any remaining items (shouldn't happen with well-formed streams,
    // but be safe).
    yield* flush();
    await drain();
  }

  /// Pipes upload requests through [backend.upload], draining at boundaries.
  Stream<TOut> _pipeUpload<TData, TIn, TOut>(
    Stream<TIn> stream, {
    required TData? Function(TIn) extract,
    required RemoteUploadRequest<RawContent> Function(TData) toRequest,
    required TOut Function(TData, RemoteUploadResult) toOutput,
    required TOut Function(TIn) passBoundary,
    PipeperfCollector? perf,
    String? perfStage,
  }) async* {
    final buffer = <TData>[];
    final passThrough = <TIn>[];

    Stream<TOut> flush() async* {
      if (buffer.isNotEmpty) {
        final sw = perf != null ? (Stopwatch()..start()) : null;
        final requests = buffer.map(toRequest);
        final resultStream = backend.upload(Stream.fromIterable(requests));
        final results = await resultStream.toList();
        if (sw != null) perf!.record(perfStage!, sw.elapsedMicroseconds);

        for (var i = 0; i < buffer.length; i++) {
          yield toOutput(buffer[i], results[i]);
        }
        buffer.clear();
      }

      for (final e in passThrough) {
        yield passBoundary(e);
      }
      passThrough.clear();
    }

    await for (final event in stream) {
      final data = extract(event);
      if (data != null) {
        buffer.add(data);
      } else {
        passThrough.add(event);
      }

      if (data == null) {
        yield* flush();
      }
    }

    yield* flush();
  }
}
