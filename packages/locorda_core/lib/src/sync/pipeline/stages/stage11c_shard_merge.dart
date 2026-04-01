/// Stage 11c: Shard CRDT Merge — sync merge with pre-loaded contract, encode.
///
/// **Implementation**: `.expand()` — pure CPU, no I/O. The merge contract
/// was pre-loaded by Stage 11b.
///
/// **Input**: `Stream<ContractLoadedShardEvent>`
/// **Output**: `Stream<MergedShardEvent>`
library;

import 'package:locorda_core/src/crdt_document_manager.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';
import 'package:locorda_core/src/sync/shard_document_generator.dart';
import 'package:locorda_core/src/vocab/generated/_index.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:locorda_rdf_jelly/jelly.dart';

/// Returns an `.expand()` function for Stage 11c.
///
/// CRDT-merges the prepared shard entries with the existing local shard
/// document using the pre-loaded merge contract, then encodes the result.
Iterable<MergedShardEvent> Function(ContractLoadedShardEvent) mergeShards(
  CrdtDocumentManager documentManager,
  RdfCore rdfCore,
) {
  return (ContractLoadedShardEvent event) => switch (event) {
        PhaseComplete() => [event],
        ContractLoadedShard() => _merge(event, documentManager, rdfCore),
      };
}

List<MergedShardEvent> _merge(
  ContractLoadedShard loaded,
  CrdtDocumentManager documentManager,
  RdfCore rdfCore,
) {
  final p = loaded.prepared;
  final shardIri = p.shardIri;

  // CRDT-merge via sync path — picks up existing HLC clock.
  final prepared = documentManager.prepareModifyWithContract(
    IdxShard.classIri,
    shardIri,
    (oldAppData) =>
        buildShardAppData(oldAppData, shardIri, p.indexIri, p.entryTriples),
    p.localDoc,
    loaded.mergeContract,
    acceptMissing: true,
  );

  if (prepared == null) {
    // No changes — shard is already up-to-date locally.
    // Upload if shard doesn't exist on remote yet (new shard).
    final localGraph = p.localDoc?.document;
    if (localGraph == null) return const [];

    final encodedBytes =
        rdfCore.encodeBinary(localGraph, contentType: jelly.primaryMimeType);
    return [
      MergedShard(
        shardIri,
        DecodedGraphSource(localGraph),
        BinaryGraphSource(encodedBytes, contentType: jelly.primaryMimeType),
        newEtag: p.newEtag,
        needsUpload: !p.existsOnRemote,
        ourPhysicalClock: 0,
      ),
    ];
  }

  // Encode merged shard document.
  final mergedGraph = prepared.crdtDocument;
  final encodedBytes = rdfCore.encodeBinary(mergedGraph);

  return [
    MergedShard(
      shardIri,
      DecodedGraphSource(mergedGraph),
      BinaryGraphSource(encodedBytes, contentType: jelly.primaryMimeType),
      newEtag: p.newEtag,
      needsUpload: true,
      ourPhysicalClock: prepared.physicalTime,
    ),
  ];
}
