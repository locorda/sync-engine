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
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/storage/document_save_service.dart';
import 'package:locorda_core/src/storage/remote_id.dart';
import 'package:locorda_core/src/storage/storage_interface.dart';
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
}) {
  final pendingSaves = <SaveDocumentRequest>[];
  final pendingIndexEntries = <SaveIndexEntryRequest>[];
  final pendingEtags = <IriTerm, String>{};
  final pendingResourceIris = <IriTerm>[];

  // Writes the entire pending batch atomically and yields CommitResults.
  // No internal chunking — the caller controls batch size via [batchSize].
  Stream<CommitResult> _flush() async* {
    if (pendingSaves.isEmpty && pendingEtags.isEmpty) return;

    await storage.inTransaction(() async {
      if (pendingSaves.isNotEmpty) {
        await documentSaveService.saveDocuments(pendingSaves);
      }
      if (pendingIndexEntries.isNotEmpty) {
        await storage.saveIndexEntries(pendingIndexEntries);
      }
      if (pendingEtags.isNotEmpty) {
        await storage.setRemoteETags(remoteId, pendingEtags);
      }
    });

    for (final iri in pendingResourceIris) {
      yield CommitResult(iri);
    }

    pendingSaves.clear();
    pendingIndexEntries.clear();
    pendingEtags.clear();
    pendingResourceIris.clear();
  }

  return (UploadedResourceEvent event) async* {
    switch (event) {
      case PhaseComplete():
        yield* _flush();
        yield event;
      case ShardComplete():
        yield* _flush();
        yield event;
      case UploadResult():
        final mergeResult = event.mergeResult;
        final etag = event.remoteEtag;

        if (!mergeResult.needsDbWrite) {
          // No DB write needed — still persist the ETag so subsequent
          // localOnly uploads (across multiple index shards) can use If-Match.
          if (etag != null) {
            pendingEtags[mergeResult.resourceIri.getDocumentIri()] = etag;
            if (pendingEtags.length >= batchSize) yield* _flush();
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

        try {
          // FIXME: potentially expensive to prepare index entry writes for every merged document
          final indexEntries = await indexManager.prepareIndexEntryWrites(
            document: mergeResult.mergedGraph.graph,
            documentIri: documentIri,
            resourceTypeIri: mergeResult.typeIri,
            physicalTime: mergeResult.clock.physicalTime,
            updatedAt: now,
            resolvedGroupIndices: mergeResult.resolvedGroupIndices,
          );
          pendingIndexEntries.addAll(indexEntries);
        } catch (e, st) {
          _log.warning(
              'prepareIndexEntryWrites failed for $documentIri: $e', e, st);
        }

        // Prefer upload-response ETag; fall back to stored remote ETag from
        // Stage 5 (needed for remoteOnly resources so subsequent localOnly
        // uploads can use If-Match).
        if (etag != null) {
          pendingEtags[documentIri] = etag;
        }

        pendingResourceIris.add(mergeResult.resourceIri);

        if (pendingSaves.length >= batchSize ||
            pendingEtags.length >= batchSize) {
          yield* _flush();
        }
    }
  };
}
