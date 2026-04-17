import 'package:locorda_core/src/sync/pipeline/pipeperf.dart';

/// Tests for Stage 12 (Shard Upload) — shard_dataset layout.
///
/// Verifies:
/// - Upload failure → [ShardError] for buffered shard
/// - [PhaseError] clears buffer and passes through
import 'dart:async';
import 'dart:typed_data';

import 'package:locorda_core/src/storage/remote_storage.dart';
import 'package:locorda_core/src/sync/pipeline/backend/remote_sync_backend.dart';
import 'package:locorda_core/src/sync/pipeline/backend/shard_dataset_pipeline.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_support.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:locorda_rdf_jelly/jelly.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Test data
// ---------------------------------------------------------------------------

final _rdfCore = RdfCore.withStandardCodecs();
final _contentType = trig.primaryMimeType;

final _shardIriA = IriTerm('tag:test,2025:shardA#shard');
final _emptyGraph = RdfGraph();

MergedShard _mergedShard(IriTerm shardIri) => MergedShard(
      shardIri,
      DecodedGraphSource(
        _emptyGraph,
        originalSource:
            BinaryGraphSource(Uint8List(0), contentType: jellyMimeType),
      ),
      BinaryGraphSource(Uint8List(0), contentType: jellyMimeType),
      needsUpload: true,
      ourPhysicalClock: 1,
    );

// ---------------------------------------------------------------------------
// Stubs
// ---------------------------------------------------------------------------

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
  group('Stage 12 — shard_dataset — upload failure', () {
    test('upload failure emits ShardError for buffered shard', () async {
      final storage = ShardDatasetRemoteSyncStorage(
        _FailingUploadBackend(),
        rdfCore: _rdfCore,
        contentType: _contentType,
        storageAccess: _StubStorageAccess(),
      );

      final results = await _transform(storage.shardUpload(), [
        _mergedShard(_shardIriA),
        PhaseComplete(SyncInput([_shardIriA]), 1),
      ]);

      final errors = results.whereType<ShardError>().toList();
      expect(errors, hasLength(1));
      expect(errors.first.shardIri, equals(_shardIriA));
    });
  });

  group('Stage 12 — shard_dataset — PhaseError', () {
    test('PhaseError clears buffer and passes through', () async {
      final storage = ShardDatasetRemoteSyncStorage(
        _FailingUploadBackend(),
        rdfCore: _rdfCore,
        contentType: _contentType,
        storageAccess: _StubStorageAccess(),
      );

      final results = await _transform(storage.shardUpload(), [
        _mergedShard(_shardIriA),
        PhaseError(StateError('test'), StackTrace.current, stage: 'S11c'),
      ]);

      // MergedShard was already dispatched to the failing backend,
      // so errorRemaining produces a ShardError before PhaseError.
      expect(results, hasLength(2));
      expect(results[0], isA<ShardError>());
      expect(results[1], isA<PhaseError>());
    });
  });
}
