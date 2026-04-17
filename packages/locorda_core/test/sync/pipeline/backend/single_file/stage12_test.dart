import 'package:locorda_core/src/sync/pipeline/pipeperf.dart';

/// Tests for Stage 12 (Shard Upload) — single_file layout.
///
/// SF defers actual I/O to finalizeSync. shardUpload only accumulates.
/// Verifies:
/// - shardUpload does not throw even with failing backend
/// - finalizeSync swallows upload error (non-fatal, logged as warning)
/// - [PhaseError] passes through
import 'dart:async';
import 'dart:typed_data';

import 'package:locorda_core/src/storage/remote_storage.dart';
import 'package:locorda_core/src/sync/pipeline/backend/remote_sync_backend.dart';
import 'package:locorda_core/src/sync/pipeline/backend/single_file_pipeline.dart';
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
  group('Stage 12 — single_file — upload deferred', () {
    test('shardUpload does not throw (upload deferred to finalizeSync)',
        () async {
      final storage = SingleFileRemoteSyncStorage(
        _FailingUploadBackend(),
        rdfCore: _rdfCore,
        contentType: _contentType,
        storageAccess: _StubStorageAccess(),
      );

      final results = await _transform(storage.shardUpload(), [
        _mergedShard(_shardIriA),
        PhaseComplete(SyncInput([_shardIriA]), 1),
      ]);

      expect(results.whereType<ShardError>(), isEmpty);
      expect(results.whereType<UploadedShard>(), hasLength(1));
    });

    test('finalizeSync swallows upload error (non-fatal)', () async {
      final storage = SingleFileRemoteSyncStorage(
        _FailingUploadBackend(),
        rdfCore: _rdfCore,
        contentType: _contentType,
        storageAccess: _StubStorageAccess(),
      );

      await expectLater(
        storage.finalizeSync(const SyncFinalizationSuccess()),
        completes,
      );
    });
  });

  group('Stage 12 — single_file — PhaseError', () {
    test('PhaseError passes through', () async {
      final storage = SingleFileRemoteSyncStorage(
        _FailingUploadBackend(),
        rdfCore: _rdfCore,
        contentType: _contentType,
        storageAccess: _StubStorageAccess(),
      );

      final results = await _transform(storage.shardUpload(), [
        _mergedShard(_shardIriA),
        PhaseError(StateError('test'), StackTrace.current, stage: 'S11c'),
      ]);

      // MergedShard is emitted immediately as UploadedShard (upload is
      // deferred to finalizeSync), then PhaseError clears accumulated
      // graphs and passes through.
      expect(results, hasLength(2));
      expect(results[0], isA<UploadedShard>());
      expect(results[1], isA<PhaseError>());
    });
  });
}
