/// Tests for Stage 2 (Shard Fetch) — single_file layout.
///
/// Verifies:
/// - Download failure → [ShardError] per shard
/// - Second shard after download failure → [ShardNotFound] (download flag set)
/// - [PhaseError] passes through
import 'dart:async';

import 'package:locorda_core/src/index/index_config_base.dart';
import 'package:locorda_core/src/storage/remote_storage.dart';
import 'package:locorda_core/src/sync/pipeline/backend/remote_sync_backend.dart';
import 'package:locorda_core/src/sync/pipeline/backend/single_file_pipeline.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_support.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Test data
// ---------------------------------------------------------------------------

final _rdfCore = RdfCore.withStandardCodecs();
final _contentType = trig.primaryMimeType;

final _shardIriA = IriTerm('tag:test,2025:shardA#shard');
final _shardIriB = IriTerm('tag:test,2025:shardB#shard');
final _typeIri = IriTerm('tag:test,2025:Type');
final _indexIri = IriTerm('tag:test,2025:index');
final _emptyGraph = RdfGraph();

ShardRef _shardRef(IriTerm shardIri) => ShardRef(
      _indexIri,
      shardIri,
      null,
      RootResourceFetchPolicy.prefetch,
      _typeIri,
    );

// ---------------------------------------------------------------------------
// Stubs
// ---------------------------------------------------------------------------

class _FailingDownloadBackend implements RemoteSyncBackend {
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

class _StubStorageAccess implements BackendStorageAccess {
  @override
  Future<Map<IriTerm, RdfGraph?>> loadResourceGraphs(
          Iterable<IriTerm> documentIris) async =>
      {for (final iri in documentIris) iri: _emptyGraph};

  @override
  Future<Map<IriTerm, String?>> getRemoteETags(
          Iterable<IriTerm> documentIris) async =>
      {for (final iri in documentIris) iri: null};

  @override
  Future<void> setRemoteETags(Map<IriTerm, String> etagsByDocument) async {}
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('Stage 2 — single_file — download failure', () {
    test('download failure emits ShardError per shard', () async {
      final storage = SingleFileRemoteSyncStorage(
        _FailingDownloadBackend(),
        rdfCore: _rdfCore,
        contentType: _contentType,
        storageAccess: _StubStorageAccess(),
      );

      final results = await _transform(storage.shardFetch(), [
        _shardRef(_shardIriA),
        PhaseComplete(SyncInput([_shardIriA]), 1),
      ]);

      final errors = results.whereType<ShardError>().toList();
      expect(errors, hasLength(1));
      expect(errors.first.shardIri, equals(_shardIriA));
    });

    test('second shard sees ShardNotFound (download flag already set)',
        () async {
      final storage = SingleFileRemoteSyncStorage(
        _FailingDownloadBackend(),
        rdfCore: _rdfCore,
        contentType: _contentType,
        storageAccess: _StubStorageAccess(),
      );

      final results = await _transform(storage.shardFetch(), [
        _shardRef(_shardIriA),
        _shardRef(_shardIriB),
        PhaseComplete(SyncInput([_shardIriA, _shardIriB]), 2),
      ]);

      final errors = results.whereType<ShardError>().toList();
      expect(errors, hasLength(1));
      expect(errors.first.shardIri, equals(_shardIriA));

      final notFound = results.whereType<ShardNotFound>().toList();
      expect(notFound, hasLength(1));
      expect(notFound.first.shardIri, equals(_shardIriB));
    });
  });

  group('Stage 2 — single_file — PhaseError', () {
    test('PhaseError passes through', () async {
      final storage = SingleFileRemoteSyncStorage(
        _FailingDownloadBackend(),
        rdfCore: _rdfCore,
        contentType: _contentType,
        storageAccess: _StubStorageAccess(),
      );

      final results = await _transform(storage.shardFetch(), [
        PhaseError(StateError('test'), StackTrace.current, stage: 'S01'),
      ]);

      expect(results, hasLength(1));
      expect(results[0], isA<PhaseError>());
    });
  });
}
