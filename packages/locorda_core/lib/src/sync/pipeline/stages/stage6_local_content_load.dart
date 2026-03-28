/// Stage 6: Local Content Load — load local graph content from DB for merge.
///
/// **Implementation**: Custom `StreamTransformer` — chunked DB read.
///
/// **Input**: `Stream<FetchedCandidateEvent>`
/// **Output**: `Stream<LoadedCandidateEvent>`
library;

import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/storage/remote_id.dart';
import 'package:locorda_core/src/storage/storage_interface.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';

/// Returns an asyncExpand function for Stage 6.
///
/// Usage: `stream.asyncExpand(localContentLoad(storage, remoteId))`
///
/// Loads local document content for candidates that need it
/// (`conflictCandidate`, `localOnly`). `remoteOnly` candidates pass through
/// without a DB read. Boundaries pass through unchanged.
///
/// For `localOnly` candidates, also loads the stored remote ETag so
/// Stage 8 can perform conditional uploads (If-Match).
Stream<LoadedCandidateEvent> Function(FetchedCandidateEvent) localContentLoad(
  Storage storage,
  RemoteId remoteId,
) {
  return (FetchedCandidateEvent event) async* {
    switch (event) {
      case PhaseComplete():
        yield event;
      case  ShardComplete():
        yield event;
      case FetchedCandidate():
        final candidate = event.candidate;
        final documentIri = candidate.resourceIri.getDocumentIri();
        final doc = await storage.getDocument(documentIri);
        final RdfGraphSource? localSource =
            doc != null ? DecodedGraphSource(doc.document) : null;

        switch (candidate.direction) {
          case SyncDirection.remoteOnly:
          case SyncDirection.conflictCandidate:
          case SyncDirection.localOnly:
            final storedEtag =
                await storage.getRemoteETag(remoteId, documentIri);
            final etag = event.remoteEtag ?? storedEtag;
            print(
                'DEBUG S6: ${candidate.resourceIri.debug} dir=${candidate.direction} '
                'hasLocal=${localSource != null} hasRemote=${event.remoteSource != null} '
                'etag=$etag');
            yield LoadedCandidate(
              candidate,
              remoteSource: event.remoteSource,
              localSource: localSource,
              localUpdatedAt: doc?.metadata.updatedAt,
              remoteEtag: etag,
            );

          case SyncDirection.remoteRemoved:
            yield LoadedCandidate(
              candidate,
              localSource: localSource,
              localUpdatedAt: doc?.metadata.updatedAt,
            );
        }
    }
  };
}
