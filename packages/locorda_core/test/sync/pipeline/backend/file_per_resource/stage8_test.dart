import 'package:locorda_core/src/sync/pipeline/pipeperf.dart';

/// Tests for Stage 8 (Resource Upload) — file_per_resource layout.
///
/// FPR uploads resources immediately via streaming (unlike SDS/SF which defer).
///
/// Verifies:
/// - Successful upload: SuccessUploadResult → UploadResult with newRemoteEtag
/// - Conflict: ConflictUploadResult → UploadResult without newRemoteEtag
/// - needsUpload=false bypass: MergeResult → UploadResult (PassThrough)
/// - [ResourceError] passes through, other uploads continue normally
/// - Upstream [ShardError] passes through with completed uploads
/// - [PhaseError] passes through with completed uploads
/// - Response-order: results emitted as they arrive within a segment
/// - Backend failure → [ResourceError] for all buffered resources
import 'dart:async';
import 'dart:typed_data';

import 'package:locorda_core/src/storage/remote_storage.dart';
import 'package:locorda_core/src/sync/pipeline/backend/file_per_resource_pipeline.dart';
import 'package:locorda_core/src/sync/pipeline/backend/remote_sync_backend.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:locorda_rdf_jelly/jelly.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Test data
// ---------------------------------------------------------------------------

final _rdfCore = RdfCore.withStandardCodecs();
final _contentType = jellyMimeType;
final _emptyGraph = RdfGraph();

final _shardIriA = IriTerm('tag:test,2025:shardA#shard');
final _resIri1 = IriTerm('tag:test,2025:res1#it');
final _resIri2 = IriTerm('tag:test,2025:res2#it');

DecodedGraphSource _preEncodedGraph() => DecodedGraphSource(
      _emptyGraph,
      originalSource:
          BinaryGraphSource(Uint8List(0), contentType: _contentType),
    );

MergeResult _mergeResult(IriTerm resourceIri,
        {bool needsUpload = true, String? resourceEtag}) =>
    MergeResult(
      resourceIri,
      IriTerm('tag:test,2025:Type'),
      _preEncodedGraph(),
      BinaryGraphSource(Uint8List(0), contentType: jellyMimeType),
      needsUpload: needsUpload,
      needsDbWrite: true,
      clock: (logicalTime: 1, physicalTime: 1, fullClock: const [], hash: ''),
      resolvedGroupIndices: const [],
      indexEntries: const [],
      resourceEtag: resourceEtag,
    );

ShardComplete _shardComplete(IriTerm shardIri) => ShardComplete(shardIri, null);

ResourceError _resourceError(IriTerm resourceIri) =>
    ResourceError(resourceIri, StateError('test error'), StackTrace.current);

// ---------------------------------------------------------------------------
// Stubs
// ---------------------------------------------------------------------------

class _SuccessBackend implements RemoteSyncBackend {
  int uploadCount = 0;

  @override
  Stream<RemoteDownloadResult<RawContent>> download(
      Stream<RemoteDownloadRequest> requests) async* {
    await for (final request in requests) {
      yield RemoteDownloadResult(
        documentIri: request.documentIri,
        requestETag: request.ifNoneMatch,
        graph: null,
        etag: null,
      );
    }
  }

  @override
  Stream<RemoteUploadResult> upload(
      Stream<RemoteUploadRequest<RawContent>> requests) async* {
    await for (final request in requests) {
      uploadCount++;
      yield SuccessUploadResult(
        'etag-$uploadCount',
        documentIri: request.documentIri,
        requestETag: request.ifMatch,
      );
    }
  }

  @override
  Future<void> finalize(SyncFinalizationState state,
      {PipeperfCollector? perf}) async {}
}

class _ConflictBackend implements RemoteSyncBackend {
  @override
  Stream<RemoteDownloadResult<RawContent>> download(
          Stream<RemoteDownloadRequest> requests) =>
      const Stream.empty();

