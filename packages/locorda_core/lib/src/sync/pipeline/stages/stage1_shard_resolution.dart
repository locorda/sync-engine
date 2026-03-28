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
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';
import 'package:locorda_core/src/vocab/generated/_index.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:logging/logging.dart';

final _log = Logger('Stage1.ShardResolution');

/// Returns an asyncExpand function for Stage 1.
///
/// Usage: `inputController.stream.asyncExpand(shardResolution(storage, remoteId))`
Stream<ShardRefEvent> Function(SyncInput) shardResolution(
  Storage storage,
  RemoteId remoteId,
) {
  return (SyncInput input) async* {
    final zeroShardIndices = <IriTerm>[];
    var processedShardCount = 0;

    // Batch-load all index documents in one query
    final documentIris =
        input.indexIris.map((iri) => iri.getDocumentIri()).toList();
    final docs = await storage.getDocumentsByIri(documentIris);

    // Collect all shard IRIs across all indices for bulk ETag query
    final allShardIris = <IriTerm>{};
    final indexShards =
        <IriTerm, (Set<IriTerm> shardIris, IndexInputInfo info)>{};

    for (final indexIri in input.indexIris) {
      final documentIri = indexIri.getDocumentIri();
      final doc = docs[documentIri];

      if (doc == null) {
        _log.warning('Index document not found: ${documentIri.debug} — '
            'adding to zeroShardIndices');
        zeroShardIndices.add(indexIri);
        continue;
      }

      final shardIris = doc.document
          .getMultiValueObjects<IriTerm>(indexIri, IdxIndex.hasShard);

      if (shardIris.isEmpty) {
        zeroShardIndices.add(indexIri);
        continue;
      }

      final info = input.indexInfos[indexIri];
      if (info == null) {
        _log.warning('No index info for ${indexIri.debug} — skipping');
        continue;
      }

      allShardIris.addAll(shardIris);
      indexShards[indexIri] = (shardIris, info);
    }

    // Bulk ETag query for all shards across all indices
    final etags = allShardIris.isNotEmpty
        ? await _getStoredEtags(storage, remoteId, allShardIris)
        : <IriTerm, String>{};

    // Emit ShardRefs
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
          storedEtag: etags[shardIri],
        );
        processedShardCount++;
      }
    }

    yield ShardRefBoundary(PhaseComplete(
      input,
      processedShardCount,
      zeroShardIndices: zeroShardIndices,
    ));
  };
}

/// Query stored ETags for shard IRIs from remote sync state.
Future<Map<IriTerm, String>> _getStoredEtags(
  Storage storage,
  RemoteId remoteId,
  Set<IriTerm> shardIris,
) async {
  final etagMap = await storage.getRemoteETags(remoteId, shardIris);
  return {
    for (final entry in etagMap.entries)
      if (entry.value != null) entry.key: entry.value!,
  };
}
