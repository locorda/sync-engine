import 'package:locorda_core/src/sync/pipeline/pipeperf.dart';

/// Tests for Stage 2 (Shard Fetch) — file_per_resource layout.
///
/// Verifies:
/// - Successful downloads: 200 (content), 304 (notModified), 404/gone, 404/notFound
/// - Download failure → [ShardError] for all buffered shards
/// - [PhaseError] clears buffer and passes through
/// - Response-order: results emitted as they arrive, not input order
/// - Cross-shard batching: multiple shards in-flight simultaneously
import 'dart:async';
import 'dart:typed_data';

import 'package:locorda_core/src/index/index_config_base.dart';
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

final _shardIriA = IriTerm('tag:test,2025:shardA#shard');
final _shardIriB = IriTerm('tag:test,2025:shardB#shard');
final _shardIriC = IriTerm('tag:test,2025:shardC#shard');
final _typeIri = IriTerm('tag:test,2025:Type');
final _indexIri = IriTerm('tag:test,2025:index');

ShardRef _shardRef(IriTerm shardIri, {String? storedEtag}) => ShardRef(
      _indexIri,
      shardIri,
      null,
      RootResourceFetchPolicy.prefetch,
      _typeIri,
      storedEtag: storedEtag,
    );

RawContent _emptyRawContent() =>
    BinaryContent(Uint8List(0), contentType: _contentType);

// ---------------------------------------------------------------------------
// Stubs
// ---------------------------------------------------------------------------

/// Backend that responds to each request using a configurable function.
class _ConfigurableBackend implements RemoteSyncBackend {
  final RemoteDownloadResult<RawContent> Function(RemoteDownloadRequest)
      _handler;

  _ConfigurableBackend(this._handler);

  @override
  Stream<RemoteDownloadResult<RawContent>> download(
      Stream<RemoteDownloadRequest> requests) async* {
    await for (final request in requests) {
      yield _handler(request);
    }
  }

  @override
  Stream<RemoteUploadResult> upload(
          Stream<RemoteUploadRequest<RawContent>> requests) =>
      const Stream.empty();

  @override
  Future<void> finalize(SyncFinalizationState state,
      {PipeperfCollector? perf}) async {}
}

/// Backend that reverses the order of responses to test response-order.
class _ReverseOrderBackend implements RemoteSyncBackend {
  @override
  Stream<RemoteDownloadResult<RawContent>> download(
      Stream<RemoteDownloadRequest> requests) async* {
    final collected = await requests.toList();
    for (final request in collected.reversed) {
      yield SuccessDownloadResult<RawContent>(
        documentIri: request.documentIri,
        requestETag: request.ifNoneMatch,
        graph: _emptyRawContent(),
        etag: 'etag-${request.documentIri.value}',
      );
    }
  }

  @override
  Stream<RemoteUploadResult> upload(
          Stream<RemoteUploadRequest<RawContent>> requests) =>
      const Stream.empty();

  @override
  Future<void> finalize(SyncFinalizationState state,
      {PipeperfCollector? perf}) async {}
}

class _FailingBackend implements RemoteSyncBackend {
  @override
  Stream<RemoteDownloadResult<RawContent>> download(
      Stream<RemoteDownloadRequest> requests) {
    return Stream.error(StateError('download failure'));
  }

  @override
  Stream<RemoteUploadResult> upload(
          Stream<RemoteUploadRequest<RawContent>> requests) =>
      const Stream.empty();

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
  group('Stage 2 — file_per_resource — successful downloads', () {
    test('200 with content yields ShardContent with graph and etag', () async {
      final storage = _storageWith(_ConfigurableBackend((req) {
        return SuccessDownloadResult<RawContent>(
          documentIri: req.documentIri,
          requestETag: req.ifNoneMatch,
          graph: _emptyRawContent(),
          etag: 'new-etag',
        );
      }));

      final results = await _transform(storage.shardFetch(), [
        _shardRef(_shardIriA),
        PhaseComplete(SyncInput([_shardIriA]), 1),
      ]);

      expect(results, hasLength(2));
      final content = results[0] as ShardContent;
      expect(content.shardIri, _shardIriA);
      expect(content.newEtag, 'new-etag');
      expect(content.source, isNotNull);
      expect(results[1], isA<PhaseComplete>());
    });

    test('304 notModified yields ShardNotModified', () async {
      final storage = _storageWith(
          _ConfigurableBackend((req) => NotModifiedDownloadResult<RawContent>(
                documentIri: req.documentIri,
                requestETag: req.ifNoneMatch,
                etag: 'stored-etag',
              )));

      final results = await _transform(storage.shardFetch(), [
        _shardRef(_shardIriA, storedEtag: 'stored-etag'),
        PhaseComplete(SyncInput([_shardIriA]), 1),
      ]);

      expect(results, hasLength(2));
      final notMod = results[0] as ShardNotModified;
      expect(notMod.shardIri, _shardIriA);
      expect(notMod.storedEtag, 'stored-etag');
    });

    test('404 with stored etag yields ShardGone', () async {
      final storage = _storageWith(_ConfigurableBackend((req) {
        return NotFoundDownloadResult<RawContent>(
          documentIri: req.documentIri,
          requestETag: req.ifNoneMatch,
        );
      }));

      final results = await _transform(storage.shardFetch(), [
        _shardRef(_shardIriA, storedEtag: 'old-etag'),
        PhaseComplete(SyncInput([_shardIriA]), 1),
      ]);

      expect(results, hasLength(2));
      expect(results[0], isA<ShardGone>());
      expect((results[0] as ShardGone).shardIri, _shardIriA);
    });

    test('404 without stored etag yields ShardNotFound', () async {
      final storage = _storageWith(_ConfigurableBackend((req) {
        return NotFoundDownloadResult<RawContent>(
          documentIri: req.documentIri,
          requestETag: req.ifNoneMatch,
        );
      }));

      final results = await _transform(storage.shardFetch(), [
        _shardRef(_shardIriA),
        PhaseComplete(SyncInput([_shardIriA]), 1),
      ]);

      expect(results, hasLength(2));
      expect(results[0], isA<ShardNotFound>());
    });

    test('multiple shards with mixed responses', () async {
      final storage = _storageWith(_ConfigurableBackend((req) {
        if (req.documentIri.value.contains('shardA')) {
          return SuccessDownloadResult<RawContent>(
            documentIri: req.documentIri,
            requestETag: req.ifNoneMatch,
            graph: _emptyRawContent(),
            etag: 'etag-a',
          );
        }
        return NotModifiedDownloadResult<RawContent>(
          documentIri: req.documentIri,
          requestETag: req.ifNoneMatch,
          etag: 'etag-b',
        );
      }));

      final results = await _transform(storage.shardFetch(), [
        _shardRef(_shardIriA),
        _shardRef(_shardIriB, storedEtag: 'etag-b'),
        PhaseComplete(SyncInput([_shardIriA, _shardIriB]), 2),
      ]);

      expect(results, hasLength(3));
      expect(results[0], isA<ShardContent>());
      expect(results[1], isA<ShardNotModified>());
      expect(results[2], isA<PhaseComplete>());
    });
  });