  @override
  Stream<RemoteUploadResult> upload(
      Stream<RemoteUploadRequest<RawContent>> requests) async* {
    await for (final request in requests) {
      yield ConflictUploadResult(
        documentIri: request.documentIri,
        requestETag: request.ifMatch,
      );
    }
  }

  @override
  Future<void> finalize(SyncFinalizationState state,
      {PipeperfCollector? perf}) async {}
}

/// Backend with configurable per-request behavior.
class _ConfigurableUploadBackend implements RemoteSyncBackend {
  final RemoteUploadResult Function(RemoteUploadRequest<RawContent>) _handler;

  _ConfigurableUploadBackend(this._handler);

  @override
  Stream<RemoteDownloadResult<RawContent>> download(
          Stream<RemoteDownloadRequest> requests) =>
      const Stream.empty();

  @override
  Stream<RemoteUploadResult> upload(
      Stream<RemoteUploadRequest<RawContent>> requests) async* {
    await for (final request in requests) {
      yield _handler(request);
    }
  }

  @override
  Future<void> finalize(SyncFinalizationState state,
      {PipeperfCollector? perf}) async {}
}

/// Backend that reverses response order.
class _ReverseOrderUploadBackend implements RemoteSyncBackend {
  @override
  Stream<RemoteDownloadResult<RawContent>> download(
          Stream<RemoteDownloadRequest> requests) =>
      const Stream.empty();

  @override
  Stream<RemoteUploadResult> upload(
      Stream<RemoteUploadRequest<RawContent>> requests) async* {
    final collected = await requests.toList();
    for (final request in collected.reversed) {
      yield SuccessUploadResult(
        'etag-${request.documentIri.value}',
        documentIri: request.documentIri,
        requestETag: request.ifMatch,
      );
    }
  }

  @override
  Future<void> finalize(SyncFinalizationState state,
      {PipeperfCollector? perf}) async {}
}

class _FailingUploadBackend implements RemoteSyncBackend {
  @override
  Stream<RemoteDownloadResult<RawContent>> download(
          Stream<RemoteDownloadRequest> requests) =>
      const Stream.empty();

  @override
  Stream<RemoteUploadResult> upload(
      Stream<RemoteUploadRequest<RawContent>> requests) {
    return Stream.error(StateError('upload failure'));
  }

  @override
  Future<void> finalize(SyncFinalizationState state,
      {PipeperfCollector? perf}) async {}
}

/// Backend that records upload requests for assertion.
class _RecordingUploadBackend implements RemoteSyncBackend {
  final requests = <RemoteUploadRequest<RawContent>>[];

  @override
  Stream<RemoteDownloadResult<RawContent>> download(
          Stream<RemoteDownloadRequest> requests) =>
      const Stream.empty();

  @override
  Stream<RemoteUploadResult> upload(
      Stream<RemoteUploadRequest<RawContent>> reqs) async* {
    await for (final req in reqs) {
      requests.add(req);
      yield SuccessUploadResult(
        'etag-new',
        documentIri: req.documentIri,
        requestETag: req.ifMatch,
      );
    }
  }

