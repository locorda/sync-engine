/// Stage 9: DB Commit — persist merged resource documents to local DB.
///
/// Batches document saves, index entry updates, and ETag persists into
/// transactions bounded by [batchSize]. Flushes eagerly when [batchSize] is
/// reached, on [ShardComplete] so Stage 10 sees committed index entries, and
/// on [PhaseComplete] for the final flush.
///
/// Documents, index entries, and remote ETags are written atomically in a
/// single transaction per flush — no partial-commit inconsistency possible.
///
/// **Implementation**: `asyncExpand` with mutable batch state captured in
/// closure — safe because `asyncExpand` processes events sequentially.
///
/// **Input**: `Stream<UploadedResourceEvent>`
/// **Output**: `Stream<CommittedResourceEvent>`
library;

import 'package:locorda_core/src/index/index_manager.dart';
import 'package:locorda_core/src/index/shard_determiner.dart'
    show ResolvedGroupIndex;
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/storage/concurrent_update_exception.dart';
import 'package:locorda_core/src/storage/document_save_service.dart';
import 'package:locorda_core/src/storage/remote_id.dart';
import 'package:locorda_core/src/storage/storage_interface.dart';
import 'package:locorda_core/src/sync/pipeline/pipeperf.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:logging/logging.dart';

final _log = Logger('Stage9.DbCommit');

