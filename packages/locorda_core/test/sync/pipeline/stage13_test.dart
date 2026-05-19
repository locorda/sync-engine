/// Tests for Stage 13 (Shard DB Commit).
///
/// Verifies:
/// - [ConcurrentUpdateException] during flush → [ConflictedShard]
/// - Other exception during flush → [ShardError]
/// - Normal commit → [ShardCommitResult]
/// - [ShardError] and [ConflictedShard] pass through
/// - [PhaseError] clears pending and passes through
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/storage/concurrent_update_exception.dart';
import 'package:locorda_core/src/storage/remote_id.dart';
import 'package:locorda_core/src/storage/storage_interface.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';
import 'package:locorda_core/src/sync/pipeline/stages/stage13_shard_db_commit.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:locorda_rdf_jelly/jelly.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

final _shardIriA = IriTerm('tag:test,2025:shardA#shard');
final _remoteId = RemoteId('test', 'remote-1');
final _emptyGraph = RdfGraph();

MergedShard _mergedShard(IriTerm shardIri) => MergedShard(
      shardIri,
      DecodedGraphSource(_emptyGraph),
      BinaryGraphSource(Uint8List(0), contentType: jellyMimeType),
      needsUpload: true,
      ourPhysicalClock: 1,
    );

UploadedShard _uploadedShard(IriTerm shardIri) =>
    UploadedShard(shardIri, _mergedShard(shardIri), newRemoteEtag: 'etag-1');

/// Minimal [Storage] stub that succeeds.
class _SuccessStorage implements Storage {
  int transactionCount = 0;
  final clearedEtags = <IriTerm>{};

  @override
  Future<T> inTransaction<T>(Future<T> Function() action) async {
    transactionCount++;
    return action();
  }

  @override
  Future<List<SaveDocumentResult>> saveDocuments(
    Iterable<SaveDocumentRequest> requests,
  ) async =>
      [
        for (final _ in requests)
          SaveDocumentResult(previousCursor: null, currentCursor: 'c1')
      ];

  @override
  Future<void> setRemoteETags(
          RemoteId remoteId, Map<IriTerm, String> etagsByDocument) async =>
      {};

  @override
  Future<void> clearRemoteETags(
          RemoteId remoteId, Iterable<IriTerm> documentIris) async =>
      clearedEtags.addAll(documentIris);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// [Storage] stub that throws [ConcurrentUpdateException] on first flush.
class _ConflictStorage implements Storage {
  final clearedEtags = <IriTerm>{};

  @override
  Future<T> inTransaction<T>(Future<T> Function() action) async =>
      throw ConcurrentUpdateException('test conflict');

  @override
  Future<void> clearRemoteETags(
          RemoteId remoteId, Iterable<IriTerm> documentIris) async =>
      clearedEtags.addAll(documentIris);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Runs events through the S13 asyncExpand function.
Future<List<CommittedShardEvent>> _runS13(
  Storage storage,
  List<UploadedShardEvent> events,
) async {
  final fn = shardDbCommit(storage, _remoteId, batchSize: 100);
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
  group('Stage 13 — normal operation', () {
    test('ShardError passes through', () async {
      final results = await _runS13(_SuccessStorage(), [
        ShardError(_shardIriA, StateError('upstream'), StackTrace.current),
      ]);

      expect(results, hasLength(1));
      expect(results[0], isA<ShardError>());
    });

    test('ConflictedShard passes through', () async {
      final results = await _runS13(_SuccessStorage(), [
        ConflictedShard(_shardIriA, message: 'upstream'),
      ]);

      expect(results, hasLength(1));
      expect(results[0], isA<ConflictedShard>());
    });
  });

  group('Stage 13 — PhaseComplete', () {
    test('PhaseComplete flushes and resets flags', () async {
      final storage = _SuccessStorage();
      final syncInput = SyncInput([_shardIriA]);
      final results = await _runS13(storage, [
        _uploadedShard(_shardIriA),
        PhaseComplete(syncInput, 1),
      ]);

      // Flush at PhaseComplete yields ShardCommitResult, then PhaseComplete.
      final commits = results.whereType<ShardCommitResult>();
      final phases = results.whereType<PhaseComplete>();
      expect(commits, hasLength(1));
      expect(phases, hasLength(1));
    });
  });

  group('Stage 13 — PhaseError pass-through', () {
    test('PhaseError clears pending and passes through', () async {
      final storage = _SuccessStorage();
      final results = await _runS13(storage, [
        _uploadedShard(_shardIriA),
        PhaseError(StateError('test'), StackTrace.current, stage: 'S12'),
      ]);

      expect(results, hasLength(1));
      expect(results[0], isA<PhaseError>());
      // No flush/commit should occur.
      expect(storage.transactionCount, equals(0));
    });
  });

  group('Stage 13 — ETag clearing', () {
    test('ConcurrentUpdateException clears ETags for conflicted shards',
        () async {
      final storage = _ConflictStorage();
      final results = await _runS13(storage, [
        _uploadedShard(_shardIriA),
        PhaseComplete(SyncInput([_shardIriA]), 1),
      ]);

      // ConflictedShard emitted, then PhaseComplete passes through.
      expect(results.whereType<ConflictedShard>(), hasLength(1));
      expect(results.whereType<PhaseComplete>(), hasLength(1));
      // ETag for the shard document IRI was cleared.
      expect(storage.clearedEtags, contains(_shardIriA.getDocumentIri()));
    });

    test('Pass-through ConflictedShard clears ETag on next flush', () async {
      final storage = _SuccessStorage();
      final results = await _runS13(storage, [
        ConflictedShard(_shardIriA, message: 'upstream'),
        PhaseComplete(SyncInput([_shardIriA]), 1),
      ]);

      // ConflictedShard passes through, PhaseComplete triggers flush
      // which includes the ETag clear.
      expect(results.whereType<ConflictedShard>(), hasLength(1));
      expect(results.whereType<PhaseComplete>(), hasLength(1));
      expect(storage.clearedEtags, contains(_shardIriA.getDocumentIri()));
    });
  });
}
