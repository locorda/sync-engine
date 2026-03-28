/// Stage 9: DB Commit — persist merged resource documents to local DB.
///
/// Batches document saves, index entry updates, and ETag persists into
/// chunked transactions (max 500 items per transaction). Flushes on
/// [ShardComplete] to ensure Stage 10 loads up-to-date index entries.
///
/// **Implementation**: `asyncExpand` with mutable batch state captured in
/// closure — safe because `asyncExpand` processes events sequentially.
///
/// **Input**: `Stream<UploadedResourceEvent>`
/// **Output**: `Stream<CommittedResourceEvent>`
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
Stream<CommittedResourceEvent> Function(UploadedResourceEvent) dbCommit(
  Storage storage,
  IndexManager indexManager,
  RemoteId remoteId,
) {
  final pendingSaves = <SaveDocumentRequest>[];
  final pendingIndexEntries = <SaveIndexEntryRequest>[];
  final pendingEtags = <IriTerm, String>{};
  final pendingResourceIris = <IriTerm>[];

  Future<Iterable<CommitResult>> _flush() async {
    if (pendingSaves.isEmpty && pendingEtags.isEmpty) {
      return const [];
    }

    final results = <CommitResult>[];

    // Chunk saves + index entries together (same chunk boundaries).
    // ETag map is usually small — always written atomically at end.
    for (var i = 0; i < pendingSaves.length; i += _chunkSize) {
      final saveChunk = pendingSaves.sublist(
          i,
          i + _chunkSize > pendingSaves.length
              ? pendingSaves.length
              : i + _chunkSize);
      final indexChunk = pendingIndexEntries.isNotEmpty
          ? pendingIndexEntries.sublist(
              i,
              i + _chunkSize > pendingIndexEntries.length
                  ? pendingIndexEntries.length
                  : i + _chunkSize)
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

  return (UploadedResourceEvent event) async* {
    switch (event) {
      case UploadedResourceBoundary(:final boundary):
        for (final r in await _flush()) yield r;
        yield CommittedResourceBoundary(boundary);
      case UploadResult():
        final mergeResult = event.mergeResult;

        if (!mergeResult.needsDbWrite) {
          // Still store ETag even without DB write — needed for subsequent
          // uploads of the same resource (e.g., localOnly processed through
          // multiple index shards).
          final etag = event.newRemoteEtag ?? mergeResult.resourceEtag;
          if (etag != null) {
            final docIri = mergeResult.resourceIri.getDocumentIri();
            pendingEtags[docIri] = etag;
          }
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
          _log.warning(
              'prepareIndexEntryWrites failed for $documentIri: $e', e, st);
        }

        // Capture ETag: prefer upload result, fall back to download ETag.
        // The download ETag (from Stage 5) is needed for remoteOnly resources
        // so that subsequent localOnly uploads can use If-Match.
        final etag = event.newRemoteEtag ?? mergeResult.resourceEtag;
        if (etag != null) {
          pendingEtags[documentIri] = etag;
        }
        print(
            'DEBUG S9: ${mergeResult.resourceIri.debug} uploadEtag=${event.newRemoteEtag} '
            'resourceEtag=${mergeResult.resourceEtag} stored=$etag needsUpload=${mergeResult.needsUpload}');

        pendingResourceIris.add(mergeResult.resourceIri);

        // Flush when chunk is full.
        if (pendingSaves.length >= _chunkSize) {
          for (final r in await _flush()) yield r;
        }
    }
  };
}
