/// Tests for Stage 11a (Prepare Shard).
///
/// Verifies:
/// - [ShardError], [ConflictedShard], [ShardComplete], [PhaseComplete]
///   pass through unchanged
/// - [PhaseError] passes through unchanged
/// - Prepare failure → [ShardError]
library;
import 'package:locorda_core/src/config/sync_engine_config.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';
import 'package:locorda_core/src/sync/pipeline/stages/stage11a_prepare.dart';
import 'package:locorda_core/src/sync/shard_document_generator.dart';
import 'package:locorda_core/src/vocab/generated/idx/classes/shard.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Test data
// ---------------------------------------------------------------------------

final _shardIri = IriTerm('tag:test,2025:shardA#shard');
final _indexIri = IriTerm('tag:test,2025:index');
final _syncInput = SyncInput([_shardIri]);

ShardError _shardError() =>
    ShardError(_shardIri, StateError('test'), StackTrace.current);

ConflictedShard _conflictedShard() =>
    ConflictedShard(_shardIri, message: 'test');

PhaseComplete _phaseComplete() => PhaseComplete(_syncInput, 1);

// ---------------------------------------------------------------------------
// Stubs
// ---------------------------------------------------------------------------

final _rdfCore = RdfCore.withStandardCodecs();

class _StubSyncEngineConfig implements SyncEngineConfig {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ThrowingShardDocumentGenerator implements ShardDocumentGenerator {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
      'ShardDocumentGenerator should not be called for error events');
}

/// Generator that throws for any actual shard preparation.
class _FailingShardDocumentGenerator implements ShardDocumentGenerator {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('prepare failure');
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('Stage 11a — pass-through', () {
    late Iterable<PreparedShardEvent> Function(LoadedShardEntriesEvent) fn;

    setUp(() {
      fn = prepareShards(
        _ThrowingShardDocumentGenerator(),
        _StubSyncEngineConfig(),
        _rdfCore,
      );
    });

    test('ShardError passes through unchanged', () {
      final error = _shardError();
      final results = fn(error).toList();
      expect(results, hasLength(1));
      expect(results[0], same(error));
    });

    test('ConflictedShard passes through unchanged', () {
      final cs = _conflictedShard();
      final results = fn(cs).toList();
      expect(results, hasLength(1));
      expect(results[0], same(cs));
    });

    test('PhaseComplete passes through unchanged', () {
      final pc = _phaseComplete();
      final results = fn(pc).toList();
      expect(results, hasLength(1));
      expect(results[0], same(pc));
    });

    test('PhaseError passes through unchanged', () {
      final pe =
          PhaseError(StateError('test'), StackTrace.current, stage: 'S10');
      final results = fn(pe).toList();
      expect(results, hasLength(1));
      expect(results[0], same(pe));
    });
  });

  group('Stage 11a — error handling', () {
    test('Prepare failure → ShardError', () {
      final fn = prepareShards(
        _FailingShardDocumentGenerator(),
        _StubSyncEngineConfig(),
        _rdfCore,
      );

      // LoadedShardEntries with a remote graph containing the index IRI
      // so _extractIndexIri succeeds and _prepare reaches generateShardNodes.
      final remoteGraph = RdfGraph(triples: [
        Triple(_shardIri, IdxShard.isShardOf, _indexIri),
      ]);
      final event = LoadedShardEntries(
        _shardIri,
        42,
        const [],
        remoteShardGraph: DecodedGraphSource(remoteGraph),
      );

      final results = fn(event).toList();
      expect(results, hasLength(1));
      expect(results[0], isA<ShardError>());
      expect((results[0] as ShardError).shardIri, equals(_shardIri));
    });
  });
}
