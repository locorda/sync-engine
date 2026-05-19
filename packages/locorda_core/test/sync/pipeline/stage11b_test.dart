/// Tests for Stage 11b (Shard Contract Load).
///
/// Verifies:
/// - [ShardError], [ConflictedShard], [ShardComplete], [PhaseComplete]
///   pass through unchanged
/// - [PhaseError] passes through unchanged
/// - Contract load failure → [ShardError]
library;

import 'dart:async';

import 'package:locorda_core/src/mapping/merge_contract.dart';
import 'package:locorda_core/src/mapping/merge_contract_loader.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';
import 'package:locorda_core/src/sync/pipeline/stages/stage11b_contract_load.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Test data
// ---------------------------------------------------------------------------

final _shardIri = IriTerm('tag:test,2025:shardA#shard');
final _syncInput = SyncInput([_shardIri]);

ShardError _shardError() =>
    ShardError(_shardIri, StateError('test'), StackTrace.current);

ConflictedShard _conflictedShard() =>
    ConflictedShard(_shardIri, message: 'test');

PhaseComplete _phaseComplete() => PhaseComplete(_syncInput, 1);

// ---------------------------------------------------------------------------
// Stubs
// ---------------------------------------------------------------------------

class _StubMergeContractLoader implements MergeContractLoader {
  @override
  Future<MergeContract> load(List<IriTerm> isGovernedBy) async =>
      MergeContract(const {}, const {});

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FailingMergeContractLoader implements MergeContractLoader {
  @override
  Future<MergeContract> load(List<IriTerm> isGovernedBy) async =>
      throw StateError('contract load failure');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('Stage 11b — pass-through', () {
    late FutureOr<ContractLoadedShardEvent> Function(PreparedShardEvent) fn;

    setUp(() {
      fn = loadShardContracts(_StubMergeContractLoader());
    });

    test('ShardError passes through unchanged', () async {
      final error = _shardError();
      final result = await fn(error);
      expect(result, same(error));
    });

    test('ConflictedShard passes through unchanged', () async {
      final cs = _conflictedShard();
      final result = await fn(cs);
      expect(result, same(cs));
    });

    test('PhaseComplete passes through unchanged', () async {
      final pc = _phaseComplete();
      final result = await fn(pc);
      expect(result, same(pc));
    });

    test('PhaseError passes through unchanged', () async {
      final pe =
          PhaseError(StateError('test'), StackTrace.current, stage: 'S10');
      final result = await fn(pe);
      expect(result, same(pe));
    });
  });

  group('Stage 11b — error handling', () {
    test('Contract load failure → ShardError', () async {
      final fn = loadShardContracts(_FailingMergeContractLoader());

      // PreparedShard triggers contract loading which throws.
      final event = PreparedShard(
        shardIri: _shardIri,
        shardStorageId: 42,
        indexIri: IriTerm('tag:test,2025:index'),
        remoteShardGraph: null,
        newEtag: null,
        existsOnRemote: true,
        localDoc: null,
        entryTriples: const [],
        governanceIris: const [],
      );

      final result = await fn(event);
      expect(result, isA<ShardError>());
      expect((result as ShardError).shardIri, equals(_shardIri));
    });
  });
}
