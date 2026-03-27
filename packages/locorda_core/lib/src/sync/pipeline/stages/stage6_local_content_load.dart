/// Stage 6: Local Content Load — load local graph content from DB for merge.
///
/// **Implementation**: Custom `StreamTransformer` — chunked DB read.
///
/// **Input**: `Stream<FetchedCandidate | ShardComplete | PhaseComplete>`
/// **Output**: `Stream<LoadedCandidate | ShardComplete | PhaseComplete>`
library;

import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/storage/storage_interface.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';

/// Returns an asyncExpand function for Stage 6.
///
/// Usage: `stream.asyncExpand(localContentLoad(storage))`
///
/// Loads local document content for candidates that need it
/// (`conflictCandidate`, `localOnly`). `remoteOnly` candidates pass through
/// without a DB read. Boundaries pass through unchanged.
Stream<Object> Function(Object) localContentLoad(Storage storage) {
  return (Object event) async* {
    if (event is Boundary) {
      yield event;
      return;
    }

    final fetched = event as FetchedCandidate;
    final candidate = fetched.candidate;

    switch (candidate.direction) {
      case SyncDirection.remoteOnly:
        // No local content needed
        yield LoadedCandidate(
          candidate,
          remoteSource: fetched.remoteSource,
        );

      case SyncDirection.conflictCandidate:
      case SyncDirection.localOnly:
        // Load local content from DB
        final documentIri = candidate.resourceIri.getDocumentIri();
        final doc = await storage.getDocument(documentIri);
        final RdfGraphSource? localSource =
            doc != null ? DecodedGraphSource(doc.document) : null;
        yield LoadedCandidate(
          candidate,
          remoteSource: fetched.remoteSource,
          localSource: localSource,
          localUpdatedAt: doc?.metadata.updatedAt,
        );

      case SyncDirection.remoteRemoved:
        // Load local content — needed for deletion processing
        final documentIri = candidate.resourceIri.getDocumentIri();
        final doc = await storage.getDocument(documentIri);
        final RdfGraphSource? localSource =
            doc != null ? DecodedGraphSource(doc.document) : null;
        yield LoadedCandidate(
          candidate,
          localSource: localSource,
          localUpdatedAt: doc?.metadata.updatedAt,
        );
    }
  };
}
