/// Tests for Stage 1 (Shard Resolution).
///
/// Verifies:
/// - Normal operation: SyncInput → ShardRef events + PhaseComplete
/// - Exception during index query → PhaseError
/// - Exception during ETag query → PhaseError
library;

import 'package:locorda_core/src/index/index_config_base.dart';
import 'package:locorda_core/src/storage/remote_id.dart';
import 'package:locorda_core/src/storage/storage_interface.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';
import 'package:locorda_core/src/sync/pipeline/stages/stage1_shard_resolution.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Test data
// ---------------------------------------------------------------------------

final _indexIri = IriTerm('tag:test,2025:idx#index');
final _shardIriA = IriTerm('tag:test,2025:shardA#shard');
final _shardIriB = IriTerm('tag:test,2025:shardB#shard');
final _typeIri = IriTerm('tag:test,2025:Type');
final _remoteId = RemoteId('test', 'remote-1');

SyncInput _syncInput() => SyncInput(
      [_indexIri],
      indexInfos: {
        _indexIri: IndexInputInfo(
            _indexIri, RootResourceFetchPolicy.prefetch, _typeIri),
      },
    );

// ---------------------------------------------------------------------------
// Storage stubs
// ---------------------------------------------------------------------------

class _SuccessStorage implements Storage {
  final Map<IriTerm, List<IriTerm>> indexShards;

  _SuccessStorage({this.indexShards = const {}});

  @override
  Future<Map<IriTerm, List<IriTerm>>> getIndexShards(
          Iterable<IriTerm> indexIris) async =>
      indexShards;

  @override
  Future<Map<IriTerm, String?>> getRemoteETags(
          RemoteId remoteId, Iterable<IriTerm> iris) async =>
      {for (final iri in iris) iri: null};

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FailingGetIndexShardsStorage implements Storage {
  @override
  Future<Map<IriTerm, List<IriTerm>>> getIndexShards(
          Iterable<IriTerm> indexIris) async =>
      throw StateError('getIndexShards failure');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FailingGetRemoteETagsStorage implements Storage {
  @override
  Future<Map<IriTerm, List<IriTerm>>> getIndexShards(
          Iterable<IriTerm> indexIris) async =>
      {
        _indexIri: [_shardIriA],
      };

  @override
  Future<Map<IriTerm, String?>> getRemoteETags(
          RemoteId remoteId, Iterable<IriTerm> iris) async =>
      throw StateError('getRemoteETags failure');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Future<List<ShardRefEvent>> _runS01(
  Storage storage,
  SyncInput input,
) async {
  final fn = shardResolution(storage, _remoteId);
  final results = <ShardRefEvent>[];
  await for (final event in fn(input)) {
    results.add(event);
  }
  return results;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('Stage 1 — normal operation', () {
    test('resolves shards and emits ShardRef + PhaseComplete', () async {
      final storage = _SuccessStorage(indexShards: {
        _indexIri: [_shardIriA, _shardIriB],
      });

      final results = await _runS01(storage, _syncInput());

      final refs = results.whereType<ShardRef>().toList();
      expect(refs, hasLength(2));
      expect(refs.map((r) => r.shardIri).toSet(),
          equals({_shardIriA, _shardIriB}));

      final phases = results.whereType<PhaseComplete>().toList();
      expect(phases, hasLength(1));
      expect(phases[0].processedShardCount, equals(2));
    });

    test('empty index yields PhaseComplete with zero shards', () async {
      final storage = _SuccessStorage(indexShards: {_indexIri: []});

      final results = await _runS01(storage, _syncInput());

      expect(results.whereType<ShardRef>(), isEmpty);
      final phases = results.whereType<PhaseComplete>().toList();
      expect(phases, hasLength(1));
      expect(phases[0].processedShardCount, equals(0));
    });
  });

  group('Stage 1 — error handling', () {
    test('getIndexShards failure → PhaseError', () async {
      final storage = _FailingGetIndexShardsStorage();

      final results = await _runS01(storage, _syncInput());

      expect(results, hasLength(1));
      expect(results[0], isA<PhaseError>());
      final error = results[0] as PhaseError;
      expect(error.stage, equals('S01'));
      expect(error.error, isA<StateError>());
    });

    test('getRemoteETags failure → PhaseError', () async {
      final storage = _FailingGetRemoteETagsStorage();

      final results = await _runS01(storage, _syncInput());

      expect(results, hasLength(1));
      expect(results[0], isA<PhaseError>());
      final error = results[0] as PhaseError;
      expect(error.stage, equals('S01'));
    });
  });
}
