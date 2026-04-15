/// Tests for Stage 6 (Resource Fetch) — single_file layout.
///
/// SF serves resource graphs from the download cache populated in S02 —
/// no I/O. Tests verify error/boundary event pass-through and cache cleanup.
import 'dart:async';

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
final _resIri = IriTerm('tag:test,2025:res1#it');
final _emptyGraph = RdfGraph();

// ---------------------------------------------------------------------------
// Stubs
// ---------------------------------------------------------------------------

class _NullBackend implements RemoteSyncBackend {
  @override
  Stream<RemoteDownloadResult<RawContent>> download(
          Stream<RemoteDownloadRequest> requests) =>
      const Stream.empty();

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
  late SingleFileRemoteSyncStorage storage;

  setUp(() {
    storage = SingleFileRemoteSyncStorage(
      _NullBackend(),
      rdfCore: _rdfCore,
      contentType: _contentType,
      storageAccess: _StubStorageAccess(),
    );
  });

  group('Stage 6 — single_file — pass-through', () {
    test('ShardError passes through', () async {
      final results =
          await _transform<LoadedCandidateEvent, FetchedCandidateEvent>(
              storage.resourceFetch(), [
        ShardError(_shardIriA, StateError('upstream'), StackTrace.current),
      ]);

      expect(results, hasLength(1));
      expect(results[0], isA<ShardError>());
    });

    test('ResourceError passes through', () async {
      final results =
          await _transform<LoadedCandidateEvent, FetchedCandidateEvent>(
              storage.resourceFetch(), [
        ResourceError(_resIri, StateError('upstream'), StackTrace.current),
      ]);

      expect(results, hasLength(1));
      expect(results[0], isA<ResourceError>());
    });

    test('ShardComplete passes through', () async {
      final results =
          await _transform<LoadedCandidateEvent, FetchedCandidateEvent>(
              storage.resourceFetch(), [
        ShardComplete(_shardIriA, null),
      ]);

      expect(results, hasLength(1));
      expect(results[0], isA<ShardComplete>());
    });

    test('PhaseComplete passes through', () async {
      final results =
          await _transform<LoadedCandidateEvent, FetchedCandidateEvent>(
              storage.resourceFetch(), [
        PhaseComplete(SyncInput([_shardIriA]), 1),
      ]);

      expect(results, hasLength(1));
      expect(results[0], isA<PhaseComplete>());
    });

    test('PhaseError clears cache and passes through', () async {
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
