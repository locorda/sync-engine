import 'package:locorda_core/src/sync/pipeline/pipeperf.dart';
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

/// Spy backend that tracks whether upload() was called.
class _SpyBackend implements RemoteSyncBackend {
  int uploadCallCount = 0;
  int downloadCallCount = 0;
  int finalizeCallCount = 0;
  SyncFinalizationState? finalizedState;
  Object? uploadError;
  StackTrace uploadStackTrace = StackTrace.empty;

  @override
  Stream<RemoteDownloadResult<RawContent>> download(
      Stream<RemoteDownloadRequest> requests) async* {
    downloadCallCount++;
    await for (final request in requests) {
      yield NotFoundDownloadResult<RawContent>(
        documentIri: request.documentIri,
        requestETag: request.ifNoneMatch,
      );
    }
  }

  @override
  Stream<RemoteUploadResult> upload(
      Stream<RemoteUploadRequest<RawContent>> requests) async* {
    uploadCallCount++;
    await for (final request in requests) {
      if (uploadError != null) {
        yield ErrorUploadResult(
          documentIri: request.documentIri,
          requestETag: request.ifMatch,
          error: uploadError!,
          stackTrace: uploadStackTrace,
        );
        continue;
      }
      yield SuccessUploadResult(
        'new-etag',
        documentIri: request.documentIri,
        requestETag: request.ifMatch,
      );
    }
  }

  @override
  Future<void> finalize(SyncFinalizationState state,
      {PipeperfCollector? perf}) async {
    finalizeCallCount++;
    finalizedState = state;
  }
}

/// Stub backend storage access that returns empty results.
class _StubBackendStorageAccess implements BackendStorageAccess {
  @override
  Future<Map<IriTerm, RdfGraph?>> loadResourceGraphs(
          Iterable<IriTerm> documentIris) async =>
      {for (final iri in documentIris) iri: null};

  @override
  Future<Map<IriTerm, String?>> getRemoteETags(
          Iterable<IriTerm> documentIris) async =>
      {for (final iri in documentIris) iri: null};

  @override
  Future<void> setRemoteETags(Map<IriTerm, String> etagsByDocument) async {}
}

/// Helper to create a minimal [MergedShard] for testing.
MergedShard _mergedShard(IriTerm shardIri, RdfGraph graph) => MergedShard(
      shardIri,
      DecodedGraphSource(graph),
      BinaryGraphSource(Uint8List(0), contentType: jellyMimeType),
      needsUpload: true,
      ourPhysicalClock: 0,
    );

void main() {
  late _SpyBackend spyBackend;
  late SingleFileRemoteSyncStorage storage;
  final rdfCore = RdfCore.withStandardCodecs();
  final contentType = trig.primaryMimeType; //'text/trig';

  final shardIri = IriTerm('tag:locorda.org,2025:test-shard#shard');
  final shardDocIri = IriTerm('tag:locorda.org,2025:test-shard');
  final shardGraph = RdfGraph.fromTriples([
    Triple(shardDocIri, IriTerm('http://xmlns.com/foaf/0.1/primaryTopic'),
        shardIri),
  ]);

  setUp(() {
    spyBackend = _SpyBackend();
    storage = SingleFileRemoteSyncStorage(
      spyBackend,
      rdfCore: rdfCore,
      contentType: contentType,
      storageAccess: _StubBackendStorageAccess(),
    );
  });

  /// Push a [MergedShard] + [PhaseComplete] through [storage.shardUpload]
  /// to populate the internal accumulators.
  Future<void> populateAccumulator() async {
    final input = StreamController<MergedShardEvent>();
    final output = input.stream.transform(storage.shardUpload());
    final outputFuture = output.toList();

    input.add(_mergedShard(shardIri, shardGraph));
    input.add(PhaseComplete(SyncInput([shardIri]), 1));
    await input.close();
    await outputFuture;
  }

  group('SingleFileRemoteSyncStorage.finalizeSync', () {
    test('uploads on SyncFinalizationSuccess', () async {
      await populateAccumulator();

      await storage.finalizeSync(const SyncFinalizationSuccess());
      expect(spyBackend.uploadCallCount, equals(1),
          reason: 'Should upload the single file on success');
      expect(spyBackend.finalizeCallCount, equals(1));
      expect(spyBackend.finalizedState, isA<SyncFinalizationSuccess>());
    });

    test('does NOT upload on SyncFinalizationFailure', () async {
      await populateAccumulator();

      await storage.finalizeSync(SyncFinalizationFailure(
          StateError('test error'), StackTrace.current));
      expect(spyBackend.uploadCallCount, equals(0),
          reason: 'Must NOT upload the single file on failure');
      expect(spyBackend.finalizeCallCount, equals(1));
      expect(spyBackend.finalizedState, isA<SyncFinalizationFailure>());
    });

    test('does NOT upload on SyncFinalizationIncomplete', () async {
      await populateAccumulator();

      await storage.finalizeSync(const SyncFinalizationIncomplete());
      expect(spyBackend.uploadCallCount, equals(0),
          reason: 'Must NOT upload the single file on incomplete');
      expect(spyBackend.finalizeCallCount, equals(1));
      expect(spyBackend.finalizedState, isA<SyncFinalizationIncomplete>());
    });

    test('cleans up accumulators regardless of finalization state', () async {
      await populateAccumulator();

      // First finalize with failure — cleans up accumulators.
      await storage.finalizeSync(
          SyncFinalizationFailure(StateError('test'), StackTrace.current));

      // Second finalize with success — nothing to upload because accumulators
      // were cleaned up by the first finalize.
      await storage.finalizeSync(const SyncFinalizationSuccess());
      expect(spyBackend.uploadCallCount, equals(0),
          reason: 'Accumulators should be cleaned after first finalize');
    });

    test('rethrows upload errors on SyncFinalizationSuccess', () async {
      await populateAccumulator();
      spyBackend.uploadError = StateError('upload failed');

      await expectLater(
        storage.finalizeSync(const SyncFinalizationSuccess()),
        throwsA(isA<StateError>()),
      );
      expect(spyBackend.uploadCallCount, equals(1));
      expect(spyBackend.finalizeCallCount, equals(1),
          reason: 'Backend finalize should still run during cleanup');
    });
  });
}
