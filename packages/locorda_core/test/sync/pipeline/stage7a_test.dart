/// Tests for Stage 7a (Decode & Classify).
///
/// Verifies:
/// - Decode failure → ResourceError
/// - ShardError passes through unchanged
/// - ResourceError passes through unchanged
/// - ShardComplete passes through unchanged
/// - PhaseComplete passes through unchanged
/// - PhaseError passes through unchanged
library;
import 'package:locorda_core/src/mapping/merge_contract.dart';
import 'package:locorda_core/src/mapping/merge_contract_loader.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';
import 'package:locorda_core/src/sync/pipeline/stages/stage7a_decode.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Test data
// ---------------------------------------------------------------------------

final _shardIri = IriTerm('tag:test,2025:shardA#shard');
final _resIri = IriTerm('tag:test,2025:res1#it');
final _syncInput = SyncInput([_shardIri]);
final _rdfCore = RdfCore.withStandardCodecs();

// ---------------------------------------------------------------------------
// Stubs
// ---------------------------------------------------------------------------

class _StubMergeContractLoader implements MergeContractLoader {
  @override
  Future<MergeContract> load(List<IriTerm> isGovernedBy) async =>
      MergeContract(const {}, const {});

  @override
  List<IriTerm> getMergedGovernanceIris(
          List<RdfGraph> graphs, IriTerm documentIri) =>
      [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ThrowingMergeContractLoader implements MergeContractLoader {
  @override
  List<IriTerm> getMergedGovernanceIris(
          List<RdfGraph> graphs, IriTerm documentIri) =>
      throw StateError('governance explosion');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('Stage 7a — error handling', () {
    test('decode/classify failure → ResourceError', () {
      final fn = decodeCandidates(_ThrowingMergeContractLoader(), _rdfCore);

      final fetched = FetchedCandidate(
        LoadedCandidate(
          SyncCandidate(
            _resIri,
            null,
            SyncDirection.remoteOnly,
            IriTerm('tag:test,2025:Type'),
          ),
        ),
      );

      final result = fn(fetched);
      expect(result, isA<ResourceError>());
      expect((result as ResourceError).resourceIri, equals(_resIri));
    });
  });

  group('Stage 7a — pass-through', () {
    late DecodedCandidateEvent Function(FetchedCandidateEvent) fn;

    setUp(() {
      fn = decodeCandidates(_StubMergeContractLoader(), _rdfCore);
    });

    test('ShardError passes through unchanged', () {
      final error =
          ShardError(_shardIri, StateError('test'), StackTrace.current);
      expect(fn(error), same(error));
    });

    test('ResourceError passes through unchanged', () {
      final error =
          ResourceError(_resIri, StateError('test'), StackTrace.current);
      expect(fn(error), same(error));
    });

    test('ShardComplete passes through unchanged', () {
      final sc = ShardComplete(_shardIri, 42);
      expect(fn(sc), same(sc));
    });

    test('PhaseComplete passes through unchanged', () {
      final phase = PhaseComplete(_syncInput, 1);
      expect(fn(phase), same(phase));
    });

    test('PhaseError passes through unchanged', () {
      final error =
          PhaseError(StateError('test'), StackTrace.current, stage: 'S06');
      expect(fn(error), same(error));
    });
  });
}
