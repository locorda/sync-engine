/// Tests for Stage 6 (Resource Fetch) — file_per_resource layout.
///
/// FPR does actual HTTP downloads for resource graphs. Tests verify:
/// - Successful fetch: 200 with graph, 304 notModified, 404 not found
/// - needsRemoteFetch=false bypass (remoteShardUnchanged → PassThrough)
/// - Download failure → [ResourceError] for buffered candidates
/// - [ShardError] passes through unchanged
/// - [ResourceError] passes through unchanged
/// - [PhaseError] passes through
/// - Response-order: results emitted as they arrive within a segment
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

final _shardIriA = IriTerm('tag:test,2025:shardA#shard');
final _typeIri = IriTerm('tag:test,2025:Type');
final _resIri1 = IriTerm('tag:test,2025:res1#it');
final _resIri2 = IriTerm('tag:test,2025:res2#it');

LoadedCandidate _loaded(
  IriTerm resIri, {
  SyncDirection direction = SyncDirection.conflictCandidate,
  String? storedRemoteEtag,
}) =>
    LoadedCandidate(
      SyncCandidate(resIri, 'storage-1', direction, _typeIri),
      storedRemoteEtag: storedRemoteEtag,
    );

RawContent _emptyRawContent() =>
    BinaryContent(Uint8List(0), contentType: _contentType);

// ---------------------------------------------------------------------------
// Stubs
// ---------------------------------------------------------------------------

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
}

