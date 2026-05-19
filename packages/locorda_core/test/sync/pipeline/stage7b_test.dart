/// Tests for Stage 7b (Preload).
///
/// Verifies:
/// - Batch preload failure → ResourceError per candidate
/// - ShardError flushes buffer then passes through
/// - ResourceError passes through
/// - ShardComplete flushes buffer then passes through
/// - PhaseComplete flushes buffer then passes through
/// - PhaseError flushes buffer then passes through
library;

import 'dart:async';

import 'package:locorda_core/src/index/index_discovery.dart';
import 'package:locorda_core/src/index/index_rdf_generator.dart';
import 'package:locorda_core/src/index/shard_determiner.dart';
import 'package:locorda_core/src/mapping/merge_contract.dart';
import 'package:locorda_core/src/mapping/merge_contract_loader.dart';
import 'package:locorda_core/src/storage/storage_interface.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';
import 'package:locorda_core/src/sync/pipeline/stages/stage7b_preload.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Test data
// ---------------------------------------------------------------------------

final _shardIri = IriTerm('tag:test,2025:shardA#shard');
final _resIri = IriTerm('tag:test,2025:res1#it');
final _syncInput = SyncInput([_shardIri]);

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

class _ThrowingIndexDiscovery implements IndexDiscovery {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
      'IndexDiscovery should not be called for error events');
}

class _ThrowingShardDeterminer implements ShardDeterminer {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
      'ShardDeterminer should not be called for error events');
}

class _ThrowingIndexRdfGenerator implements IndexRdfGenerator {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
      'IndexRdfGenerator should not be called for error events');
}

class _StubStorage implements Storage {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Merge contract loader that always throws — triggers batch failure.
class _FailingMergeContractLoader implements MergeContractLoader {
  @override
  Future<MergeContract> load(List<IriTerm> isGovernedBy) =>
      throw StateError('contract load failure');

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

StreamTransformer<DecodedCandidateEvent, PreloadedCandidateEvent>
    _makeTransformer({
  MergeContractLoader? mergeContractLoader,
}) {
  return preloadCandidates(
    mergeContractLoader ?? _StubMergeContractLoader(),
    _ThrowingIndexDiscovery(),
    _ThrowingShardDeterminer(),
    _StubStorage(),
    _ThrowingIndexRdfGenerator(),
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('Stage 7b — error handling', () {
    test('batch preload failure → ResourceError per candidate', () async {
      final transformer =
          _makeTransformer(mergeContractLoader: _FailingMergeContractLoader());

      final candidate = DecodedCandidate(
        resourceIri: _resIri,
        documentIri: IriTerm('tag:test,2025:res1'),
        typeIri: IriTerm('tag:test,2025:Type'),
        localGraph: null,
        remoteGraph: RdfGraph(),
        effectiveDirection: SyncDirection.remoteOnly,
        governanceIris: const [],
      );

      final results = await _transform(transformer, [
        candidate,
        ShardComplete(_shardIri, 42),
      ]);

      final errors = results.whereType<ResourceError>().toList();
      expect(errors, hasLength(1));
      expect(errors[0].resourceIri, equals(_resIri));

      expect(results.whereType<ShardComplete>(), hasLength(1));
    });
  });

  group('Stage 7b — pass-through', () {
    test('ShardError passes through', () async {
      final transformer = _makeTransformer();
      final results = await _transform(transformer, [
        ShardError(_shardIri, StateError('test'), StackTrace.current),
      ]);
      expect(results, hasLength(1));
      expect(results[0], isA<ShardError>());
    });

    test('ResourceError passes through', () async {
      final transformer = _makeTransformer();
      final results = await _transform(transformer, [
        ResourceError(_resIri, StateError('test'), StackTrace.current),
      ]);
      expect(results, hasLength(1));
      expect(results[0], isA<ResourceError>());
    });

    test('ShardComplete passes through', () async {
      final transformer = _makeTransformer();
      final results = await _transform(transformer, [
        ShardComplete(_shardIri, 42),
      ]);
      expect(results, hasLength(1));
      expect(results[0], isA<ShardComplete>());
    });

    test('PhaseComplete passes through', () async {
      final transformer = _makeTransformer();
      final results = await _transform(transformer, [
        PhaseComplete(_syncInput, 1),
      ]);
      expect(results, hasLength(1));
      expect(results[0], isA<PhaseComplete>());
    });

    test('PhaseError passes through', () async {
      final transformer = _makeTransformer();
      final results = await _transform(transformer, [
        PhaseError(StateError('test'), StackTrace.current, stage: 'S06'),
      ]);
      expect(results, hasLength(1));
      expect(results[0], isA<PhaseError>());
    });
  });
}
