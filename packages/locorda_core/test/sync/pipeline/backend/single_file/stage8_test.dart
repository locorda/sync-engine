import 'package:locorda_core/src/sync/pipeline/pipeperf.dart';
/// Tests for Stage 8 (Resource Upload) — single_file layout.
///
/// Verifies:
/// - [ResourceError] converts to [ShardError] at [ShardComplete] boundary
/// - Error flag resets between shards
/// - [PhaseError] resets state and passes through
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
final _emptyGraph = RdfGraph();

final _shardIriA = IriTerm('tag:test,2025:shardA#shard');
final _shardIriB = IriTerm('tag:test,2025:shardB#shard');
final _resIri1 = IriTerm('tag:test,2025:res1#it');
final _resIri2 = IriTerm('tag:test,2025:res2#it');
final _resIri3 = IriTerm('tag:test,2025:res3#it');

MergeResult _mergeResult(IriTerm resourceIri, {bool needsUpload = true}) =>
    MergeResult(
      resourceIri,
      IriTerm('tag:test,2025:Type'),
      DecodedGraphSource(_emptyGraph),
      BinaryGraphSource(Uint8List(0), contentType: jellyMimeType),
      needsUpload: needsUpload,
      needsDbWrite: true,
      clock: (logicalTime: 1, physicalTime: 1, fullClock: const [], hash: ''),
      resolvedGroupIndices: const [],
      indexEntries: const [],
    );

ShardComplete _shardComplete(IriTerm shardIri) => ShardComplete(shardIri, null);

ResourceError _resourceError(IriTerm resourceIri) =>
    ResourceError(resourceIri, StateError('test error'), StackTrace.current);

// ---------------------------------------------------------------------------
// Stubs
// ---------------------------------------------------------------------------

class _SuccessBackend implements RemoteSyncBackend {
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
      yield SuccessUploadResult(
        'etag-1',
        documentIri: request.documentIri,
        requestETag: request.ifMatch,
      );
    }
  }

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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  late SingleFileRemoteSyncStorage storage;

  setUp(() {
    storage = SingleFileRemoteSyncStorage(
      _SuccessBackend(),
      rdfCore: _rdfCore,
      contentType: _contentType,
      storageAccess: _StubStorageAccess(),
    );
  });

  group('Stage 8 — single_file — error handling', () {
    test('ResourceError converts to ShardError at ShardComplete', () async {
      final results = await _runS08(storage.resourceUpload(), [
        _mergeResult(_resIri1),
        _resourceError(_resIri2),
        _shardComplete(_shardIriA),
      ]);

      expect(results, hasLength(2));
      expect(results[0], isA<UploadResult>());
      expect(results[1], isA<ShardError>());
      expect((results[1] as ShardError).shardIri, equals(_shardIriA));
    });

    test('Error flag resets between shards', () async {
      final results = await _runS08(storage.resourceUpload(), [
        _resourceError(_resIri1),
        _shardComplete(_shardIriA),
        _mergeResult(_resIri3),
        _shardComplete(_shardIriB),
      ]);

      expect(results.whereType<ShardError>(), hasLength(1));
      expect(results.whereType<ShardComplete>(), hasLength(1));
    });
  });

  group('Stage 8 — single_file — PhaseError', () {
    test('PhaseError resets state and passes through', () async {
      final results = await _runS08(storage.resourceUpload(), [
        _resourceError(_resIri1),
        PhaseError(StateError('test'), StackTrace.current, stage: 'S07c'),
      ]);

      expect(results, hasLength(1));
      expect(results[0], isA<PhaseError>());
    });
  });
}
