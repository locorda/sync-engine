/// Stage 9: DB Commit — persist merged resource documents to local DB.
///
/// Batches document saves, index entry updates, and ETag persists into
/// chunked transactions (max 500 items per transaction). Flushes on
/// [ShardComplete] to ensure Stage 10 loads up-to-date index entries.
///
/// **Implementation**: `asyncExpand` with mutable batch state captured in
/// closure — safe because `asyncExpand` processes events sequentially.
///
/// **Input**: `Stream<UploadResult | ShardComplete | PhaseComplete>`
/// **Output**: `Stream<CommitResult | ShardComplete | PhaseComplete>`
library;

import 'package:locorda_core/src/index/index_manager.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/storage/remote_id.dart';
import 'package:locorda_core/src/storage/storage_interface.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:logging/logging.dart';

final _log = Logger('Stage9.DbCommit');
const _chunkSize = 500;

/// Returns an asyncExpand function for Stage 9.
///
/// Usage: `stream.asyncExpand(dbCommit(storage, indexManager, remoteId))`
///
/// Flushes the batch on [ShardComplete] (so Stage 10 sees committed index
/// entries) and on [PhaseComplete] (final flush).
Stream<Object> Function(Object) dbCommit(
  Storage storage,
  IndexManager indexManager,
  RemoteId remoteId,
) {
  final pendingSaves = <SaveDocumentRequest>[];
  final pendingIndexEntries = <SaveIndexEntryRequest>[];
  final pendingEtags = <IriTerm, String>{};
  final pendingResourceIris = <IriTerm>[];

  Future<Iterable<Object>> _flush() async {
    if (pendingSaves.isEmpty && pendingEtags.isEmpty) {
      return const [];
    }

    final results = <Object>[];

    // Chunk saves + index entries together (same chunk boundaries).
    // ETag map is usually small — always written atomically at end.
    for (var i = 0; i < pendingSaves.length; i += _chunkSize) {
      final saveChunk =
          pendingSaves.sublist(i, i + _chunkSize > pendingSaves.length ? pendingSaves.length : i + _chunkSize);
      final indexChunk = pendingIndexEntries.isNotEmpty
          ? pendingIndexEntries.sublist(i, i + _chunkSize > pendingIndexEntries.length ? pendingIndexEntries.length : i + _chunkSize)
          : const <SaveIndexEntryRequest>[];

      if (storage case TransactionalStorage txStorage) {
        await txStorage.inTransaction(() async {
          await storage.saveDocuments(saveChunk);
          if (indexChunk.isNotEmpty) {
            await storage.saveIndexEntries(indexChunk);
          }
        });
      } else {
        await storage.saveDocuments(saveChunk);
        if (indexChunk.isNotEmpty) {
          await storage.saveIndexEntries(indexChunk);
        }
      }
    }

    // Persist ETags (separate — usually very small).
    if (pendingEtags.isNotEmpty) {
      await storage.setRemoteETags(remoteId, pendingEtags);
    }

    for (final iri in pendingResourceIris) {
      results.add(CommitResult(iri));
    }

    pendingSaves.clear();
    pendingIndexEntries.clear();
    pendingEtags.clear();
    pendingResourceIris.clear();

    return results;
  }

  return (Object event) async* {
    if (event is ShardComplete) {
      // Flush before passing ShardComplete downstream so Stage 10 sees
      // committed index entries when it calls getActiveIndexEntriesForShard.
      for (final r in await _flush()) {
        yield r;
      }
      yield event;
      return;
    }

    if (event is PhaseComplete) {
      for (final r in await _flush()) {
        yield r;
      }
      yield event;
      return;
    }

    final upload = event as UploadResult;
    final mergeResult = upload.mergeResult;

    if (!mergeResult.needsDbWrite) {
      yield CommitResult(mergeResult.resourceIri);
      return;
    }

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
    ));

    // Update index entries with post-merge clock hash.
    try {
      final indexEntries = await indexManager.prepareIndexEntryWrites(
        document: mergeResult.mergedGraph.graph,
        documentIri: documentIri,
        resourceTypeIri: mergeResult.typeIri,
        physicalTime: mergeResult.clock.physicalTime,
        updatedAt: now,
        missingGroupIndices: mergeResult.missingGroupIndices,
      );
      pendingIndexEntries.addAll(indexEntries);
    } catch (e, st) {
      _log.warning('prepareIndexEntryWrites failed for $documentIri: $e', e, st);
    }

    // Capture ETag if upload produced one.
    if (upload.newRemoteEtag != null) {
      pendingEtags[documentIri] = upload.newRemoteEtag!;
    }

    pendingResourceIris.add(mergeResult.resourceIri);

    // Flush when chunk is full.
    if (pendingSaves.length >= _chunkSize) {
      for (final r in await _flush()) {
        yield r;
      }
    }
  };
}
