/// Tests for Stage 7c (CRDT Merge).
///
/// Verifies:
/// - Exceptions during CRDT merge → [ResourceError] with correct resourceIri
/// - Exception in reconciler → [ResourceError]
/// - Pass-through: ShardError, ResourceError, ShardComplete, PhaseComplete,
///   PhaseError forwarded unchanged
import 'package:locorda_core/src/mapping/merge_contract.dart';
import 'package:locorda_core/src/sync/pipeline/document_shard_reconciler.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';
import 'package:locorda_core/src/sync/pipeline/stages/stage7c_crdt_merge.dart';
import 'package:locorda_core/src/sync/remote_document_merger.dart'
    as merger_lib;
import 'package:locorda_rdf_core/core.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Test data
// ---------------------------------------------------------------------------

final _shardIri = IriTerm('tag:test,2025:shardA#shard');
final _resIri = IriTerm('tag:test,2025:res1#it');
final _typeIri = IriTerm('tag:test,2025:Type');
final _docIri = IriTerm('tag:test,2025:res1');
final _syncInput = SyncInput([_shardIri]);
final _emptyGraph = RdfGraph();
final _rdfCore = RdfCore.withStandardCodecs();

// ---------------------------------------------------------------------------
// Stubs
// ---------------------------------------------------------------------------

/// Merger that throws on every call — triggers [ResourceError].
class _ThrowingMerger implements merger_lib.RemoteDocumentMerger {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('merge explosion');
}

/// Merger that returns a valid merge result.
class _SuccessMerger implements merger_lib.RemoteDocumentMerger {
  @override
  merger_lib.MergeResult merge({
    required MergeContract mergeContract,
    required IriTerm documentIri,
    required RdfGraph? localGraph,
    required RdfGraph? remoteGraph,
  }) =>
      merger_lib.MergeResult(
        mergedGraph: _emptyGraph,
      );
}

/// Reconciler that throws — triggers [ResourceError] during reconciliation.
class _ThrowingReconciler implements DocumentShardReconciler {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('reconcile explosion');
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('Stage 7c — merge error → ResourceError', () {
    test('Exception in merge produces ResourceError', () {
      final fn = mergeCandidates(
        _ThrowingMerger(),
        _ThrowingReconciler(), // never reached
        _rdfCore,
      );

      // conflictCandidate direction triggers merger.merge() which throws
      final candidate = PreloadedCandidate(
        decoded: DecodedCandidate(
          resourceIri: _resIri,
          documentIri: _docIri,
          typeIri: _typeIri,
          localGraph: _emptyGraph,
          remoteGraph: _emptyGraph,
          effectiveDirection: SyncDirection.conflictCandidate,
          governanceIris: const [],
        ),
        mergeContract: MergeContract(const {}, const {}),
        indexConfigs: const [],
        documents: const {},
        indexedProperties: const {},
      );

      final results = fn(candidate).toList();

      expect(results, hasLength(1));
      expect(results[0], isA<ResourceError>());
      final error = results[0] as ResourceError;
      expect(error.resourceIri, equals(_resIri));
      expect(error.error, isA<StateError>());
    });

    test('Exception in reconciler produces ResourceError', () {
      final fn = mergeCandidates(
        _SuccessMerger(),
        _ThrowingReconciler(),
        _rdfCore,
      );

      // remoteOnly direction uses merger, but reconciler fails after merge
      final candidate = PreloadedCandidate(
        decoded: DecodedCandidate(
          resourceIri: _resIri,
          documentIri: _docIri,
          typeIri: _typeIri,
          localGraph: null,
          remoteGraph: _emptyGraph,
          effectiveDirection: SyncDirection.remoteOnly,
          governanceIris: const [],
        ),
        mergeContract: MergeContract(const {}, const {}),
        indexConfigs: const [],
        documents: const {},
        indexedProperties: const {},
      );

      final results = fn(candidate).toList();

      expect(results, hasLength(1));
      expect(results[0], isA<ResourceError>());
      expect((results[0] as ResourceError).resourceIri, equals(_resIri));
    });
  });

  group('Stage 7c — pass-through', () {
    late Iterable<MergedResourceEvent> Function(PreloadedCandidateEvent) fn;

    setUp(() {
      fn = mergeCandidates(
        _ThrowingMerger(), // never called for pass-throughs
        _ThrowingReconciler(),
        _rdfCore,
      );
    });

    test('ShardError passes through', () {
      final error =
          ShardError(_shardIri, StateError('test'), StackTrace.current);
      final results = fn(error).toList();
      expect(results, hasLength(1));
      expect(results[0], same(error));
    });

    test('ResourceError passes through', () {
      final error =
          ResourceError(_resIri, StateError('test'), StackTrace.current);
      final results = fn(error).toList();
      expect(results, hasLength(1));
      expect(results[0], same(error));
    });

    test('ShardComplete passes through', () {
      final sc = ShardComplete(_shardIri, 42);
      final results = fn(sc).toList();
      expect(results, hasLength(1));
      expect(results[0], same(sc));
    });

    test('PhaseComplete passes through', () {
      final pc = PhaseComplete(_syncInput, 1);
      final results = fn(pc).toList();
      expect(results, hasLength(1));
      expect(results[0], same(pc));
    });

    test('PhaseError passes through', () {
      final pe =
          PhaseError(StateError('test'), StackTrace.current, stage: 'S06');
      final results = fn(pe).toList();
      expect(results, hasLength(1));
      expect(results[0], same(pe));
    });
  });
}