  @override
  Future<void> finalize(SyncFinalizationState state,
      {PipeperfCollector? perf}) async {}
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Future<List<UploadedResourceEvent>> _runS08(
  StreamTransformer<MergedResourceEvent, UploadedResourceEvent> transformer,
  List<MergedResourceEvent> events,
) async {
  final controller = StreamController<MergedResourceEvent>();
  final output = controller.stream.transform(transformer);
  final resultFuture = output.toList();
  for (final e in events) {
    controller.add(e);
  }
  await controller.close();
  return resultFuture;
}

FilePerResourceRemoteSyncStorage _storageWith(RemoteSyncBackend backend) =>
    FilePerResourceRemoteSyncStorage(
      backend,
      rdfCore: _rdfCore,
      contentType: _contentType,
    );

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('Stage 8 — file_per_resource — successful upload', () {
    test('SuccessUploadResult yields UploadResult with newRemoteEtag',
        () async {
      final backend = _SuccessBackend();
      final storage = _storageWith(backend);

      final results = await _runS08(storage.resourceUpload(), [
        _mergeResult(_resIri1),
        _shardComplete(_shardIriA),
      ]);

      expect(results, hasLength(2));
      final upload = results[0] as UploadResult;
      expect(upload.newRemoteEtag, 'etag-1');
      expect(backend.uploadCount, 1);
    });

    test('multiple resources all uploaded and emit UploadResult', () async {
      final backend = _SuccessBackend();
      final storage = _storageWith(backend);

      final results = await _runS08(storage.resourceUpload(), [
        _mergeResult(_resIri1),
        _mergeResult(_resIri2),
        _shardComplete(_shardIriA),
      ]);

      expect(results.whereType<UploadResult>(), hasLength(2));
      expect(results.whereType<ShardComplete>(), hasLength(1));
      expect(backend.uploadCount, 2);
    });
  });

  group('Stage 8 — file_per_resource — conflict handling', () {
    test('ConflictUploadResult yields ConflictedResource', () async {
      final storage = _storageWith(_ConflictBackend());

      final results = await _runS08(storage.resourceUpload(), [
        _mergeResult(_resIri1, resourceEtag: 'old-etag'),
        _shardComplete(_shardIriA),
      ]);

      expect(results, hasLength(2));
      final conflict = results[0] as ConflictedResource;
      expect(conflict.resourceIri, _resIri1);
      expect(conflict.mergeResult, isA<MergeResult>());
      expect(conflict.message, contains('Upload conflict'));
    });

    test('mixed success and conflict in same shard', () async {
      final storage = _storageWith(_ConfigurableUploadBackend((req) {
        if (req.documentIri.value.contains('res1')) {
          return SuccessUploadResult('new-etag',
              documentIri: req.documentIri, requestETag: req.ifMatch);
        }
        return ConflictUploadResult(
            documentIri: req.documentIri, requestETag: req.ifMatch);
      }));

      final results = await _runS08(storage.resourceUpload(), [
        _mergeResult(_resIri1),
        _mergeResult(_resIri2),
        _shardComplete(_shardIriA),
      ]);

      final uploads = results.whereType<UploadResult>().toList();
      final conflicts = results.whereType<ConflictedResource>().toList();
      expect(uploads, hasLength(1));
      expect(conflicts, hasLength(1));
      expect(uploads[0].newRemoteEtag, 'new-etag');
      expect(conflicts[0].resourceIri, _resIri2);
    });
  });

  group('Stage 8 — file_per_resource — needsUpload bypass', () {
    test('needsUpload=false bypasses backend, emits UploadResult directly',
        () async {
      final recording = _RecordingUploadBackend();
      final storage = _storageWith(recording);

      final results = await _runS08(storage.resourceUpload(), [
        _mergeResult(_resIri1, needsUpload: false),
        _shardComplete(_shardIriA),
      ]);

      expect(results, hasLength(2));
      final upload = results[0] as UploadResult;
      expect(upload.newRemoteEtag, isNull);
      expect(recording.requests, isEmpty,
          reason: 'No backend request for needsUpload=false');
    });

    test('mix of needsUpload=true and false', () async {
      final recording = _RecordingUploadBackend();
      final storage = _storageWith(recording);

      final results = await _runS08(storage.resourceUpload(), [
        _mergeResult(_resIri1, needsUpload: false),
        _mergeResult(_resIri2, needsUpload: true),
        _shardComplete(_shardIriA),
      ]);

      expect(results.whereType<UploadResult>(), hasLength(2));
      expect(recording.requests, hasLength(1));
    });
  });