class _ReverseOrderBackend implements RemoteSyncBackend {
  @override
  Stream<RemoteDownloadResult<RawContent>> download(
      Stream<RemoteDownloadRequest> requests) async* {
    final collected = await requests.toList();
    for (final request in collected.reversed) {
      yield RemoteDownloadResult(
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
}

/// Backend that records requests — verifies no requests sent for bypass.
class _RecordingBackend implements RemoteSyncBackend {
  final requests = <RemoteDownloadRequest>[];
  final RemoteDownloadResult<RawContent> Function(RemoteDownloadRequest)
      _handler;

  _RecordingBackend(this._handler);

  @override
  Stream<RemoteDownloadResult<RawContent>> download(
      Stream<RemoteDownloadRequest> reqs) async* {
    await for (final req in reqs) {
      requests.add(req);
      yield _handler(req);
    }
  }

  @override
  Stream<RemoteUploadResult> upload(
          Stream<RemoteUploadRequest<RawContent>> requests) =>
      const Stream.empty();
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
  group('Stage 6 — file_per_resource — successful fetch', () {
    test('200 with graph yields FetchedCandidate with remoteSource', () async {
      final storage = _storageWith(_ConfigurableBackend((req) {
        return RemoteDownloadResult(
          documentIri: req.documentIri,
          requestETag: req.ifNoneMatch,
          graph: _emptyRawContent(),
          etag: 'new-etag',
        );
      }));

      final results = await _transform(storage.resourceFetch(), [
        _loaded(_resIri1),
        ShardComplete(_shardIriA, null),
      ]);

      expect(results, hasLength(2));
      final fetched = results[0] as FetchedCandidate;
      expect(fetched.remoteSource, isNotNull);
      expect(fetched.remoteEtag, 'new-etag');
      expect(results[1], isA<ShardComplete>());
    });

    test('304 notModified yields FetchedCandidate with etag from response',
        () async {
      final storage = _storageWith(
          _ConfigurableBackend((req) => RemoteDownloadResult.notModified(
                documentIri: req.documentIri,
                requestETag: req.ifNoneMatch,
                etag: 'stored-etag',
              )));

      final results = await _transform(storage.resourceFetch(), [
        _loaded(_resIri1, storedRemoteEtag: 'stored-etag'),
        ShardComplete(_shardIriA, null),
      ]);

      expect(results, hasLength(2));
      final fetched = results[0] as FetchedCandidate;
      expect(fetched.remoteSource, isNull);
      expect(fetched.remoteEtag, 'stored-etag');
    });

    test('404 yields FetchedCandidate with null remoteSource and null etag',
        () async {
      final storage = _storageWith(_ConfigurableBackend((req) {
        return RemoteDownloadResult(
          documentIri: req.documentIri,
          requestETag: req.ifNoneMatch,
          graph: null,
          etag: null,
        );
      }));

      final results = await _transform(storage.resourceFetch(), [
        _loaded(_resIri1),
        ShardComplete(_shardIriA, null),
      ]);

      expect(results, hasLength(2));
      final fetched = results[0] as FetchedCandidate;
      expect(fetched.remoteSource, isNull);
      expect(fetched.remoteEtag, isNull,
          reason: '404 should not carry an ETag');
    });
  });

  group('Stage 6 — file_per_resource — needsRemoteFetch bypass', () {
    test('remoteShardUnchanged bypasses backend, preserves storedRemoteEtag',
        () async {
      final recording = _RecordingBackend((req) {
        return RemoteDownloadResult(
          documentIri: req.documentIri,
          requestETag: req.ifNoneMatch,
          graph: _emptyRawContent(),
          etag: 'new-etag',
        );
      });
      final storage = _storageWith(recording);

      final results = await _transform(storage.resourceFetch(), [
        _loaded(_resIri1,
            direction: SyncDirection.remoteShardUnchanged,
            storedRemoteEtag: 'old-etag'),
        ShardComplete(_shardIriA, null),
      ]);

      expect(results, hasLength(2));
      final fetched = results[0] as FetchedCandidate;
      expect(fetched.remoteSource, isNull);
      expect(fetched.remoteEtag, 'old-etag');
      // No request sent to backend
      expect(recording.requests, isEmpty);
    });

    test('conflictCandidate sends request to backend', () async {
      final recording = _RecordingBackend((req) {
        return RemoteDownloadResult(
          documentIri: req.documentIri,
          requestETag: req.ifNoneMatch,
          graph: _emptyRawContent(),
          etag: 'new-etag',
        );
      });
      final storage = _storageWith(recording);

      await _transform(storage.resourceFetch(), [
        _loaded(_resIri1, direction: SyncDirection.conflictCandidate),
        ShardComplete(_shardIriA, null),
      ]);

      expect(recording.requests, hasLength(1));
    });

    test('notInRemoteShard sends request to backend', () async {
      final recording = _RecordingBackend((req) {
        return RemoteDownloadResult(
          documentIri: req.documentIri,
          requestETag: req.ifNoneMatch,
          graph: null,
          etag: null,
        );
      });
      final storage = _storageWith(recording);

      await _transform(storage.resourceFetch(), [
        _loaded(_resIri1, direction: SyncDirection.notInRemoteShard),
        ShardComplete(_shardIriA, null),
      ]);

      expect(recording.requests, hasLength(1));
    });

    test('shardGone sends request to backend', () async {
      final recording = _RecordingBackend((req) {
        return RemoteDownloadResult(
          documentIri: req.documentIri,
          requestETag: req.ifNoneMatch,
          graph: null,
          etag: null,
        );
      });
      final storage = _storageWith(recording);

      await _transform(storage.resourceFetch(), [
        _loaded(_resIri1, direction: SyncDirection.shardGone),
        ShardComplete(_shardIriA, null),
      ]);

      expect(recording.requests, hasLength(1));
    });
  });

  group('Stage 6 — file_per_resource — response order', () {
    test('results emitted in response order within a shard segment', () async {
      final storage = _storageWith(_ReverseOrderBackend());

      final results = await _transform(storage.resourceFetch(), [
        _loaded(_resIri1),
        _loaded(_resIri2),
        ShardComplete(_shardIriA, null),
      ]);

      // Backend reverses: res2 arrives first
      expect(results, hasLength(3));
      final f1 = results[0] as FetchedCandidate;
      final f2 = results[1] as FetchedCandidate;
      expect(f1.loaded.candidate.resourceIri, _resIri2);
      expect(f2.loaded.candidate.resourceIri, _resIri1);
      expect(results[2], isA<ShardComplete>());
    });

    test('bypass candidates emitted before backend responses', () async {
      // Mix of bypass and fetch candidates
      final storage = _storageWith(_ConfigurableBackend((req) {
        return RemoteDownloadResult(
          documentIri: req.documentIri,
          requestETag: req.ifNoneMatch,
          graph: _emptyRawContent(),
          etag: 'new-etag',
        );
      }));

      final results = await _transform(storage.resourceFetch(), [
        _loaded(_resIri1,
            direction: SyncDirection.remoteShardUnchanged,
            storedRemoteEtag: 'etag-1'),
        _loaded(_resIri2, direction: SyncDirection.conflictCandidate),
        ShardComplete(_shardIriA, null),
      ]);

      expect(results, hasLength(3));
      // bypass emitted immediately, then fetched candidate, then boundary
      final f1 = results[0] as FetchedCandidate;
      final f2 = results[1] as FetchedCandidate;
      expect(f1.loaded.candidate.resourceIri, _resIri1);
      expect(f2.loaded.candidate.resourceIri, _resIri2);
    });
  });

  group('Stage 6 — file_per_resource — download failure', () {
    test('download failure emits ResourceError for buffered candidates',
        () async {
      final storage = _storageWith(_FailingBackend());

      final loaded = _loaded(_resIri1);

      final results = await _transform(storage.resourceFetch(), [
        loaded,
        ShardComplete(_shardIriA, null),
      ]);

      final errors = results.whereType<ResourceError>().toList();
      expect(errors, hasLength(1));
      expect(errors.first.resourceIri, equals(_resIri1));
    });

    test('multiple candidates all get ResourceError on failure', () async {
      final storage = _storageWith(_FailingBackend());

      final results = await _transform(storage.resourceFetch(), [
        _loaded(_resIri1),
        _loaded(_resIri2),
        ShardComplete(_shardIriA, null),
      ]);

      final errors = results.whereType<ResourceError>().toList();
      expect(errors, hasLength(2));
      expect(results.last, isA<ShardComplete>());
    });
  });

  group('Stage 6 — file_per_resource — pass-through', () {
    test('ShardError passes through S06 unchanged', () async {
      final storage = _storageWith(_FailingBackend());

      final results =
          await _transform<LoadedCandidateEvent, FetchedCandidateEvent>(
              storage.resourceFetch(), [
        ShardError(_shardIriA, StateError('upstream'), StackTrace.current),
        PhaseComplete(SyncInput([_shardIriA]), 1),
      ]);

      expect(results.whereType<ShardError>(), hasLength(1));
      expect(results.whereType<PhaseComplete>(), hasLength(1));
    });

    test('ResourceError passes through S06 unchanged', () async {
      final storage = _storageWith(_FailingBackend());

      final results =
          await _transform<LoadedCandidateEvent, FetchedCandidateEvent>(
              storage.resourceFetch(), [
        ResourceError(_resIri1, StateError('upstream'), StackTrace.current),
        ShardComplete(_shardIriA, null),
      ]);

      expect(results.whereType<ResourceError>(), hasLength(1));
    });

    test('PhaseError passes through', () async {
      final storage = _storageWith(_FailingBackend());

      final results =
          await _transform<LoadedCandidateEvent, FetchedCandidateEvent>(
              storage.resourceFetch(), [
        PhaseError(StateError('test'), StackTrace.current, stage: 'S05'),
      ]);

      expect(results, hasLength(1));
      expect(results[0], isA<PhaseError>());
    });
  });
}
