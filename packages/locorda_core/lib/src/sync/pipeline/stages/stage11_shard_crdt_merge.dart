/// Stage 11: Shard CRDT Merge — assemble updated shard document from committed
/// index entries, CRDT-merge with local shard, encode.
///
/// **Implementation**: `asyncExpand` — [CrdtDocumentManager.prepareModify] is
/// async (merge contract loading, cached after meta phase).
///
/// **Input**: `Stream<LoadedShardEntriesEvent>`
/// **Output**: `Stream<MergedShardEvent>`
library;

import 'package:locorda_core/src/crdt_document_manager.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';
import 'package:locorda_core/src/sync/shard_document_generator.dart';
import 'package:locorda_core/src/vocab/generated/_index.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:logging/logging.dart';

final _log = Logger('Stage11.ShardCrdtMerge');

/// Returns an asyncExpand function for Stage 11.
///
/// Usage: `stream.asyncExpand(shardCrdtMerge(documentManager, shardDocGen, rdfCore))`
///
/// Reacts to [LoadedShardEntries]: builds the shard document from committed
/// entries and CRDT-merges with the existing local shard document.
/// [PhaseComplete] passes through unchanged.
Stream<MergedShardEvent> Function(LoadedShardEntriesEvent) shardCrdtMerge(
  CrdtDocumentManager documentManager,
  ShardDocumentGenerator shardDocGen,
  RdfCore rdfCore,
) {
  return (LoadedShardEntriesEvent event) async* {
    switch (event) {
      case LoadedShardEntriesBoundary(:final boundary):
        yield MergedShardBoundary(boundary);
      case LoadedShardEntries():
        yield* _mergeShardEntries(event, documentManager, shardDocGen, rdfCore);
    }
  };
}

Stream<MergedShard> _mergeShardEntries(
  LoadedShardEntries loaded,
  CrdtDocumentManager documentManager,
  ShardDocumentGenerator shardDocGen,
  RdfCore rdfCore,
) async* {
  final shardIri = loaded.shardIri;
  final shardDocumentIri = shardIri.getDocumentIri();

  // 1. Extract index IRI from remote or local shard graph.
  final indexIri = _extractIndexIri(shardIri, loaded);
  if (indexIri == null) {
    _log.warning(
        'Cannot determine indexIri for shard ${shardIri.debug} — skipping');
    return;
  }

  // 2. Generate entry triples from post-commit index entries.
  final nodes = shardDocGen.generateShardNodes(
    shardDocumentIri: shardDocumentIri,
    shardResourceIri: shardIri,
    entries: loaded.entries,
  );
  final newTriples = nodes.expand((node) => [
        Triple(shardIri, IdxShard.containsEntry, node.$1),
        ...node.$2.triples,
      ]);

  // 3. CRDT-merge via CrdtDocumentManager — picks up existing HLC clock.
  final prepared = await documentManager.prepareModify(
    IdxShard.classIri,
    shardIri,
    (oldAppData) =>
        buildShardAppData(oldAppData, shardIri, indexIri, newTriples),
    loaded.localDoc,
    acceptMissing: true,
  );

  if (prepared == null) {
    // No changes — shard is already up-to-date locally.
    // Upload if shard doesn't exist on remote yet (new shard).
    final localGraph = loaded.localDoc?.document;
    if (localGraph == null) return;

    final encodedBytes = rdfCore.encodeBinary(localGraph);
    yield MergedShard(
      shardIri,
      DecodedGraphSource(localGraph),
      BinaryGraphSource(encodedBytes, contentType: 'application/x-jelly-rdf'),
      newEtag: loaded.newEtag,
      needsUpload: !loaded.existsOnRemote,
      ourPhysicalClock: 0,
    );
    return;
  }

  // 4. Encode merged shard document.
  final mergedGraph = prepared.crdtDocument;
  final encodedBytes = rdfCore.encodeBinary(mergedGraph);

  // Always upload when shard content changed — both for new shards (404 →
  // create) and modified shards (200 → update with ETag).
  yield MergedShard(
    shardIri,
    DecodedGraphSource(mergedGraph),
    BinaryGraphSource(encodedBytes, contentType: 'application/x-jelly-rdf'),
    newEtag: loaded.newEtag,
    needsUpload: true,
    ourPhysicalClock: prepared.physicalTime,
  );
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
