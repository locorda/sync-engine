/// Tests for Stage 4 (Change Detection).
///
/// Verifies:
/// - Upfront query failure → PhaseError (stream terminates)
/// - Handler exception for ParsedShard → ShardError (terminal)
/// - ShardError passes through unchanged
/// - PhaseError passes through unchanged
/// - PhaseComplete passes through unchanged
library;
import 'dart:async';

import 'package:locorda_core/src/storage/remote_id.dart';
import 'package:locorda_core/src/storage/storage_interface.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';
import 'package:locorda_core/src/sync/pipeline/stages/stage4_change_detection.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Test data
// ---------------------------------------------------------------------------

final _shardIri = IriTerm('tag:test,2025:shardA#shard');
final _syncInput = SyncInput([_shardIri]);

// ---------------------------------------------------------------------------
// Storage stubs
// ---------------------------------------------------------------------------

class _StubStorage implements Storage {
  @override
  Future<Set<IriTerm>?> getShardsWithLocalChangesSince(int sinceTimestamp,
          {int limit = 20}) async =>
      const {};

  @override
  Future<Map<IriTerm, RawStoredDocument?>> getRawDocumentsByIri(
          Iterable<IriTerm> iris,
          {int? ifChangedSincePhysicalClock}) async =>
      {};

  @override
  Future<Map<IriTerm, String?>> getRemoteETags(
          RemoteId remoteId, Iterable<IriTerm> iris) async =>
      {};

  @override
  Future<Map<IriTerm, List<IndexEntryWithIri>>> getActiveIndexEntriesForShards(
          Iterable<IriTerm> shardIris) async =>
      {};

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FailingUpfrontQueryStorage implements Storage {
  @override
  Future<Set<IriTerm>?> getShardsWithLocalChangesSince(int sinceTimestamp,
          {int limit = 20}) async =>
      throw StateError('upfront query failure');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FailingPerShardStorage implements Storage {
  @override
  Future<Set<IriTerm>?> getShardsWithLocalChangesSince(int sinceTimestamp,
          {int limit = 20}) async =>
      const {};

  @override
  Future<List<IndexEntryWithIri>> getActiveIndexEntriesForShard(
      IriTerm shardIri) {
    return Future.error(StateError('per-shard query failure'));
  }

  @override
  Future<Map<IriTerm, IriTerm>> getIndexIrisForShards(
          Iterable<IriTerm> shardIris) async =>
      {};

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Future<List<T>> _transform<S, T>(
  StreamTransformer<S, T> transformer,
  List<S> events,
) async {
  return Stream.fromIterable(events).transform(transformer).toList();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('Stage 4 — error handling', () {
    test('upfront query failure → PhaseError (stream terminates)', () async {
      final transformer = changeDetection(_FailingUpfrontQueryStorage(), 0);

      final results = await _transform(transformer, <ParsedShardEvent>[
        PhaseComplete(_syncInput, 1),
      ]);

      // PhaseError is emitted, then the generator returns.
      // The PhaseComplete from the stream may or may not come through
      // depending on timing, but PhaseError must be present.
      final errors = results.whereType<PhaseError>().toList();
      expect(errors, hasLength(1));
      expect(errors[0].stage, equals('S04'));
    });

    test('per-shard handler failure → ShardError (terminal)', () async {
      final transformer = changeDetection(_FailingPerShardStorage(), 0);

      final parsed = ParsedShard(
        _shardIri,
        null,
        null,
        IriTerm('tag:test,2025:Type'),
        const [],
        DecodedGraphSource(RdfGraph()),
        'etag-1',
      );

      final results = await _transform(transformer, <ParsedShardEvent>[
        parsed,
        PhaseComplete(_syncInput, 1),
      ]);

      final errors = results.whereType<ShardError>().toList();
      expect(errors, hasLength(1));
      expect(errors[0].shardIri, equals(_shardIri));

      // ShardError is the terminal event — no ShardComplete follows.
      final completes = results.whereType<ShardComplete>().toList();
      expect(completes, isEmpty);
    });
  });

  group('Stage 4 — pass-through', () {
    test('ShardError passes through', () async {
      final transformer = changeDetection(_StubStorage(), 0);
      final error =
          ShardError(_shardIri, StateError('test'), StackTrace.current);
      final results = await _transform(transformer, [error]);
      expect(results, hasLength(1));
      expect(results[0], isA<ShardError>());
      expect((results[0] as ShardError).shardIri, equals(_shardIri));
    });

    test('PhaseError passes through', () async {
      final transformer = changeDetection(_StubStorage(), 0);
      final error =
          PhaseError(StateError('test'), StackTrace.current, stage: 'S03');
      final results = await _transform(transformer, [error]);
      expect(results, hasLength(1));
      expect(results[0], isA<PhaseError>());
    });

    test('PhaseComplete passes through', () async {
      final transformer = changeDetection(_StubStorage(), 0);
      final phase = PhaseComplete(_syncInput, 1);
      final results = await _transform(transformer, [phase]);
      expect(results, hasLength(1));
      expect(results[0], isA<PhaseComplete>());
    });
  });
}