  group('Stage 8 — file_per_resource — response order', () {
    test('results emitted in response order within a shard segment', () async {
      final storage = _storageWith(_ReverseOrderUploadBackend());

      final results = await _runS08(storage.resourceUpload(), [
        _mergeResult(_resIri1),
        _mergeResult(_resIri2),
        _shardComplete(_shardIriA),
      ]);

      // Backend reverses: res2 response arrives first
      final uploads = results.whereType<UploadResult>().toList();
      expect(uploads, hasLength(2));
      expect(uploads[0].mergeResult.resourceIri, _resIri2);
      expect(uploads[1].mergeResult.resourceIri, _resIri1);
    });
  });

  group('Stage 8 — file_per_resource — error handling', () {
    test('ResourceError passes through, completed uploads emitted normally',
        () async {
      final storage = _storageWith(_SuccessBackend());

      final results = await _runS08(storage.resourceUpload(), [
        _mergeResult(_resIri1),
        _resourceError(_resIri2),
        _shardComplete(_shardIriA),
      ]);

      expect(results, hasLength(3));
      expect(results[0], isA<UploadResult>());
      expect(results[1], isA<ResourceError>());
      expect(results[2], isA<ShardComplete>());
    });

    test('MergeResult after ResourceError still uploads normally', () async {
      final backend = _SuccessBackend();
      final storage = _storageWith(backend);

      final results = await _runS08(storage.resourceUpload(), [
        _resourceError(_resIri1),
        _mergeResult(_resIri2, needsUpload: true),
        _shardComplete(_shardIriA),
      ]);

      expect(results.whereType<UploadResult>(), hasLength(1));
      expect(results.whereType<ResourceError>(), hasLength(1));
      expect(backend.uploadCount, 1);
    });

    test('Upstream ShardError passes through with completed uploads', () async {
      final backend = _SuccessBackend();
      final storage = _storageWith(backend);

      final results = await _runS08(storage.resourceUpload(), [
        _mergeResult(_resIri1),
        ShardError(_shardIriA, StateError('upstream'), StackTrace.current),
      ]);

      expect(results, hasLength(2));
      expect(results[0], isA<UploadResult>());
      expect(results[1], isA<ShardError>());
    });

    test('Backend failure emits ResourceError for pending resources', () async {
      final storage = _storageWith(_FailingUploadBackend());

      final results = await _runS08(storage.resourceUpload(), [
        _mergeResult(_resIri1),
        _mergeResult(_resIri2),
        _shardComplete(_shardIriA),
      ]);

      final errors = results.whereType<ResourceError>().toList();
      expect(errors, hasLength(2));
      expect(results.last, isA<ShardComplete>());
    });
  });

  group('Stage 8 — file_per_resource — PhaseError', () {
    test('PhaseError passes through with completed uploads', () async {
      final storage = _storageWith(_SuccessBackend());

      final results = await _runS08(storage.resourceUpload(), [
        _mergeResult(_resIri1),
        _resourceError(_resIri2),
        PhaseError(StateError('test'), StackTrace.current, stage: 'S07c'),
      ]);

      expect(results, hasLength(3));
      expect(results[0], isA<UploadResult>());
      expect(results[1], isA<ResourceError>());
      expect(results[2], isA<PhaseError>());
    });
  });

  group('Stage 8 — file_per_resource — request identity', () {
    test('ifMatch carries resourceEtag from MergeResult', () async {
      final recording = _RecordingUploadBackend();
      final storage = _storageWith(recording);

      await _runS08(storage.resourceUpload(), [
        _mergeResult(_resIri1, resourceEtag: 'my-etag'),
        _shardComplete(_shardIriA),
      ]);

      expect(recording.requests, hasLength(1));
      expect(recording.requests.first.ifMatch, 'my-etag');
      // Fragment stripped for document IRI
      expect(
          recording.requests.first.documentIri, IriTerm('tag:test,2025:res1'));
    });
  });
}
