/// Stage 13: Shard DB Commit — persist merged shard documents to local DB.
///
/// Exact parallel to Stage 9 (DB Commit) for shard documents. Batches shard
/// document saves and ETag updates into transactions bounded by [batchSize].
/// Flushes eagerly when [batchSize] is reached and on [PhaseComplete].
///
/// Shard documents and remote ETags are written atomically per flush.
///
/// The batch is **cross-shard**: multiple [UploadedShard] events from different
/// shards accumulate in one transaction. When a flush fails, all shards in the
/// pending batch receive the appropriate error event ([ConflictedShard] or
/// [ShardError]) directly from [_flush]. Terminal shard boundaries
/// ([ShardError], [ConflictedShard], [ShardSkipped]) are passed through without
/// touching pending state — they belong to other shards that will not commit to db.
///
/// [ShardComplete] means no [UploadedShard] was emitted for this shard (Stage
/// 12 had nothing to upload) — flush any cross-shard pending and emit
/// [ShardCommitResult] for this shard.
///
/// **Implementation**: `asyncExpand` with mutable batch state captured in
/// closure — safe because `asyncExpand` processes events sequentially.
///
/// **Input**: `Stream<UploadedShardEvent>`
/// **Output**: `Stream<CommittedShardEvent>`
library;

import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/storage/concurrent_update_exception.dart';
import 'package:locorda_core/src/storage/remote_id.dart';
import 'package:locorda_core/src/storage/storage_interface.dart';
import 'package:locorda_core/src/sync/pipeline/pipeperf.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';
import 'package:locorda_core/src/vocab/generated/_index.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:logging/logging.dart';

final _log = Logger('Stage13.ShardDbCommit');

/// Returns an asyncExpand function for Stage 13.
///
/// Usage: `stream.asyncExpand(shardDbCommit(storage, remoteId))`
///
/// Flushes when [batchSize] is reached and on [PhaseComplete] (final flush).
/// Shard documents and remote ETags are written atomically per flush.
Stream<CommittedShardEvent> Function(UploadedShardEvent) shardDbCommit(
  Storage storage,
  RemoteId remoteId, {
  int batchSize = defaultPipelineBatchSize,
  PipeperfCollector? perf,
  String perfStage = 'S13.ShardDbCommit',
}) {
  final pendingSaves = <SaveDocumentRequest>[];
  final pendingEtags = <IriTerm, String>{};
  final pendingShardIris = <IriTerm>[];
  // Shard document IRIs whose stored remote ETag should be cleared (set to
  // null) within the flush transaction — used for upstream ConflictedShard
  // events to force a fresh download on re-sync.
  final pendingEtagClears = <IriTerm>{};

  void _clearPending() {
    pendingSaves.clear();
    pendingEtags.clear();
    pendingShardIris.clear();
    pendingEtagClears.clear();
  }

  // Writes the pending batch atomically.
  //
  // On success: yields [ShardCommitResult] for every shard in the batch.
  // On [ConcurrentUpdateException]: yields [ConflictedShard] for every shard.
  // On other errors: yields [ShardError] for every shard.
  // In all cases the pending state is cleared afterwards.
  Stream<CommittedShardEvent> _flush() async* {
    if (pendingSaves.isEmpty &&
        pendingEtags.isEmpty &&
        pendingEtagClears.isEmpty) return;

    final sw = perf?.start(perfStage);

    // Snapshot all pending state into local variables before clearing, so the
    // transaction closure captures the correct data and _clearPending() can
    // reset the shared lists without affecting the in-flight batch.
    final flushSaves = List<SaveDocumentRequest>.of(pendingSaves);
    final flushEtags = Map<IriTerm, String>.of(pendingEtags);
    final flushShardIris = List<IriTerm>.of(pendingShardIris);
    final flushEtagClears = Set<IriTerm>.of(pendingEtagClears);
    _clearPending();

    try {
      await storage.inTransaction(() async {
        if (flushSaves.isNotEmpty) {
          await storage.saveDocuments(flushSaves);
        }
        if (flushEtags.isNotEmpty) {
          await storage.setRemoteETags(remoteId, flushEtags);
        }
        if (flushEtagClears.isNotEmpty) {
          await storage.clearRemoteETags(remoteId, flushEtagClears);
        }
      });
    } on ConcurrentUpdateException catch (e) {
      _log.info('Concurrent update during shard DB commit — '
          'affected shards will be re-injected: $e');
      // Clear stored ETags for all shards in the failed batch — forces
      // fresh downloads on re-sync (analogous to S9's pendingEtagClears).
      final docIris = flushShardIris.map((iri) => iri.getDocumentIri()).toSet();
      try {
        await storage.clearRemoteETags(remoteId, docIris);
      } catch (clearError, clearSt) {
        _log.warning('Failed to clear ETags after conflict: $clearError',
            clearError, clearSt);
      }
      for (final shardIri in flushShardIris) {
        yield ConflictedShard(shardIri,
            trigger: e, message: 'shardDbCommit._flush');
      }
      return;
    } catch (e, st) {
      _log.warning('Shard DB commit failed: $e', e, st);
      for (final shardIri in flushShardIris) {
        yield ShardError(shardIri, e, st);
      }
      return;
    }

    sw?.stop();

    for (final shardIri in flushShardIris) {
      yield ShardCommitResult(shardIri);
    }
  }

  return (UploadedShardEvent event) async* {
    switch (event) {
      // --- Shard Events ---
      case UploadedShard():
        final merged = event.mergedShard;
        final shardDocumentIri = merged.shardIri.getDocumentIri();
        pendingSaves.add(SaveDocumentRequest(
          documentIri: shardDocumentIri,
          typeIri: IdxShard.classIri,
          document: merged.mergedGraph.graph,
          metadata: DocumentMetadata(
            ourPhysicalClock: merged.ourPhysicalClock,
            updatedAt: DateTime.now().millisecondsSinceEpoch,
          ),
          changes: const [],
          encodedContent: merged.encodedForDb.bytes,
        ));

        final etag = event.remoteEtag;
        if (etag != null) {
          pendingEtags[shardDocumentIri] = etag;
        }

        pendingShardIris.add(merged.shardIri);

        if (pendingSaves.length >= batchSize ||
            pendingEtags.length >= batchSize) {
          yield* _flush();
        }
      case ConflictedShard():
        // Pass-through: belongs to a shard handled upstream (S09 or S12).
        // Clear stored ETag so re-sync forces a fresh download.
        pendingEtagClears.add(event.shardIri.getDocumentIri());
        yield event;
      case ShardError():
        // Pass-through: terminal shard boundary from an upstream stage.
        // Do NOT touch pending — it may contain data for other shards.
        yield event;
      case ShardSkipped():
        // Pass-through: no upload, no DB write needed.
        yield event;

      // --- Phase Events ---
      case PhaseComplete():
        yield* _flush();
        yield event;
      case PhaseError():
        _clearPending();
        yield event;
    }
  };
}
