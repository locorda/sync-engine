/// Stage 1: Shard Resolution — resolve [SyncInput] → [ShardRef]s via DB queries.
///
/// For each [SyncInput] (a batch of index IRIs), loads index documents from
/// storage to extract shard IRIs, then queries stored ETags.
///
/// **Implementation**: `asyncExpand` — 1:N async; O(1) events per sync cycle.
///
/// **Input**: `Stream<SyncInput>`
/// **Output**: `Stream<ShardRefEvent>`
library;

import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/storage/remote_id.dart';
import 'package:locorda_core/src/storage/storage_interface.dart';
import 'package:locorda_core/src/sync/pipeline/pipeperf.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:logging/logging.dart';

final _log = Logger('Stage1.ShardResolution');

/// Returns an asyncExpand function for Stage 1.
///
/// Usage: `inputController.stream.asyncExpand(shardResolution(storage, remoteId))`
Stream<ShardRefEvent> Function(SyncInput) shardResolution(
  Storage storage,
  RemoteId remoteId, {
  PipeperfCollector? perf,
}) {
  return (SyncInput input) async* {
    final sw = perf?.start('S01.ShardResolution');
    final zeroShardIndices = <IriTerm>[];
    var processedShardCount = 0;

    // Single DB query replaces document load + RDF parse per index.
    final indexToShards = await storage.getIndexShards(input.indexIris);

    // Collect all shard IRIs for bulk ETag query.
    final allShardIris = <IriTerm>{};
    final indexShards = <IriTerm, (List<IriTerm>, IndexInputInfo)>{};

    for (final indexIri in input.indexIris) {
      final shardIris = indexToShards[indexIri] ?? const [];
      if (shardIris.isEmpty) {
        zeroShardIndices.add(indexIri);
        continue;
      }

      final info = input.indexInfos[indexIri];
      if (info == null) {
        _log.warning('No index info for ${indexIri.debug} — skipping');
        continue;
      }

      final filtered = input.conflictedShardIris != null
          ? shardIris
              .where((s) => input.conflictedShardIris!.contains(s))
              .toList()
          : shardIris;
      if (filtered.isEmpty) continue;

      allShardIris.addAll(filtered);
      indexShards[indexIri] = (filtered, info);
    }

    // Bulk ETag query — ETags are keyed by document IRI (without fragment),
    // matching Stage 13 which stores them via shardIri.getDocumentIri().
    final shardDocIris = allShardIris.map((s) => s.getDocumentIri()).toSet();
    final etagsByDocIri = shardDocIris.isNotEmpty
        ? await storage.getRemoteETags(remoteId, shardDocIris)
        : <IriTerm, String?>{};

    sw?.stop();

    for (final entry in indexShards.entries) {
      final indexIri = entry.key;
      final (shardIris, info) = entry.value;

      for (final shardIri in shardIris) {
        yield ShardRef(
          indexIri,
          shardIri,
          shardIri, // shardStorageId — use IRI as opaque ID for now
          info.fetchPolicy,
          info.typeIri,
          storedEtag: etagsByDocIri[shardIri.getDocumentIri()],
        );
        processedShardCount++;
      }
    }

    yield PhaseComplete(
      input,
      processedShardCount,
      zeroShardIndices: zeroShardIndices,
    );
  };
}
