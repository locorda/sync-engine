/// Tests for Stage 11c (Shard CRDT Merge).
///
/// Verifies:
/// - Exception during CRDT merge → [ShardError] with correct shardIri
/// - Exception during remote structural merge → [ShardError]
/// - Pass-through: ConflictedShard, ShardError,
///   PhaseComplete, PhaseError forwarded unchanged
library;
import 'package:locorda_core/src/crdt_document_manager.dart';
import 'package:locorda_core/src/mapping/merge_contract.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';
import 'package:locorda_core/src/sync/pipeline/stages/stage11c_shard_merge.dart';
import 'package:locorda_core/src/sync/remote_document_merger.dart'
    as merger_lib;
import 'package:locorda_rdf_core/core.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Test data
// ---------------------------------------------------------------------------

final _shardIriA = IriTerm('tag:test,2025:shardA#shard');
final _indexIri = IriTerm('tag:test,2025:idx#index');
final _syncInput = SyncInput([_shardIriA]);
final _emptyGraph = RdfGraph();
final _rdfCore = RdfCore.withStandardCodecs();

ContractLoadedShard _loadedShard({
  IriTerm? shardIri,
  DecodedGraphSource? remoteShardGraph,
}) =>
    ContractLoadedShard(
      prepared: PreparedShard(
        shardIri: shardIri ?? _shardIriA,
        shardStorageId: 'storage-1',
        localDoc: null,
        indexIri: _indexIri,
        entryTriples: const [],
        governanceIris: const [],
        remoteShardGraph: remoteShardGraph,
      ),
      mergeContract: MergeContract(const {}, const {}),
    );

// ---------------------------------------------------------------------------
// Stubs
// ---------------------------------------------------------------------------

/// DocumentManager that throws on every call — triggers [ShardError].
class _ThrowingDocumentManager implements CrdtDocumentManager {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('DocumentManager failure');
}

/// Merger that throws on every call — used for remote merge path.
class _ThrowingMerger implements merger_lib.RemoteDocumentMerger {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Merger failure');
}

/// Merger that returns a successful result.
class _SuccessMerger implements merger_lib.RemoteDocumentMerger {
  @override
  merger_lib.MergeResult merge({
    required MergeContract mergeContract,
    required IriTerm documentIri,
    required RdfGraph? localGraph,
    required RdfGraph? remoteGraph,
  }) =>
      merger_lib.MergeResult(mergedGraph: _emptyGraph);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('Stage 11c — error handling', () {
    test('exception in documentManager.prepareModifyWithContract → ShardError',
        () {
      // No remote graph → skips remote merge, goes straight to
      // prepareModifyWithContract which throws.
      final fn =
          mergeShards(_ThrowingDocumentManager(), _SuccessMerger(), _rdfCore);
      final results = fn(_loadedShard()).toList();

      expect(results, hasLength(1));
      expect(results[0], isA<ShardError>());
      final error = results[0] as ShardError;
      expect(error.shardIri, equals(_shardIriA));
      expect(error.error, isA<StateError>());
    });

    test('exception in remote merge (merger.merge) → ShardError', () {
      // Non-null remoteShardGraph triggers merger.merge() before
      // documentManager — merger throws.
      final fn = mergeShards(
        _ThrowingDocumentManager(),
        _ThrowingMerger(),
        _rdfCore,
      );
      final results = fn(
        _loadedShard(remoteShardGraph: DecodedGraphSource(_emptyGraph)),
      ).toList();

      expect(results, hasLength(1));
      expect(results[0], isA<ShardError>());
      final error = results[0] as ShardError;
      expect(error.shardIri, equals(_shardIriA));
      expect(error.error.toString(), contains('Merger failure'));
    });
  });

  group('Stage 11c — pass-through', () {
    test('ConflictedShard passes through unchanged', () {
      final fn =
          mergeShards(_ThrowingDocumentManager(), _ThrowingMerger(), _rdfCore);
      final event = ConflictedShard(_shardIriA);
      final results = fn(event).toList();

      expect(results, hasLength(1));
      expect(results[0], same(event));
    });

    test('ShardError passes through unchanged', () {
      final fn =
          mergeShards(_ThrowingDocumentManager(), _ThrowingMerger(), _rdfCore);
      final event =
          ShardError(_shardIriA, StateError('up'), StackTrace.current);
      final results = fn(event).toList();

      expect(results, hasLength(1));
      expect(results[0], same(event));
    });

    test('PhaseComplete passes through unchanged', () {
      final fn =
          mergeShards(_ThrowingDocumentManager(), _ThrowingMerger(), _rdfCore);
      final event = PhaseComplete(_syncInput, 1);
      final results = fn(event).toList();

      expect(results, hasLength(1));
      expect(results[0], same(event));
    });

    test('PhaseError passes through unchanged', () {
      final fn =
          mergeShards(_ThrowingDocumentManager(), _ThrowingMerger(), _rdfCore);
      final event =
          PhaseError(StateError('test'), StackTrace.current, stage: 'S10');
      final results = fn(event).toList();

      expect(results, hasLength(1));
      expect(results[0], same(event));
    });
  });
}
