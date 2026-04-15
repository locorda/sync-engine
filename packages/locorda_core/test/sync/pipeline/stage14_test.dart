/// Tests for Stage 14 (Feedback).
///
/// Verifies:
/// - [ShardError] collected in erroredShardIris, yielded (not re-injected)
/// - [ConflictedShard] collected, re-injected at [PhaseComplete]
/// - Errored shards removed from conflict set before re-injection
/// - Max retries exceeded → inputSink.close()
/// - Content phase complete → inputSink.close()
/// - [ShardCommitResult] and [ShardComplete] pass through
/// - [PhaseError] passes through unchanged
import 'dart:async';

import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_core/src/sync/pipeline/content_index_resolver.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';
import 'package:locorda_core/src/sync/pipeline/stages/stage14_feedback.dart';
import 'package:locorda_core/src/vocab/generated/_index.dart'
    show SyncManagedDocument;
import 'package:locorda_rdf_core/core.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Test data
// ---------------------------------------------------------------------------

final _shardIriA = IriTerm('tag:test,2025:shardA#shard');
final _shardIriB = IriTerm('tag:test,2025:shardB#shard');
final _indexIri = IriTerm('tag:test,2025:idx#index');

SyncInput _contentSyncInput({int retryCount = 0}) => SyncInput(
      [_indexIri],
      retryCount: retryCount,
    );

SyncInput _metaSyncInput({
  int retryCount = 0,
  Map<IriTerm, String>? metaIndexClockHashes,
}) =>
    SyncInput(
      [_indexIri],
      retryCount: retryCount,
      metaIndexClockHashes: metaIndexClockHashes ?? {_indexIri: 'hash-1'},
    );

// ---------------------------------------------------------------------------
// Stubs
// ---------------------------------------------------------------------------

class _RecordingSink implements StreamSink<SyncInput> {
  final List<SyncInput> added = [];
  bool closed = false;

  @override
  void add(SyncInput event) => added.add(event);

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future addStream(Stream<SyncInput> stream) => stream.forEach(add);

  @override
  Future close() async {
    closed = true;
  }

  @override
  Future get done => Future.value();
}

/// Storage that returns clock hashes matching the snapshot (stable).
class _StableClockStorage implements Storage {
  final Map<IriTerm, String> clockHashes;

  _StableClockStorage(this.clockHashes);

