/// Stage 10: Shard Entry Load — load index entries and shard document from DB.
///
/// Triggered by [ShardComplete] boundaries. Reads active index entries and the
/// locally-stored shard document — both required for CRDT merge in Stage 11.
///
/// **Implementation**: `asyncExpand` — boundary-reactive; all other events
/// pass through unchanged.
///
/// **Input**: `Stream<CommittedResourceEvent>`
/// **Output**: `Stream<LoadedShardEntriesEvent>`
library;

import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/storage/storage_interface.dart' show Storage;
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';

/// Returns an asyncExpand function for Stage 10.
///
/// Usage: `stream.asyncExpand(shardEntryLoad(storage))`
///
/// Reacts to [ShardComplete] boundaries: loads index entries and existing
/// shard document from DB. [PhaseComplete] passes through. [CommitResult]
/// events are consumed — they have served their purpose.
Stream<LoadedShardEntriesEvent> Function(CommittedResourceEvent) shardEntryLoad(
    Storage storage) {
  return (CommittedResourceEvent event) async* {
    switch (event) {
      case CommitResult():
        // consumed — doesn't propagate past shard entry load
        break;
      case CommittedResourceBoundary(:final boundary):
        switch (boundary) {
          case PhaseComplete():
            yield LoadedShardEntriesBoundary(boundary);
          case ShardComplete():
            final shardIri = boundary.shardIri;
            final shardDocumentIri = shardIri.getDocumentIri();

            // Two DB queries: entries + shard document
            final entries =
                await storage.getActiveIndexEntriesForShard(shardIri);
            final shardDoc = await storage.getDocument(shardDocumentIri);

            yield LoadedShardEntries(
              shardIri,
              boundary.shardStorageId,
              entries,
              localDoc: shardDoc,
              remoteShardGraph: boundary.remoteShardGraph,
              newEtag: boundary.newEtag,
              existsOnRemote: boundary.existsOnRemote,
            );
        }
    }
  };
}
