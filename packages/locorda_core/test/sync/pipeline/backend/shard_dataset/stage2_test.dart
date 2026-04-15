import 'package:locorda_core/src/sync/pipeline/pipeperf.dart';
/// Tests for Stage 2 (Shard Fetch) — shard_dataset layout.
///
/// Verifies:
/// - Download failure → [ShardError] for all buffered shards
/// - [PhaseError] clears buffer and passes through
import 'dart:async';

import 'package:locorda_core/src/index/index_config_base.dart';
import 'package:locorda_core/src/storage/remote_storage.dart';
import 'package:locorda_core/src/sync/pipeline/backend/remote_sync_backend.dart';
import 'package:locorda_core/src/sync/pipeline/backend/shard_dataset_pipeline.dart';
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

  @override
  Future<void> finalize(SyncFinalizationState state, {PipeperfCollector? perf}) async {}
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
  group('Stage 2 — shard_dataset — download failure', () {
    test('download failure emits ShardError for all buffered shards', () async {
      final storage = ShardDatasetRemoteSyncStorage(
        _FailingDownloadBackend(),
        rdfCore: _rdfCore,
        contentType: _contentType,
        storageAccess: _StubStorageAccess(),
      );

      final syncInput = SyncInput([_shardIriA, _shardIriB]);
      final results = await _transform(storage.shardFetch(), [
        _shardRef(_shardIriA),
        _shardRef(_shardIriB),
        PhaseComplete(syncInput, 2),
      ]);

      final errors = results.whereType<ShardError>().toList();
      expect(errors, hasLength(2));
      expect(errors.map((e) => e.shardIri).toSet(),
          equals({_shardIriA, _shardIriB}));
      expect(results.whereType<PhaseComplete>(), hasLength(1));
    });
  });

  group('Stage 2 — shard_dataset — PhaseError', () {
    test('PhaseError clears buffer and passes through', () async {
      final storage = ShardDatasetRemoteSyncStorage(
        _FailingDownloadBackend(),
        rdfCore: _rdfCore,
        contentType: _contentType,
        storageAccess: _StubStorageAccess(),
      );

      final results = await _transform(storage.shardFetch(), [
        _shardRef(_shardIriA),
        PhaseError(StateError('test'), StackTrace.current, stage: 'S01'),
      ]);

      // ShardRef was already dispatched to the failing backend,
      // so errorRemaining produces a ShardError before PhaseError.
      expect(results, hasLength(2));
      expect(results[0], isA<ShardError>());
      expect(results[1], isA<PhaseError>());
    });
  });
}
