/// Tests for Stage 10 (Shard Entry Load).
///
/// Verifies:
/// - [ShardSkipped] passes through directly (no batch load)
/// - [ShardComplete] triggers batch load
/// - Batch load failure → [ShardError] for each pending shard
/// - [ConflictedShard], [ShardError] pass through unchanged
/// - [PhaseComplete] flushes pending batch then passes through
/// - [PhaseError] clears pending and passes through
library;
import 'package:locorda_core/src/storage/storage_interface.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';
import 'package:locorda_core/src/sync/pipeline/stages/stage10_shard_entry_load.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Test data
// ---------------------------------------------------------------------------

final _shardIriA = IriTerm('tag:test,2025:shardA#shard');
final _shardIriB = IriTerm('tag:test,2025:shardB#shard');
final _syncInput = SyncInput([_shardIriA]);

ShardError _shardError() =>
    ShardError(_shardIriA, StateError('test'), StackTrace.current);

ConflictedShard _conflictedShard() =>
    ConflictedShard(_shardIriA, message: 'test');

PhaseComplete _phaseComplete() => PhaseComplete(_syncInput, 1);

// ---------------------------------------------------------------------------
// Stubs
// ---------------------------------------------------------------------------

class _StubStorage implements Storage {
  @override
  Future<Map<IriTerm, List<IndexEntryWithIri>>> getActiveIndexEntriesForShards(
          Iterable<IriTerm> shardIris) async =>
      {};

  @override
  Future<Map<IriTerm, RawStoredDocument?>> getRawDocumentsByIri(
          Iterable<IriTerm> iris,
          {int? ifChangedSincePhysicalClock}) async =>
      {};

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FailingStorage implements Storage {
  @override
  Future<Map<IriTerm, List<IndexEntryWithIri>>> getActiveIndexEntriesForShards(
          Iterable<IriTerm> shardIris) async =>
      throw StateError('batch load failure');

  @override
  Future<Map<IriTerm, RawStoredDocument?>> getRawDocumentsByIri(
          Iterable<IriTerm> iris,
          {int? ifChangedSincePhysicalClock}) async =>
      {};

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// ---------------------------------------------------------------------------
// Test runner
// ---------------------------------------------------------------------------

Future<List<LoadedShardEntriesEvent>> _runS10(
  Storage storage,
  List<CommittedResourceEvent> events,
) async {
  final fn = shardEntryLoad(storage);
  final results = <LoadedShardEntriesEvent>[];
  for (final event in events) {
    await for (final out in fn(event)) {
      results.add(out);
    }
  }
  return results;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('Stage 10 — pass-through', () {
    test('ShardError passes through', () async {
      final results = await _runS10(_StubStorage(), [_shardError()]);
      expect(results, hasLength(1));
      expect(results[0], isA<ShardError>());
    });

    test('ConflictedShard passes through', () async {
      final results = await _runS10(_StubStorage(), [_conflictedShard()]);
      expect(results, hasLength(1));
      expect(results[0], isA<ConflictedShard>());
    });

    test('PhaseComplete passes through (flushes empty batch)', () async {
      final results = await _runS10(_StubStorage(), [_phaseComplete()]);
      expect(results, hasLength(1));
      expect(results[0], isA<PhaseComplete>());
    });

    test('ShardSkipped passes through directly', () async {
      final sc = ShardSkipped(_shardIriA, 42);
      final results = await _runS10(_StubStorage(), [sc]);
      expect(results, hasLength(1));
      expect(results[0], isA<ShardSkipped>());
    });
  });

  group('Stage 10 — batch load', () {
    test('ShardComplete triggers batch flush', () async {
      final sc = ShardComplete(_shardIriA, 42);
      final results = await _runS10(_StubStorage(), [sc, _phaseComplete()]);
      // Flushed as LoadedShardEntries on PhaseComplete, followed by
      // PhaseComplete itself.
      final loaded = results.whereType<LoadedShardEntries>().toList();
      expect(loaded, hasLength(1));
      expect(loaded[0].shardIri, equals(_shardIriA));
      expect(results.last, isA<PhaseComplete>());
    });
  });

  group('Stage 10 — error handling', () {
    test('Batch load failure → ShardError for each pending shard', () async {
      final sc1 = ShardComplete(_shardIriA, 42);
      final sc2 = ShardComplete(_shardIriB, 43);
      final results = await _runS10(
        _FailingStorage(),
        [sc1, sc2, _phaseComplete()],
      );

      // Both shards fail at PhaseComplete flush.
      final errors = results.whereType<ShardError>().toList();
      expect(errors, hasLength(2));
      expect(errors.map((e) => e.shardIri).toSet(),
          equals({_shardIriA, _shardIriB}));
      expect(results.whereType<PhaseComplete>(), hasLength(1));
    });
  });

  group('Stage 10 — PhaseError pass-through', () {
    test('PhaseError clears pending and passes through', () async {
      final sc = ShardComplete(_shardIriA, 42);
      final results = await _runS10(_StubStorage(), [
        sc,
        PhaseError(StateError('test'), StackTrace.current, stage: 'S09'),
      ]);

      // ShardComplete was buffered, PhaseError clears it and passes through.
      expect(results, hasLength(1));
      expect(results[0], isA<PhaseError>());
    });
  });
}
