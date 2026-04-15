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
import 'package:locorda_core/src/storage/storage_interface.dart'
    show RawStoredDocument, StoredDocument;
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
///
/// Decodes raw shard documents (from Stage 10's I/O read) into
/// [StoredDocument] for downstream usage — keeping decode CPU in this
/// CPU stage rather than in Stage 10's I/O stage.
Iterable<PreparedShardEvent> Function(LoadedShardEntriesEvent) prepareShards(
  ShardDocumentGenerator shardDocGen,
  SyncEngineConfig config,
  RdfCore rdfCore,
) {
  return (LoadedShardEntriesEvent event) => switch (event) {
        // --- Shard Events ---
        ConflictedShard() => [event],
        ShardError() => [event],
        ShardSkipped() => [event],
        LoadedShardEntries() =>
          _prepareOrError(event, shardDocGen, config, rdfCore),

        // --- Phase Events ---
        PhaseComplete() => [event],
        PhaseError() => [event],
      };
}

Iterable<PreparedShardEvent> _prepareOrError(
  LoadedShardEntries loaded,
  ShardDocumentGenerator shardDocGen,
  SyncEngineConfig config,
  RdfCore rdfCore,
) {
  try {
    return _prepare(loaded, shardDocGen, config, rdfCore);
  } catch (e, st) {
    _log.warning('S11a: failed to prepare shard ${loaded.shardIri}', e, st);
    return [ShardError(loaded.shardIri, e, st)];
  }
}

Iterable<PreparedShardEvent> _prepare(
  LoadedShardEntries loaded,
  ShardDocumentGenerator shardDocGen,
  SyncEngineConfig config,
  RdfCore rdfCore,
) {
  final shardIri = loaded.shardIri;
  final shardDocumentIri = shardIri.getDocumentIri();

  // 0. Decode raw shard document (CPU work deferred from Stage 10 I/O).
  final localDoc = _decodeRawDocument(loaded.localDoc, rdfCore);

  // 1. Extract index IRI from remote or local shard graph.
  final indexIri = _extractIndexIri(shardIri, localDoc, loaded);
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
    localDoc?.document,
    shardDocumentIri,
    config,
    IdxShard.classIri,
  );

  return [
    PreparedShard(
      shardIri: shardIri,
      shardStorageId: loaded.shardStorageId,
      localDoc: localDoc,
      indexIri: indexIri,
      entryTriples: entryTriples,
      governanceIris: governanceIris,
      remoteShardGraph: loaded.remoteShardGraph,
      newEtag: loaded.newEtag,
      existsOnRemote: loaded.existsOnRemote,
    ),
  ];
}

/// Decodes a [RawStoredDocument] into a [StoredDocument].
StoredDocument? _decodeRawDocument(
  RawStoredDocument? raw,
  RdfCore rdfCore,
) {
  if (raw == null) return null;
  return StoredDocument(
    documentIri: raw.documentIri,
    document:
        rdfCore.decodeBinary(raw.rawContent, contentType: raw.contentType),
    metadata: raw.metadata,
  );
}

/// Extract the index IRI for a shard from available graphs.
///
/// Prefers the remote shard graph (always fresh); falls back to local.
IriTerm? _extractIndexIri(
  IriTerm shardIri,
  StoredDocument? localDoc,
  LoadedShardEntries loaded,
) {
  if (loaded.remoteShardGraph != null) {
    final iri = loaded.remoteShardGraph!.graph
        .findSingleObject<IriTerm>(shardIri, IdxShard.isShardOf);
    if (iri != null) return iri;
  }
  if (localDoc != null) {
    final iri = localDoc.document
        .findSingleObject<IriTerm>(shardIri, IdxShard.isShardOf);
    if (iri != null) return iri;
  }
  return null;
}
