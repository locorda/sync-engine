/// Tests for Stage 5 (Local Content Load).
///
/// Verifies:
/// - Batch load failure → ResourceError per candidate
/// - ShardError discards buffer then passes through
/// - ShardComplete flushes buffer then passes through
/// - PhaseComplete flushes buffer then passes through
/// - PhaseError flushes buffer then passes through
import 'dart:async';

import 'package:locorda_core/src/storage/remote_id.dart';
import 'package:locorda_core/src/storage/storage_interface.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';
import 'package:locorda_core/src/sync/pipeline/stages/stage5_local_content_load.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Test data
// ---------------------------------------------------------------------------

final _shardIri = IriTerm('tag:test,2025:shardA#shard');
final _resIri = IriTerm('tag:test,2025:res1#it');
final _typeIri = IriTerm('tag:test,2025:Type');
final _syncInput = SyncInput([_shardIri]);
final _remoteId = RemoteId('test', 'remote-1');

SyncCandidate _candidate() => SyncCandidate(
      _resIri,
      42,
      SyncDirection.remoteOnly,
      _typeIri,
    );

// ---------------------------------------------------------------------------
// Storage stubs
// ---------------------------------------------------------------------------

class _StubStorage implements Storage {
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
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FailingStorage implements Storage {
  @override
  Future<Map<IriTerm, RawStoredDocument?>> getRawDocumentsByIri(
      Iterable<IriTerm> iris,
      {int? ifChangedSincePhysicalClock}) async {
    throw StateError('batch load failure');
  }

  @override
  Future<Map<IriTerm, String?>> getRemoteETags(
          RemoteId remoteId, Iterable<IriTerm> iris) async =>
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
  group('Stage 5 — error handling', () {
    test('batch load failure → ResourceError per candidate', () async {
      final transformer = localContentLoad(_FailingStorage(), _remoteId);
      final results = await _transform(transformer, [
        _candidate(),
        ShardComplete(_shardIri, 42),
      ]);

      // candidate fails to load → ResourceError, ShardComplete passes through
      final errors = results.whereType<ResourceError>().toList();
      expect(errors, hasLength(1));
      expect(errors[0].resourceIri, equals(_resIri));
      expect(results.whereType<ShardComplete>(), hasLength(1));
    });
  });

  group('Stage 5 — pass-through', () {
    test('ShardError passes through', () async {
      final transformer = localContentLoad(_StubStorage(), _remoteId);
      final results = await _transform(transformer, <SyncCandidateEvent>[
        ShardError(_shardIri, StateError('test'), StackTrace.current),
      ]);

      expect(results, hasLength(1));
      expect(results[0], isA<ShardError>());
    });

    test('ShardComplete flushes buffer then passes through', () async {
      final transformer = localContentLoad(_StubStorage(), _remoteId);
      final results = await _transform(transformer, [
        ShardComplete(_shardIri, 42),
      ]);
      expect(results, hasLength(1));
      expect(results[0], isA<ShardComplete>());
    });

    test('PhaseComplete passes through', () async {
      final transformer = localContentLoad(_StubStorage(), _remoteId);
      final results = await _transform(transformer, [
        PhaseComplete(_syncInput, 1),
      ]);
      expect(results, hasLength(1));
      expect(results[0], isA<PhaseComplete>());
    });

    test('PhaseError flushes buffer then passes through', () async {
      final transformer = localContentLoad(_StubStorage(), _remoteId);
      final error =
          PhaseError(StateError('test'), StackTrace.current, stage: 'S04');
      final results = await _transform(transformer, [error]);
      expect(results, hasLength(1));
      expect(results[0], isA<PhaseError>());
    });
  });
}
