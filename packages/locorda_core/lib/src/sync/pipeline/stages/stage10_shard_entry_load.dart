/// Stage 10: Shard Entry Load — load index entries and shard document from DB.
///
/// Triggered by [ShardComplete] boundaries. Reads active index entries and the
/// locally-stored shard document — both required for CRDT merge in Stage 11.
///
/// **Implementation**: `asyncExpand` — boundary-reactive; all other events
/// pass through unchanged.
///
/// **Input**: `Stream<CommitResult | ShardComplete | PhaseComplete>`
/// **Output**: `Stream<LoadedShardEntries | PhaseComplete>`
library;

import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/storage/storage_interface.dart' show Storage;
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';

/// Returns an asyncExpand function for Stage 10.
///
/// Usage: `stream.asyncExpand(shardEntryLoad(storage))`
///
/// Reacts to [ShardComplete] boundaries: loads index entries and existing
/// shard document from DB. [PhaseComplete] passes through. Other events
/// (e.g. [CommitResult]) are consumed — they have served their purpose.
Stream<Object> Function(Object) shardEntryLoad(Storage storage) {
  return (Object event) async* {
    if (event is PhaseComplete) {
      yield event;
      return;
    }

    if (event is ShardComplete) {
      final shardIri = event.shardIri;
      final shardDocumentIri = shardIri.getDocumentIri();

      // Two DB queries: entries + shard document
      final entries = await storage.getActiveIndexEntriesForShard(shardIri);
      final shardDoc = await storage.getDocument(shardDocumentIri);

      yield LoadedShardEntries(
        shardIri,
        event.shardStorageId,
        entries,
        localDoc: shardDoc,
        remoteShardGraph: event.remoteShardGraph,
        newEtag: event.newEtag,
      );
      return;
    }

    // CommitResult and other events are consumed — they don't propagate
    // past the shard entry load stage.
  };
}