  group('Stage 2 — file_per_resource — response order', () {
    test('results emitted in response order, not input order', () async {
      final storage = _storageWith(_ReverseOrderBackend());

      final results = await _transform(storage.shardFetch(), [
        _shardRef(_shardIriA),
        _shardRef(_shardIriB),
        PhaseComplete(SyncInput([_shardIriA, _shardIriB]), 2),
      ]);

      // Backend reverses: B response arrives first, A second
      expect(results, hasLength(3));
      expect((results[0] as ShardContent).shardIri, _shardIriB);
      expect((results[1] as ShardContent).shardIri, _shardIriA);
      expect(results[2], isA<PhaseComplete>());
    });

    test('PhaseComplete waits for all responses before emitting', () async {
      final storage = _storageWith(_ReverseOrderBackend());

      final results = await _transform(storage.shardFetch(), [
        _shardRef(_shardIriA),
        _shardRef(_shardIriB),
        _shardRef(_shardIriC),
        PhaseComplete(SyncInput([_shardIriA, _shardIriB, _shardIriC]), 3),
      ]);

      // All 3 shards emitted before PhaseComplete
      expect(results, hasLength(4));
      expect(results[3], isA<PhaseComplete>());
      expect(results.take(3).every((e) => e is ShardContent), isTrue);
    });
  });

  group('Stage 2 — file_per_resource — download failure', () {
    test('download failure emits ShardError for all buffered shards', () async {
      final storage = _storageWith(_FailingBackend());

      final results = await _transform(storage.shardFetch(), [
        _shardRef(_shardIriA),
        _shardRef(_shardIriB),
        PhaseComplete(SyncInput([_shardIriA, _shardIriB]), 2),
      ]);

      final errors = results.whereType<ShardError>().toList();
      expect(errors, hasLength(2));
      expect(results.whereType<PhaseComplete>(), hasLength(1));
    });

    test('subsequent shards after backend failure get ShardError', () async {
      final storage = _storageWith(_FailingBackend());

      final results = await _transform(storage.shardFetch(), [
        _shardRef(_shardIriA),
        _shardRef(_shardIriB),
        _shardRef(_shardIriC),
        PhaseComplete(SyncInput([_shardIriA, _shardIriB, _shardIriC]), 3),
      ]);

      final errors = results.whereType<ShardError>().toList();
      expect(errors, hasLength(3));
      expect(results.last, isA<PhaseComplete>());
    });
  });

  group('Stage 2 — file_per_resource — PhaseError', () {
    test('PhaseError clears buffer and passes through', () async {
      final storage = _storageWith(_FailingBackend());

      final results = await _transform(storage.shardFetch(), [
        _shardRef(_shardIriA),
        PhaseError(StateError('test'), StackTrace.current, stage: 'S01'),
      ]);

      expect(results, hasLength(2));
      expect(results[0], isA<ShardError>());
      expect(results[1], isA<PhaseError>());
    });
  });

  group('Stage 2 — file_per_resource — request identity', () {
    test('ifNoneMatch carries storedEtag from ShardRef', () async {
      RemoteDownloadRequest? captured;
      final storage = _storageWith(_ConfigurableBackend((req) {
        captured = req;
        return SuccessDownloadResult<RawContent>(
          documentIri: req.documentIri,
          requestETag: req.ifNoneMatch,
          graph: _emptyRawContent(),
          etag: 'new-etag',
        );
      }));

      await _transform(storage.shardFetch(), [
        _shardRef(_shardIriA, storedEtag: 'my-etag'),
        PhaseComplete(SyncInput([_shardIriA]), 1),
      ]);

      expect(captured, isNotNull);
      expect(captured!.ifNoneMatch, 'my-etag');
      // Fragment stripped for document IRI
      expect(captured!.documentIri, IriTerm('tag:test,2025:shardA'));
    });
  });
}
