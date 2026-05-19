/// Tests for Stage 9 (DB Commit).
///
/// Verifies:
/// - [ConcurrentUpdateException] during flush → [ConflictedShard] at boundary
/// - [ResourceError] from upstream → [ShardError] at boundary (safety net)
/// - [ConflictedResource] from S08 → [ConflictedShard] at boundary
/// - [ShardError] from upstream passes through unchanged
/// - Normal operation: [UploadResult] + [ShardComplete] → [ShardComplete]
/// - Error flags reset between shards
/// - PhaseError clears pending and passes through
library;
import 'dart:typed_data';

import 'package:locorda_core/src/index/index_manager.dart';
import 'package:locorda_core/src/index/shard_determiner.dart';
import 'package:locorda_core/src/storage/concurrent_update_exception.dart';
import 'package:locorda_core/src/storage/document_save_service.dart';
import 'package:locorda_core/src/storage/remote_id.dart';
import 'package:locorda_core/src/storage/storage_interface.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';
import 'package:locorda_core/src/sync/pipeline/stages/stage9_db_commit.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:locorda_rdf_jelly/jelly.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Test data
// ---------------------------------------------------------------------------

final _shardIriA = IriTerm('tag:test,2025:shardA#shard');
final _shardIriB = IriTerm('tag:test,2025:shardB#shard');
final _resIri1 = IriTerm('tag:test,2025:res1#it');
final _resIri2 = IriTerm('tag:test,2025:res2#it');
final _typeIri = IriTerm('tag:test,2025:Type');
final _remoteId = RemoteId('test', 'remote-1');
final _emptyGraph = RdfGraph();
final _syncInput = SyncInput([_shardIriA]);

UploadResult _uploadResult(IriTerm resourceIri) => UploadResult(
      MergeResult(
        resourceIri,
        _typeIri,
        DecodedGraphSource(_emptyGraph),
        BinaryGraphSource(Uint8List(0), contentType: jellyMimeType),
        needsUpload: true,
        needsDbWrite: true,
        clock: (
          logicalTime: 1,
          physicalTime: 1,
          fullClock: const [],
          hash: '',
        ),
        resolvedGroupIndices: const [],
        indexEntries: const [],
      ),
      newRemoteEtag: 'etag-1',
    );

ConflictedResource _conflictedResource(IriTerm resourceIri) =>
    ConflictedResource(
      resourceIri,
      mergeResult: MergeResult(
        resourceIri,
        _typeIri,
        DecodedGraphSource(_emptyGraph),
        BinaryGraphSource(Uint8List(0), contentType: jellyMimeType),
        needsUpload: true,
        needsDbWrite: true,
        clock: (
          logicalTime: 1,
          physicalTime: 1,
          fullClock: const [],
          hash: '',
        ),
        resolvedGroupIndices: const [],
        indexEntries: const [],
      ),
      message: 'Upload conflict',
    );

ShardComplete _shardComplete(IriTerm shardIri) => ShardComplete(shardIri, null);

// ---------------------------------------------------------------------------
// Storage/service stubs
// ---------------------------------------------------------------------------

class _SuccessStorage implements Storage {
  int transactionCount = 0;

  @override
  Future<T> inTransaction<T>(Future<T> Function() action) async {
    transactionCount++;
    return action();
  }

  @override
  Future<void> saveIndexEntries(
      Iterable<SaveIndexEntryRequest> requests) async {}

  @override
  Future<void> setRemoteETags(
      RemoteId remoteId, Map<IriTerm, String> etagsByDocument) async {}

  @override
  Future<void> clearRemoteETag(RemoteId remoteId, IriTerm documentIri) async {}

  @override
  Future<void> clearRemoteETags(
      RemoteId remoteId, Set<IriTerm> documentIris) async {}

