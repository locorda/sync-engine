/// Tests for Stage 12 (Shard Upload) — file_per_resource layout.
///
/// Verifies:
/// - Successful upload: SuccessUploadResult → UploadedShard with newRemoteEtag
/// - Conflict: ConflictUploadResult → ConflictedShard (Boundary)
/// - needsUpload=false bypass: MergedShard → UploadedShard (Boundary, no upload)
/// - [ConflictedShard] passes through as Boundary
/// - Upload failure → [ShardError] for buffered shard
/// - [PhaseError] clears buffer and passes through
/// - Input-order: results emitted in input order (isBoundary=true)
import 'dart:async';
import 'dart:typed_data';

import 'package:locorda_core/src/storage/remote_storage.dart';
import 'package:locorda_core/src/sync/pipeline/backend/file_per_resource_pipeline.dart';
import 'package:locorda_core/src/sync/pipeline/backend/remote_sync_backend.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';
import 'package:locorda_core/src/sync/pipeline/pipeperf.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:locorda_rdf_jelly/jelly.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Test data
// ---------------------------------------------------------------------------

final _rdfCore = RdfCore.withStandardCodecs();
final _contentType = jellyMimeType;

final _shardIriA = IriTerm('tag:test,2025:shardA#shard');
final _shardIriB = IriTerm('tag:test,2025:shardB#shard');
final _emptyGraph = RdfGraph();

MergedShard _mergedShard(IriTerm shardIri,
        {bool needsUpload = true, String? newEtag}) =>
    MergedShard(
      shardIri,
      DecodedGraphSource(
        _emptyGraph,
        originalSource:
            BinaryGraphSource(Uint8List(0), contentType: _contentType),
      ),
      BinaryGraphSource(Uint8List(0), contentType: jellyMimeType),
      needsUpload: needsUpload,
      ourPhysicalClock: 1,
      newEtag: newEtag,
    );

// ---------------------------------------------------------------------------
// Stubs
// ---------------------------------------------------------------------------

class _SuccessUploadBackend implements RemoteSyncBackend {
  int uploadCount = 0;

  @override
  Stream<RemoteDownloadResult<RawContent>> download(
          Stream<RemoteDownloadRequest> requests) =>
      const Stream.empty();

  @override
  Stream<RemoteUploadResult> upload(
      Stream<RemoteUploadRequest<RawContent>> requests) async* {
    await for (final request in requests) {
      uploadCount++;
      yield SuccessUploadResult(
        'new-etag-$uploadCount',
        documentIri: request.documentIri,
        requestETag: request.ifMatch,
      );
    }
  }

  @override
  Future<void> finalize(SyncFinalizationState state,
      {PipeperfCollector? perf}) async {}
}

class _ConflictUploadBackend implements RemoteSyncBackend {
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

/// Backend that reverses response order — tests that S12 enforces input-order.
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
      Stream<RemoteDownloadRequest> requests) async* {
    await for (final request in requests) {
      yield NotFoundDownloadResult<RawContent>(
        documentIri: request.documentIri,
        requestETag: request.ifNoneMatch,
      );
    }
  }

  @override
  Stream<RemoteUploadResult> upload(
      Stream<RemoteUploadRequest<RawContent>> requests) {
    return Stream.error(StateError('upload failure'));
  }

  @override
  Future<void> finalize(SyncFinalizationState state,
      {PipeperfCollector? perf}) async {}
}

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
        'new-etag',
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

