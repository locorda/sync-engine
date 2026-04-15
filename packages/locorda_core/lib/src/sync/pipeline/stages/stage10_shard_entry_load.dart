/// Stage 10: Shard Entry Load — load index entries and shard document from DB.
///
/// Triggered by [ShardComplete] boundaries. Reads active index entries and the
/// locally-stored shard document — both required for CRDT merge in Stage 11.
///
/// Buffers up to [batchSize] shards and issues two batch DB queries per flush
/// ([Storage.getActiveIndexEntriesForShards] + [Storage.getDocumentsByIri]),
/// reducing round-trips from 2N to 2 per batch. Flushes eagerly when
/// [batchSize] is reached and on [PhaseComplete].
///
/// A shard-specific default batch size is intentionally smaller than the
/// resource-level [defaultPipelineBatchSize] — shard documents are larger
/// and shard counts are typically in the tens to low hundreds per phase.
///
/// **Implementation**: `asyncExpand` with mutable batch state captured in
/// closure — safe because `asyncExpand` processes events sequentially.
///
/// **Input**: `Stream<CommittedResourceEvent>`
/// **Output**: `Stream<LoadedShardEntriesEvent>`
library;

import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/storage/storage_interface.dart' show Storage;
import 'package:locorda_core/src/sync/pipeline/pipeperf.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';
import 'package:logging/logging.dart';

final _log = Logger('Stage10.ShardEntryLoad');

/// Default shard batch size for Stage 10.
///
/// Smaller than [defaultPipelineBatchSize] — shard documents are heavier,
/// and phase shard counts are typically tens to low hundreds.
const defaultShardBatchSize = 20;

/// Returns an asyncExpand function for Stage 10.
///
/// Usage: `stream.asyncExpand(shardEntryLoad(storage))`
///
/// Buffers [ShardComplete] events and flushes as a batch when [batchSize] is
/// reached or on [PhaseComplete].
Stream<LoadedShardEntriesEvent> Function(CommittedResourceEvent) shardEntryLoad(
  Storage storage, {
  int batchSize = defaultShardBatchSize,
  PipeperfCollector? perf,
}) {
  final pendingShards = <ShardComplete>[];

  Stream<LoadedShardEntriesEvent> _flush() async* {
    if (pendingShards.isEmpty) return;

    try {
      final sw = perf?.start('S10.ShardEntryLoad');

      final shardIris = pendingShards.map((e) => e.shardIri).toList();
      final shardDocumentIris =
          shardIris.map((iri) => iri.getDocumentIri()).toList();

      // Two batch queries instead of 2N per-shard queries.
      final entriesByShardIri =
          await storage.getActiveIndexEntriesForShards(shardIris);
      final docsByIri = await storage.getRawDocumentsByIri(shardDocumentIris);

      sw?.stop();

      for (final event in pendingShards) {
        final shardIri = event.shardIri;
        final entries = entriesByShardIri[shardIri] ?? [];
        yield LoadedShardEntries(
          shardIri,
          event.shardStorageId,
          entries,
          localDoc: docsByIri[shardIri.getDocumentIri()],
          remoteShardGraph: event.remoteShardGraph,
          newEtag: event.newEtag,
          existsOnRemote: event.existsOnRemote,
        );
      }
    } catch (e, st) {
      _log.warning(
          'S10: batch shard entry load failed for ${pendingShards.length} shards',
          e,
          st);
      for (final event in pendingShards) {
        yield ShardError(event.shardIri, e, st);
      }
    }

    pendingShards.clear();
  }

  return (CommittedResourceEvent event) async* {
    switch (event) {
      // --- Shard Events ---
      case ShardComplete():
        pendingShards.add(event);
        if (pendingShards.length >= batchSize) yield* _flush();
      case ShardSkipped():
        yield event;
      case ConflictedShard():
        yield event;
      case ShardError():
        yield event;

      // --- Phase Events ---
      case PhaseComplete():
        yield* _flush();
        yield event;
      case PhaseError():
        pendingShards.clear();
        yield event;
    }
  };
}
