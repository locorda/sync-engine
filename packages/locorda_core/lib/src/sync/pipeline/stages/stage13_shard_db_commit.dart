/// Stage 13: Shard DB Commit — persist merged shard documents to local DB.
///
/// Exact parallel to Stage 9 (DB Commit) for shard documents. Batches shard
/// document saves and ETag updates into transactions bounded by [batchSize].
/// Flushes eagerly when [batchSize] is reached and on [PhaseComplete].
///
/// Shard documents and remote ETags are written atomically per flush.
///
/// **Implementation**: `asyncExpand` with mutable batch state captured in
/// closure — safe because `asyncExpand` processes events sequentially.
///
/// **Input**: `Stream<UploadedShardEvent>`
/// **Output**: `Stream<CommittedShardEvent>`
library;

import 'dart:typed_data';

import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/storage/remote_id.dart';
import 'package:locorda_core/src/storage/storage_interface.dart';
import 'package:locorda_core/src/sync/pipeline/pipeperf.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';
import 'package:locorda_core/src/vocab/generated/_index.dart';
import 'package:locorda_rdf_core/core.dart';

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
  final pendingBytes = <Uint8List>[];
  final pendingEtags = <IriTerm, String>{};
  final pendingShardIris = <IriTerm>[];

  // Writes the entire pending batch atomically and yields ShardCommitResults.
  // No internal chunking — the caller controls batch size via [batchSize].
  Stream<ShardCommitResult> _flush() async* {
    if (pendingSaves.isEmpty && pendingEtags.isEmpty) return;

    final sw = perf?.start(perfStage);

    await storage.inTransaction(() async {
      if (pendingSaves.isNotEmpty) {
        await storage.saveDocuments(pendingSaves,
            preEncodedContents: pendingBytes);
      }
      if (pendingEtags.isNotEmpty) {
        await storage.setRemoteETags(remoteId, pendingEtags);
      }
    });

    sw?.stop();

    for (final shardIri in pendingShardIris) {
      yield ShardCommitResult(shardIri);
    }

    pendingSaves.clear();
    pendingBytes.clear();
    pendingEtags.clear();
    pendingShardIris.clear();
  }

  return (UploadedShardEvent event) async* {
    switch (event) {
      case PhaseComplete():
        yield* _flush();
        yield event;
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
        ));
        pendingBytes.add(merged.encodedForDb.bytes);

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
        yield event;
      case ShardComplete():
        // hasLocalChanges=false — no document to write, no ETag to update.
        yield ShardCommitResult(event.shardIri);
    }
  };
}