Future<List<T>> _transform<S, T>(
  StreamTransformer<S, T> transformer,
  List<S> events,
) async {
  final controller = StreamController<S>();
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
  group('Stage 12 — file_per_resource — successful upload', () {
    test('SuccessUploadResult yields UploadedShard with newRemoteEtag',
        () async {
      final backend = _SuccessUploadBackend();
      final storage = _storageWith(backend);

      final results =
          await _transform(storage.shardUpload(), <MergedShardEvent>[
        _mergedShard(_shardIriA),
        PhaseComplete(SyncInput([_shardIriA]), 1),
      ]);

      expect(results, hasLength(2));
      final uploaded = results[0] as UploadedShard;
      expect(uploaded.shardIri, _shardIriA);
      expect(uploaded.newRemoteEtag, 'new-etag-1');
      expect(results[1], isA<PhaseComplete>());
      expect(backend.uploadCount, 1);
    });

    test('multiple shards all uploaded', () async {
      final backend = _SuccessUploadBackend();
      final storage = _storageWith(backend);

      final results =
          await _transform(storage.shardUpload(), <MergedShardEvent>[
        _mergedShard(_shardIriA),
        _mergedShard(_shardIriB),
        PhaseComplete(SyncInput([_shardIriA, _shardIriB]), 2),
      ]);

      final uploads = results.whereType<UploadedShard>().toList();
      expect(uploads, hasLength(2));
      expect(backend.uploadCount, 2);
    });
  });

  group('Stage 12 — file_per_resource — conflict handling', () {
    test('ConflictUploadResult yields ConflictedShard', () async {
      final storage = _storageWith(_ConflictUploadBackend());

      final results =
          await _transform(storage.shardUpload(), <MergedShardEvent>[
        _mergedShard(_shardIriA),
        PhaseComplete(SyncInput([_shardIriA]), 1),
      ]);

      expect(results, hasLength(2));
      final conflicted = results[0] as ConflictedShard;
      expect(conflicted.shardIri, _shardIriA);
      expect(conflicted.trigger, isA<MergedShard>());
      expect(results[1], isA<PhaseComplete>());
    });

    test('mixed success and conflict across shards', () async {
      final storage = _storageWith(_ConfigurableUploadBackend((req) {
        if (req.documentIri.value.contains('shardA')) {
          return SuccessUploadResult('new-etag',
              documentIri: req.documentIri, requestETag: req.ifMatch);
        }
        return ConflictUploadResult(
            documentIri: req.documentIri, requestETag: req.ifMatch);
      }));

      final results =
          await _transform(storage.shardUpload(), <MergedShardEvent>[
        _mergedShard(_shardIriA),
        _mergedShard(_shardIriB),
        PhaseComplete(SyncInput([_shardIriA, _shardIriB]), 2),
      ]);

      expect(results.whereType<UploadedShard>(), hasLength(1));
      expect(results.whereType<ConflictedShard>(), hasLength(1));
    });
  });

  group('Stage 12 — file_per_resource — needsUpload bypass', () {
    test('needsUpload=false emits UploadedShard without backend request',
        () async {
      final recording = _RecordingUploadBackend();
      final storage = _storageWith(recording);

      final results =
          await _transform(storage.shardUpload(), <MergedShardEvent>[
        _mergedShard(_shardIriA, needsUpload: false),
        PhaseComplete(SyncInput([_shardIriA]), 1),
      ]);

      expect(results, hasLength(2));
      final uploaded = results[0] as UploadedShard;
      expect(uploaded.shardIri, _shardIriA);
      expect(uploaded.newRemoteEtag, isNull);
      expect(recording.requests, isEmpty);
    });

    test('mix of needsUpload=true and false', () async {
      final recording = _RecordingUploadBackend();
      final storage = _storageWith(recording);

      final results =
          await _transform(storage.shardUpload(), <MergedShardEvent>[
        _mergedShard(_shardIriA, needsUpload: false),
        _mergedShard(_shardIriB, needsUpload: true),
        PhaseComplete(SyncInput([_shardIriA, _shardIriB]), 2),
      ]);

      expect(results.whereType<UploadedShard>(), hasLength(2));
      expect(recording.requests, hasLength(1));
    });
  });

  group('Stage 12 — file_per_resource — response order', () {
    test('results emitted in response order (no isBoundary)', () async {
      // S12 no longer uses isBoundary — response-order within a segment.
      // _ReverseOrderUploadBackend returns B before A.
      final storage = _storageWith(_ReverseOrderUploadBackend());

      final results =
          await _transform(storage.shardUpload(), <MergedShardEvent>[
        _mergedShard(_shardIriA),
        _mergedShard(_shardIriB),
        PhaseComplete(SyncInput([_shardIriA, _shardIriB]), 2),
      ]);

      final uploads = results.whereType<UploadedShard>().toList();
      expect(uploads, hasLength(2));
      // Response order: B arrives first from reversed backend
      expect(uploads[0].shardIri, _shardIriB);
      expect(uploads[1].shardIri, _shardIriA);
    });
  });

  group('Stage 12 — file_per_resource — pass-through', () {
    test('ConflictedShard from upstream passes through as Boundary', () async {
      final storage = _storageWith(_SuccessUploadBackend());

      final results =
          await _transform(storage.shardUpload(), <MergedShardEvent>[
        ConflictedShard(_shardIriA, message: 'from upstream'),
        _mergedShard(_shardIriB),
        PhaseComplete(SyncInput([_shardIriA, _shardIriB]), 2),
      ]);

      // ConflictedShard should be a boundary — emitted in order
      expect(results[0], isA<ConflictedShard>());
      expect((results[0] as ConflictedShard).shardIri, _shardIriA);
      expect(results[1], isA<UploadedShard>());
      expect(results[2], isA<PhaseComplete>());
    });

    test('ShardError passes through as Boundary', () async {
      final storage = _storageWith(_SuccessUploadBackend());

      final results =
          await _transform(storage.shardUpload(), <MergedShardEvent>[
        ShardError(_shardIriA, StateError('upstream'), StackTrace.current),
        _mergedShard(_shardIriB),
        PhaseComplete(SyncInput([_shardIriA, _shardIriB]), 2),
      ]);

      expect(results[0], isA<ShardError>());
      expect(results[1], isA<UploadedShard>());
    });
  });

  group('Stage 12 — file_per_resource — upload failure', () {
    test('upload failure emits ShardError for buffered shard', () async {
      final storage = _storageWith(_FailingUploadBackend());

      final results =
          await _transform(storage.shardUpload(), <MergedShardEvent>[
        _mergedShard(_shardIriA),
        PhaseComplete(SyncInput([_shardIriA]), 1),
      ]);

      final errors = results.whereType<ShardError>().toList();
      expect(errors, hasLength(1));
      expect(errors.first.shardIri, equals(_shardIriA));
    });

    test('subsequent shards after backend failure get ShardError', () async {
      final storage = _storageWith(_FailingUploadBackend());

      final results =
          await _transform(storage.shardUpload(), <MergedShardEvent>[
        _mergedShard(_shardIriA),
        _mergedShard(_shardIriB),
        PhaseComplete(SyncInput([_shardIriA, _shardIriB]), 2),
      ]);

      final errors = results.whereType<ShardError>().toList();
      expect(errors, hasLength(2));
      expect(results.last, isA<PhaseComplete>());
    });
  });

  group('Stage 12 — file_per_resource — PhaseError', () {
    test('PhaseError clears buffer and passes through', () async {
      final storage = _storageWith(_FailingUploadBackend());

      final results =
          await _transform(storage.shardUpload(), <MergedShardEvent>[
        _mergedShard(_shardIriA),
        PhaseError(StateError('test'), StackTrace.current, stage: 'S11c'),
      ]);

      expect(results, hasLength(2));
      expect(results[0], isA<ShardError>());
      expect(results[1], isA<PhaseError>());
    });
  });

  group('Stage 12 — file_per_resource — request identity', () {
    test('ifMatch carries newEtag from MergedShard', () async {
      final recording = _RecordingUploadBackend();
      final storage = _storageWith(recording);

      await _transform(storage.shardUpload(), <MergedShardEvent>[
        _mergedShard(_shardIriA, newEtag: 'my-etag'),
        PhaseComplete(SyncInput([_shardIriA]), 1),
      ]);

      expect(recording.requests, hasLength(1));
      expect(recording.requests.first.ifMatch, 'my-etag');
      // Fragment stripped
      expect(recording.requests.first.documentIri,
          IriTerm('tag:test,2025:shardA'));
    });
  });
}