  @override
  Future<Map<IriTerm, StoredDocument?>> getDocumentsByIri(
    Iterable<IriTerm> documentIris, {
    int? ifChangedSincePhysicalClock,
  }) async {
    return {
      for (final iri in documentIris)
        if (clockHashes.containsKey(iri))
          iri: StoredDocument(
            documentIri: iri,
            document: _graphWithClockHash(clockHashes[iri]!),
            metadata: DocumentMetadata(ourPhysicalClock: 0, updatedAt: 0),
          ),
    };
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Storage that returns different clock hashes (unstable).
class _UnstableClockStorage implements Storage {
  @override
  Future<Map<IriTerm, StoredDocument?>> getDocumentsByIri(
    Iterable<IriTerm> documentIris, {
    int? ifChangedSincePhysicalClock,
  }) async {
    return {
      for (final iri in documentIris)
        iri: StoredDocument(
          documentIri: iri,
          document: _graphWithClockHash('changed-hash'),
          metadata: DocumentMetadata(ourPhysicalClock: 0, updatedAt: 0),
        ),
    };
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

RdfGraph _graphWithClockHash(String hash) {
  return RdfGraph.fromTriples([
    Triple(
      _indexIri,
      SyncManagedDocument.crdtClockHash,
      LiteralTerm(hash),
    ),
  ]);
}

class _StubIndexResolver implements ContentIndexResolver {
  final Map<IriTerm, IndexInputInfo> contentIndices;

  _StubIndexResolver({this.contentIndices = const {}});

  @override
  Future<Map<IriTerm, IndexInputInfo>> resolveContentIndices() async =>
      contentIndices;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Future<List<CommittedShardEvent>> _runS14(
  _RecordingSink sink,
  List<CommittedShardEvent> events, {
  Storage? storage,
  ContentIndexResolver? indexResolver,
}) async {
  final fn = feedback(
    sink,
    storage ?? _StableClockStorage({}),
    indexResolver ?? _StubIndexResolver(),
  );
  final results = <CommittedShardEvent>[];
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
  group('Stage 14 — pass-through events', () {
    test('ShardCommitResult passes through', () async {
      final sink = _RecordingSink();
      final results = await _runS14(sink, [
        ShardCommitResult(_shardIriA),
      ]);

      expect(results, hasLength(1));
      expect(results[0], isA<ShardCommitResult>());
    });

    test('PhaseComplete passes through (content phase → close)', () async {
      final sink = _RecordingSink();
      final results = await _runS14(sink, [
        PhaseComplete(_contentSyncInput(), 1),
      ]);

      expect(results, hasLength(1));
      expect(results[0], isA<PhaseComplete>());
      expect(sink.closed, isTrue);
    });
  });

  group('Stage 14 — ShardError handling', () {
    test('ShardError is yielded', () async {
      final sink = _RecordingSink();
      final results = await _runS14(sink, [
        ShardError(_shardIriA, StateError('fail'), StackTrace.current),
        PhaseComplete(_contentSyncInput(), 1),
      ]);

      final errors = results.whereType<ShardError>();
      expect(errors, hasLength(1));
      expect(errors.first.shardIri, equals(_shardIriA));
    });

    test('ShardError NOT re-injected — pipeline closes on content phase',
        () async {
      final sink = _RecordingSink();
      await _runS14(sink, [
        ShardError(_shardIriA, StateError('fail'), StackTrace.current),
        PhaseComplete(_contentSyncInput(), 1),
      ]);

      // Errored shards are NOT re-injected.
      expect(sink.added, isEmpty);
      expect(sink.closed, isTrue);
    });
  });

  group('Stage 14 — ConflictedShard handling', () {
    test('ConflictedShard is yielded', () async {
      final sink = _RecordingSink();
      final results = await _runS14(sink, [
        ConflictedShard(_shardIriA),
        PhaseComplete(_contentSyncInput(), 1),
      ]);

      final conflicts = results.whereType<ConflictedShard>();
      expect(conflicts, hasLength(1));
    });

    test('ConflictedShard → re-injection at PhaseComplete', () async {
      final sink = _RecordingSink();
      await _runS14(sink, [
        ConflictedShard(_shardIriA),
        PhaseComplete(_contentSyncInput(), 1),
      ]);

      expect(sink.added, hasLength(1));
      expect(sink.added.first.retryCount, equals(1));
      expect(sink.added.first.conflictedShardIris, contains(_shardIriA));
      expect(sink.closed, isFalse);
    });

    test('Errored shards removed from conflict set before re-injection',
        () async {
      final sink = _RecordingSink();
      await _runS14(sink, [
        ConflictedShard(_shardIriA),
        ConflictedShard(_shardIriB),
        ShardError(_shardIriA, StateError('fail'), StackTrace.current),
        PhaseComplete(_contentSyncInput(), 1),
      ]);

      expect(sink.added, hasLength(1));
      // Only _shardIriB should be re-injected.
      expect(sink.added.first.conflictedShardIris, isNot(contains(_shardIriA)));
      expect(sink.added.first.conflictedShardIris, contains(_shardIriB));
    });

    test('Max retries exceeded → inputSink.close()', () async {
      final sink = _RecordingSink();
      await _runS14(sink, [
        ConflictedShard(_shardIriA),
        PhaseComplete(_contentSyncInput(retryCount: 6), 1),
      ]);

      expect(sink.added, isEmpty);
      expect(sink.closed, isTrue);
    });
  });

  group('Stage 14 — meta phase stability', () {
    test('stable meta-indices → transition to content phase', () async {
      final hashes = {_indexIri: 'hash-1'};
      final sink = _RecordingSink();
      final contentIdx = IriTerm('tag:test,2025:content#index');

      await _runS14(
        sink,
        [PhaseComplete(_metaSyncInput(metaIndexClockHashes: hashes), 1)],
        storage: _StableClockStorage(hashes),
        indexResolver: _StubIndexResolver(contentIndices: {
          contentIdx: IndexInputInfo(
            contentIdx,
            RootResourceFetchPolicy.prefetch,
            IriTerm('tag:test,2025:Type'),
          ),
        }),
      );

      expect(sink.added, hasLength(1));
      expect(sink.added.first.indexIris, contains(contentIdx));
      expect(sink.added.first.metaIndexClockHashes, isNull);
    });

    test('unstable meta-indices → re-inject meta phase', () async {
      final hashes = {_indexIri: 'hash-1'};
      final sink = _RecordingSink();

      await _runS14(
        sink,
        [PhaseComplete(_metaSyncInput(metaIndexClockHashes: hashes), 1)],
        storage: _UnstableClockStorage(),
      );

      expect(sink.added, hasLength(1));
      expect(sink.added.first.retryCount, equals(1));
      expect(sink.added.first.metaIndexClockHashes, isNotNull);
    });

    test('unstable meta-indices at max retries → close', () async {
      final hashes = {_indexIri: 'hash-1'};
      final sink = _RecordingSink();

      await _runS14(
        sink,
        [
          PhaseComplete(
              _metaSyncInput(retryCount: 6, metaIndexClockHashes: hashes), 1)
        ],
        storage: _UnstableClockStorage(),
      );

      expect(sink.added, isEmpty);
      expect(sink.closed, isTrue);
    });

    test('stable meta-indices with no content indices → close', () async {
      final hashes = {_indexIri: 'hash-1'};
      final sink = _RecordingSink();

      await _runS14(
        sink,
        [PhaseComplete(_metaSyncInput(metaIndexClockHashes: hashes), 1)],
        storage: _StableClockStorage(hashes),
        indexResolver: _StubIndexResolver(contentIndices: {}),
      );

      expect(sink.added, isEmpty);
      expect(sink.closed, isTrue);
    });
  });

  group('Stage 14 — PhaseError pass-through', () {
    test('PhaseError passes through unchanged', () async {
      final sink = _RecordingSink();
      final results = await _runS14(sink, [
        PhaseError(StateError('test'), StackTrace.current, stage: 'S13'),
      ]);

      expect(results, hasLength(1));
      expect(results[0], isA<PhaseError>());
      expect(sink.closed, isFalse);
    });
  });
}