/// Returns an asyncExpand function for Stage 9.
///
/// Usage: `stream.asyncExpand(dbCommit(storage, indexManager, remoteId, saveService))`
///
/// Flushes when [batchSize] is reached, on [ShardComplete] (so Stage 10 sees
/// committed index entries), and on [PhaseComplete] (final flush).
/// Documents, index entries, and remote ETags are written atomically per flush.
Stream<CommittedResourceEvent> Function(UploadedResourceEvent) dbCommit(
  Storage storage,
  IndexManager indexManager,
  RemoteId remoteId,
  DocumentSaveService documentSaveService, {
  int batchSize = defaultPipelineBatchSize,
  PipeperfCollector? perf,
  String perfStage = 'S09.DbCommit',
}) {
  final pendingSaves = <SaveDocumentRequest>[];
  final pendingIndexEntries = <SaveIndexEntryRequest>[];
  final pendingEtags = <IriTerm, String>{};
  // Collect resolved GroupIndices across the batch for batched creation.
  final pendingGroupIndices = <IriTerm, ResolvedGroupIndex>{};
  // Track GroupIndex IRIs already confirmed to exist (avoids repeated DB lookups).
  final ensuredGroupIndices = <IriTerm>{};
  // Tombstoned shard IRIs awaiting indexIri resolution in _flush().
  final pendingTombstones = <({
    IriTerm shardIri,
    IriTerm typeIri,
    IriTerm resourceIri,
    int physicalTime
  })>[];
  // Document IRIs whose stored remote ETag should be cleared (set to null)
  // within the flush transaction — used for ConflictedResource events where
  // the CRDT merge data is saved but the upload ETag is invalidated.
  final pendingEtagClears = <IriTerm>{};

  // Track whether the current shard's flush failed due to a concurrent
  // update — set by _flush(), read by the ShardComplete handler.
  var _currentShardConflicted = false;

  // Track resource errors within the current shard — if any, the shard
  // is converted to a ShardError at the ShardComplete boundary.
  Object? _currentShardError;
  StackTrace? _currentShardErrorStack;

  void _clearPending() {
    pendingSaves.clear();
    pendingIndexEntries.clear();
    pendingEtags.clear();
    pendingEtagClears.clear();
    pendingGroupIndices.clear();
    pendingTombstones.clear();
  }

  // Writes the entire pending batch atomically.
  // No internal chunking — the caller controls batch size via [batchSize].
  //
  // On [ConcurrentUpdateException] the transaction is rolled back by the
  // storage layer, all pending state is cleared, and [_currentShardConflicted]
  // is set so the [ShardComplete] handler can emit [ConflictedShard].
  Future<void> _flush() async {
    if (pendingSaves.isEmpty &&
        pendingEtags.isEmpty &&
        pendingEtagClears.isEmpty &&
        pendingGroupIndices.isEmpty &&
        pendingTombstones.isEmpty) {
      return;
    }

    final sw = perf?.start(perfStage);

    // Ensure GroupIndex documents exist before writing index entries.
    if (pendingGroupIndices.isNotEmpty) {
      final unchecked = pendingGroupIndices.values
          .where((r) => !ensuredGroupIndices.contains(r.groupIndexIri))
          .toList();
      if (unchecked.isNotEmpty) {
        try {
          await indexManager.ensureGroupIndicesExist(unchecked);
          ensuredGroupIndices.addAll(unchecked.map((r) => r.groupIndexIri));
        } catch (e, st) {
          _log.warning('ensureGroupIndicesExist failed: $e', e, st);
        }
      }
      pendingGroupIndices.clear();
    }

    // Resolve tombstone indexIris from IndexShards table before entering the transaction.
    if (pendingTombstones.isNotEmpty) {
      final allShardIris = pendingTombstones.map((t) => t.shardIri).toSet();
      final indexMap = await storage.getIndexIrisForShards(allShardIris);
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final t in pendingTombstones) {
        final indexIri = indexMap[t.shardIri];
        if (indexIri == null) {
          _log.fine('No stored indexIri for tombstoned shard '
              '${t.shardIri} — skipping');
          continue;
        }
        pendingIndexEntries.add(SaveIndexEntryRequest(
          shardIri: t.shardIri,
          indexIri: indexIri,
          resourceIri: t.resourceIri,
          resourceType: t.typeIri,
          clockHash: '',
          isDeleted: true,
          ourPhysicalClock: t.physicalTime,
          updatedAt: now,
        ));
      }
      pendingTombstones.clear();
    }
    final flushSaves = List<SaveDocumentRequest>.of(pendingSaves);
    final flushIndexEntries =
        List<SaveIndexEntryRequest>.of(pendingIndexEntries);
    final flushEtags = Map<IriTerm, String>.of(pendingEtags);
    final flushEtagClears = Set<IriTerm>.of(pendingEtagClears);
    _clearPending();

    try {
      await storage.inTransaction(() async {
        if (flushSaves.isNotEmpty) {
          await documentSaveService.saveDocuments(flushSaves);
        }
        if (flushIndexEntries.isNotEmpty) {
          await storage.saveIndexEntries(flushIndexEntries);
        }
        if (flushEtags.isNotEmpty) {
          await storage.setRemoteETags(remoteId, flushEtags);
        }
        if (flushEtagClears.isNotEmpty) {
          await storage.clearRemoteETags(remoteId, flushEtagClears);
        }
      });
    } on ConcurrentUpdateException catch (e) {
      _log.info('Concurrent update during DB commit — '
          'shard will be re-injected: $e');
      _currentShardConflicted = true;
      // Note: here, we are effectively discarding all resource events instead of converting them to conflict events
      return;
    } catch (e, st) {
      _log.warning('DB commit failed: $e', e, st);
      _currentShardError ??= e;
      _currentShardErrorStack ??= st;
      // Note: here, we are effectively discarding all resource events instead of converting them to error events
      return;
    }

    sw?.stop();
  }

  void _clearCurrentShardState() {
    _currentShardConflicted = false;
    _currentShardError = null;
    _currentShardErrorStack = null;
  }

  /// Enqueues a [MergeResult] for DB write: document save, index entries,
  /// tombstones, group indices, and resource IRI tracking.
  void _enqueueMergeForDb(MergeResult mergeResult) {
    final documentIri = mergeResult.resourceIri.getDocumentIri();
    final now = DateTime.now().millisecondsSinceEpoch;

    pendingSaves.add(SaveDocumentRequest(
      documentIri: documentIri,
      typeIri: mergeResult.typeIri,
      document: mergeResult.mergedGraph.graph,
      metadata: DocumentMetadata(
        ourPhysicalClock: mergeResult.clock.physicalTime,
        updatedAt: now,
      ),
      changes: const [],
      ifMatchUpdatedAt: mergeResult.localUpdatedAt,
      encodedContent: mergeResult.encodedForDb.bytes,
    ));

    for (final entry in mergeResult.indexEntries) {
      pendingIndexEntries.add(entry.withUpdatedAt(now));
    }
    for (final shardIri in mergeResult.tombstonedShardIris) {
      pendingTombstones.add((
        shardIri: shardIri,
        resourceIri: mergeResult.resourceIri,
        typeIri: mergeResult.typeIri,
        physicalTime: mergeResult.clock.physicalTime,
      ));
    }
    for (final resolved in mergeResult.resolvedGroupIndices) {
      pendingGroupIndices[resolved.groupIndexIri] = resolved;
    }
  }

  return (UploadedResourceEvent event) async* {
    switch (event) {
      // --- Resource Events ---
      case ResourceError():
        // Resource-level failure propagated from upstream stages (including
        // backend-specific S08 implementations). Flag the shard so a terminal
        // ShardError is emitted at shard boundary.
        _currentShardError ??= event.error;
        _currentShardErrorStack ??= event.stackTrace;
        _log.warning('Resource error in shard: '
            '${event.resourceIri.debug}: ${event.error}');
      // Note: we are effectively swallowing the ResourceError here.

      case ConflictedResource():
        // Resource upload rejected (ETag mismatch) — the CRDT merge was
        // correct, only the upload failed. Persist the merge data locally
        // and clear the stored remote ETag to force a fresh fetch on retry.
        // Also, flagging the shard is important so it is not persisted but re-processed.
        _currentShardConflicted = true;
        _log.info('Resource upload conflict in shard: '
            '${event.resourceIri.debug}: ${event.message}');

        // Clear the stored ETag unconditionally — the upload failed so we
        // don't know the current remote state, regardless of whether the
        // merge result needs a DB write.
        pendingEtagClears.add(event.mergeResult.resourceIri.getDocumentIri());

        if (event.mergeResult.needsDbWrite) {
          _enqueueMergeForDb(event.mergeResult);

          if (pendingSaves.length >= batchSize ||
              pendingEtags.length >= batchSize) {
            await _flush();
          }
        }

      case UploadResult():
        final mergeResult = event.mergeResult;
        final etag = event.remoteEtag;

        if (!mergeResult.needsDbWrite) {
          // No DB write needed — still persist the ETag so subsequent
          // localOnly uploads (across multiple index shards) can use If-Match.
          if (etag != null) {
            pendingEtags[mergeResult.resourceIri.getDocumentIri()] = etag;
            if (pendingEtags.length >= batchSize) await _flush();
          }
          return;
        }

        _enqueueMergeForDb(mergeResult);

        if (etag != null) {
          pendingEtags[mergeResult.resourceIri.getDocumentIri()] = etag;
        }

        if (pendingSaves.length >= batchSize ||
            pendingEtags.length >= batchSize) {
          await _flush();
        }

      // --- Shard Events ---
      case ShardComplete():
        await _flush();
        if (_currentShardConflicted) {
          _clearCurrentShardState();
          yield ConflictedShard(event.shardIri,
              trigger: event, message: "dbCommit.ShardComplete");
        } else if (_currentShardError != null) {
          final error = _currentShardError!;
          final stack = _currentShardErrorStack!;
          _clearCurrentShardState();
          yield ShardError(event.shardIri, error, stack);
        } else {
          _clearCurrentShardState();
          yield event;
        }

      case ShardError():
        // Terminal shard boundary: discard any partial data and reset
        // per-shard state so the next shard starts clean.
        //
        // Note: this might swallow resource events that were part of the failed
        // shard, but that's acceptable since the shard is being aborted due to an error.
        _clearPending();
        _clearCurrentShardState();
        yield event;

      case ShardSkipped():
        assert(
            pendingSaves.isEmpty &&
                pendingTombstones.isEmpty &&
                pendingGroupIndices.isEmpty,
            'S09: pending state not empty at ShardSkipped — '
            'upstream protocol violation');
        if (pendingSaves.isNotEmpty ||
            pendingTombstones.isNotEmpty ||
            pendingGroupIndices.isNotEmpty) {
          _log.severe('S09: pending state unexpectedly non-empty '
              'at ShardSkipped for ${event.shardIri} — clearing');
          _clearPending();
        }
        yield event;

      // --- Phase Events ---
      case PhaseComplete():
        await _flush();
        _clearCurrentShardState();
        yield event;

      case PhaseError():
        _clearPending();
        _clearCurrentShardState();
        yield event;
    }
  };
}
