/// Stage 6: Local Content Load — load local graph content from DB for merge.
///
/// **Implementation**: Custom `StreamTransformer` — chunked DB read.
///
/// **Input**: `Stream<FetchedCandidate | ShardComplete | PhaseComplete>`
/// **Output**: `Stream<LoadedCandidate | ShardComplete | PhaseComplete>`
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
Stream<Object> Function(Object) localContentLoad(
  Storage storage,
  RemoteId remoteId,
) {
  return (Object event) async* {
    if (event is Boundary) {
      yield event;
      return;
    }

    final fetched = event as FetchedCandidate;
    final candidate = fetched.candidate;

    final documentIri = candidate.resourceIri.getDocumentIri();
    final doc = await storage.getDocument(documentIri);
    final RdfGraphSource? localSource =
        doc != null ? DecodedGraphSource(doc.document) : null;

    switch (candidate.direction) {
      case SyncDirection.remoteOnly:
      case SyncDirection.conflictCandidate:
      case SyncDirection.localOnly:
        final storedEtag = await storage.getRemoteETag(remoteId, documentIri);
        final etag = fetched.remoteEtag ?? storedEtag;
        print('DEBUG S6: ${candidate.resourceIri.debug} dir=${candidate.direction} '
            'hasLocal=${localSource != null} hasRemote=${fetched.remoteSource != null} '
            'etag=$etag');
        yield LoadedCandidate(
          candidate,
          remoteSource: fetched.remoteSource,
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
  };
}
