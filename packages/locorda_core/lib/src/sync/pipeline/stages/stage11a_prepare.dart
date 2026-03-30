/// Stage 11a: Prepare Shard — extract index IRI, generate entry triples,
/// compute governance IRIs for contract loading.
///
/// **Implementation**: `.expand()` — pure CPU, no I/O. Uses expand rather
/// than map because shards with an undetermined index IRI are dropped.
///
/// **Input**: `Stream<LoadedShardEntriesEvent>`
/// **Output**: `Stream<PreparedShardEvent>`
library;

import 'package:locorda_core/src/config/sync_engine_config.dart';
import 'package:locorda_core/src/crdt_document_manager.dart'
    show computeIsGovernedBy;
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';
import 'package:locorda_core/src/sync/shard_document_generator.dart';
import 'package:locorda_core/src/vocab/generated/_index.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:logging/logging.dart';

final _log = Logger('Stage11a.Prepare');

/// Returns an `.expand()` function for Stage 11a.
///
/// Extracts the index IRI from shard graphs, generates entry triples from
/// committed index entries, and computes governance IRIs for Stage 11b.
/// Drops shards where the index IRI cannot be determined.
Iterable<PreparedShardEvent> Function(LoadedShardEntriesEvent) prepareShards(
  ShardDocumentGenerator shardDocGen,
  SyncEngineConfig config,
) {
  return (LoadedShardEntriesEvent event) => switch (event) {
        PhaseComplete() => [event],
        LoadedShardEntries() => _prepare(event, shardDocGen, config),
      };
}

Iterable<PreparedShardEvent> _prepare(
  LoadedShardEntries loaded,
  ShardDocumentGenerator shardDocGen,
  SyncEngineConfig config,
) {
  final shardIri = loaded.shardIri;
  final shardDocumentIri = shardIri.getDocumentIri();

  // 1. Extract index IRI from remote or local shard graph.
  final indexIri = _extractIndexIri(shardIri, loaded);
  if (indexIri == null) {
    _log.warning(
        'Cannot determine indexIri for shard ${shardIri.debug} — skipping');
    return const [];
  }

  // 2. Generate entry triples from post-commit index entries.
  final nodes = shardDocGen.generateShardNodes(
    shardDocumentIri: shardDocumentIri,
    shardResourceIri: shardIri,
    entries: loaded.entries,
  );
  final entryTriples = nodes
      .expand((node) => [
            Triple(shardIri, IdxShard.containsEntry, node.$1),
            ...node.$2.triples,
          ])
      .toList();

  // 3. Compute governance IRIs for merge contract loading in 11b.
  final governanceIris = computeIsGovernedBy(
    loaded.localDoc?.document,
    shardDocumentIri,
    config,
    IdxShard.classIri,
  );

  return [
    PreparedShard(
      shardIri: shardIri,
      shardStorageId: loaded.shardStorageId,
      localDoc: loaded.localDoc,
      indexIri: indexIri,
      entryTriples: entryTriples,
      governanceIris: governanceIris,
      newEtag: loaded.newEtag,
      existsOnRemote: loaded.existsOnRemote,
    ),
  ];
}

/// Extract the index IRI for a shard from available graphs.
///
/// Prefers the remote shard graph (always fresh); falls back to local.
IriTerm? _extractIndexIri(IriTerm shardIri, LoadedShardEntries loaded) {
  if (loaded.remoteShardGraph != null) {
    final iri = loaded.remoteShardGraph!.graph
        .findSingleObject<IriTerm>(shardIri, IdxShard.isShardOf);
    if (iri != null) return iri;
  }
  if (loaded.localDoc != null) {
    final iri = loaded.localDoc!.document
        .findSingleObject<IriTerm>(shardIri, IdxShard.isShardOf);
    if (iri != null) return iri;
  }
  return null;
}