  @override
  Future<Map<IriTerm, IriTerm>> getIndexIrisForShards(
          Iterable<IriTerm> shardIris) async =>
      {};

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ConflictStorage extends _SuccessStorage {
  @override
  Future<T> inTransaction<T>(Future<T> Function() action) async {
    transactionCount++;
    throw ConcurrentUpdateException('test conflict');
  }
}

class _ConflictOnceStorage extends _SuccessStorage {
  var _firstCall = true;

  @override
  Future<T> inTransaction<T>(Future<T> Function() action) async {
    transactionCount++;
    if (_firstCall) {
      _firstCall = false;
      throw ConcurrentUpdateException('first conflict');
    }
    return action();
  }
}

class _StubIndexManager implements IndexManager {
  @override
  Future<void> ensureGroupIndicesExist(
      Iterable<ResolvedGroupIndex> resolvedGroupIndices) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StubDocumentSaveService implements DocumentSaveService {
  @override
  Future<List<SaveDocumentResult>> saveDocuments(
    Iterable<SaveDocumentRequest> requests,
  ) async =>
      [
        for (final _ in requests)
          SaveDocumentResult(previousCursor: null, currentCursor: 'c1')
      ];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// ---------------------------------------------------------------------------
// Test runner
// ---------------------------------------------------------------------------

/// Runs events through S09's asyncExpand function sequentially.
Future<List<CommittedResourceEvent>> _runS09(
  Storage storage,
  List<UploadedResourceEvent> events, {
  IndexManager? indexManager,
  DocumentSaveService? saveService,
}) async {
  final fn = dbCommit(
    storage,
    indexManager ?? _StubIndexManager(),
    _remoteId,
    saveService ?? _StubDocumentSaveService(),
    batchSize: 100,
  );
  final results = <CommittedResourceEvent>[];
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
  group('Stage 9 — normal operation', () {
    test('UploadResult + ShardComplete → ShardComplete', () async {
      final storage = _SuccessStorage();
      final results = await _runS09(storage, [
        _uploadResult(_resIri1),
        _shardComplete(_shardIriA),
      ]);

      expect(results, hasLength(1));
      expect(results[0], isA<ShardComplete>());
      expect(storage.transactionCount, equals(1));
    });

    test('ShardError from upstream passes through', () async {
      final results = await _runS09(_SuccessStorage(), [
        ShardError(_shardIriA, StateError('upstream'), StackTrace.current),
      ]);

      expect(results, hasLength(1));
      expect(results[0], isA<ShardError>());
    });

    test('PhaseComplete triggers flush', () async {
      final storage = _SuccessStorage();
      final results = await _runS09(storage, [
        _uploadResult(_resIri1),
        PhaseComplete(_syncInput, 1),
      ]);

      expect(results, hasLength(1));
      expect(results[0], isA<PhaseComplete>());
    });
  });

  group('Stage 9 — ConcurrentUpdateException', () {
    test('ConcurrentUpdateException → ConflictedShard at ShardComplete',
        () async {
      final storage = _ConflictStorage();
      final results = await _runS09(storage, [
        _uploadResult(_resIri1),
        _shardComplete(_shardIriA),
      ]);

      expect(results, hasLength(1));
      expect(results[0], isA<ConflictedShard>());
      expect((results[0] as ConflictedShard).shardIri, equals(_shardIriA));
    });

    test('ConflictedShard flag resets — next shard succeeds', () async {
      final storage = _ConflictOnceStorage();
      final results = await _runS09(storage, [
        _uploadResult(_resIri1),
        _shardComplete(_shardIriA), // → ConflictedShard
        _uploadResult(_resIri2),
        _shardComplete(_shardIriB), // → ShardComplete
      ]);

      expect(results.whereType<ConflictedShard>(), hasLength(1));
      expect(results.whereType<ShardComplete>(), hasLength(1));
    });
  });

  group('Stage 9 — ResourceError safety net', () {
    test('ResourceError flags shard → ShardError at ShardComplete', () async {
      final storage = _SuccessStorage();
      final results = await _runS09(storage, [
        ResourceError(_resIri1, StateError('S08 error'), StackTrace.current),
        _shardComplete(_shardIriA),
      ]);

      expect(results, hasLength(1));
      expect(results[0], isA<ShardError>());
      expect((results[0] as ShardError).shardIri, equals(_shardIriA));
    });

    test('ResourceError flag resets — next shard succeeds', () async {
      final storage = _SuccessStorage();
      final results = await _runS09(storage, [
        ResourceError(_resIri1, StateError('error'), StackTrace.current),
        _shardComplete(_shardIriA), // → ConflictedShard
        _uploadResult(_resIri2),
        _shardComplete(_shardIriB), // → ShardComplete
      ]);

      expect(results.whereType<ShardError>(), hasLength(1));
      expect(results.whereType<ShardComplete>(), hasLength(1));
    });

    test('ConcurrentUpdateException takes priority over ResourceError',
        () async {
      // Both conflict and resource error in same shard — conflict wins
      final storage = _ConflictStorage();
      final results = await _runS09(storage, [
        ResourceError(_resIri1, StateError('error'), StackTrace.current),
        _uploadResult(_resIri2),
        _shardComplete(_shardIriA),
      ]);

      // ConcurrentUpdateException during flush → ConflictedShard,
      // not ShardError from the ResourceError.
      expect(results, hasLength(1));
      expect(results[0], isA<ConflictedShard>());
    });
  });

  group('Stage 9 — ConflictedResource promotion', () {
    test('ConflictedResource from S08 → ConflictedShard at ShardComplete',
        () async {
      final storage = _SuccessStorage();
      final results = await _runS09(storage, [
        _conflictedResource(_resIri1),
        _shardComplete(_shardIriA),
      ]);

      // ConflictedResource writes merge data to DB, then shard is
      // marked conflicted → ConflictedShard.
      expect(results, hasLength(1));
      expect(results[0], isA<ConflictedShard>());
      expect((results[0] as ConflictedShard).shardIri, equals(_shardIriA));
    });

    test(
        'ConflictedResource + successful UploadResult in same shard → '
        'ConflictedShard (conflict wins)', () async {
      final storage = _SuccessStorage();
      final results = await _runS09(storage, [
        _uploadResult(_resIri1),
        _conflictedResource(_resIri2),
        _shardComplete(_shardIriA),
      ]);

      // Both resources are committed (UploadResult + ConflictedResource
      // both write merge data to DB), but the shard is marked conflicted.
      expect(results, hasLength(1));
      expect(results[0], isA<ConflictedShard>());
    });

    test('ConflictedResource flag resets — next shard succeeds', () async {
      final storage = _SuccessStorage();
      final results = await _runS09(storage, [
        _conflictedResource(_resIri1),
        _shardComplete(_shardIriA), // → ConflictedShard
        _uploadResult(_resIri2),
        _shardComplete(_shardIriB), // → ShardComplete
      ]);

      expect(results.whereType<ConflictedShard>(), hasLength(1));
      expect(results.whereType<ShardComplete>(), hasLength(1));
    });

    test('ConcurrentUpdateException takes priority over ConflictedResource',
        () async {
      // ConflictedResource + ConcurrentUpdateException in same shard
      // — ConflictedShard is emitted (both set the flag, but the flag
      // was already true).
      final storage = _ConflictStorage();
      final results = await _runS09(storage, [
        _conflictedResource(_resIri1),
        _uploadResult(_resIri2),
        _shardComplete(_shardIriA),
      ]);

      expect(results, hasLength(1));
      expect(results[0], isA<ConflictedShard>());
    });
  });

  group('Stage 9 — PhaseError pass-through', () {
    test('PhaseError clears pending and passes through', () async {
      final storage = _SuccessStorage();
      final results = await _runS09(storage, [
        _uploadResult(_resIri1),
        PhaseError(StateError('test'), StackTrace.current, stage: 'S08'),
      ]);

      expect(results, hasLength(1));
      expect(results[0], isA<PhaseError>());
      // No flush/commit should occur.
      expect(storage.transactionCount, equals(0));
    });
  });
}
