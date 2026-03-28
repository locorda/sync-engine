/// Stage 13: Shard DB Commit — persist merged shard documents to local DB.
///
/// Exact parallel to Stage 9 (DB Commit) for shard documents. Batches shard
/// document saves and ETag updates in chunked transactions (max 500 per tx).
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
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';
import 'package:locorda_core/src/vocab/generated/_index.dart';
import 'package:locorda_rdf_core/core.dart';

const _chunkSize = 500;

/// Returns an asyncExpand function for Stage 13.
///
/// Usage: `stream.asyncExpand(shardDbCommit(storage, remoteId))`
///
/// Flushes the remaining batch on [PhaseComplete] before passing it through.
Stream<CommittedShardEvent> Function(UploadedShardEvent) shardDbCommit(
  Storage storage,
  RemoteId remoteId,
) {
  final pendingSaves = <SaveDocumentRequest>[];
  final pendingBytes = <Uint8List>[];
  final pendingEtags = <IriTerm, String>{};
  final pendingShardIris = <IriTerm>[];

  Future<Iterable<ShardCommitResult>> _flush() async {
    if (pendingSaves.isEmpty && pendingEtags.isEmpty) return const [];

    final results = <ShardCommitResult>[];

    for (var i = 0; i < pendingSaves.length; i += _chunkSize) {
      final end = (i + _chunkSize).clamp(0, pendingSaves.length);
      final saveChunk = pendingSaves.sublist(i, end);
      final bytesChunk = pendingBytes.sublist(i, end);

      if (storage case TransactionalStorage txStorage) {
        await txStorage.inTransaction(() async {
          await storage.saveDocuments(saveChunk,
              preEncodedContents: bytesChunk);
        });
      } else {
        await storage.saveDocuments(saveChunk, preEncodedContents: bytesChunk);
      }
    }

    if (pendingEtags.isNotEmpty) {
      await storage.setRemoteETags(remoteId, pendingEtags);
    }

    for (final shardIri in pendingShardIris) {
      results.add(ShardCommitResult(shardIri));
    }

    pendingSaves.clear();
    pendingBytes.clear();
    pendingEtags.clear();
    pendingShardIris.clear();

    return results;
  }

  return (UploadedShardEvent event) async* {
    switch (event) {
      case PhaseComplete():
        for (final r in await _flush()) yield r;
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

        final etagToStore = event.newRemoteEtag ?? merged.newEtag;
        if (etagToStore != null) {
          pendingEtags[shardDocumentIri] = etagToStore;
        }

        pendingShardIris.add(merged.shardIri);

        if (pendingSaves.length >= _chunkSize) {
          for (final r in await _flush()) yield r;
        }
    }
  };
}
