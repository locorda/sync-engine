/// Stage 11c: Shard CRDT Merge — sync merge with pre-loaded contract, encode.
///
/// **Implementation**: `.expand()` — pure CPU, no I/O. The merge contract
/// was pre-loaded by Stage 11b.
///
/// **Input**: `Stream<ContractLoadedShardEvent>`
/// **Output**: `Stream<MergedShardEvent>`
library;

import 'package:locorda_core/src/crdt_document_manager.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/storage/storage_interface.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';
import 'package:locorda_core/src/sync/remote_document_merger.dart';
import 'package:locorda_core/src/sync/shard_document_generator.dart';
import 'package:locorda_core/src/vocab/generated/_index.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:locorda_rdf_jelly/jelly.dart';

/// Returns an `.expand()` function for Stage 11c.
///
/// CRDT-merges the prepared shard entries with the existing local shard
/// document using the pre-loaded merge contract, then encodes the result.
///
/// When the remote returned a 200 response (i.e. [PreparedShard.remoteShardGraph]
/// is non-null), a structural CRDT merge between local and remote is performed
/// first via [RemoteDocumentMerger]. This preserves framework metadata from
/// foreign installations (clock entries, tombstones, `cm:createdAt`) that
/// are not present in the locally-generated shard document.
Iterable<MergedShardEvent> Function(ContractLoadedShardEvent) mergeShards(
  CrdtDocumentManager documentManager,
  RemoteDocumentMerger merger,
  RdfCore rdfCore,
) {
  return (ContractLoadedShardEvent event) => switch (event) {
        PhaseComplete() => [event],
        ContractLoadedShard() =>
          _merge(event, documentManager, merger, rdfCore),
      };
}

List<MergedShardEvent> _merge(
  ContractLoadedShard loaded,
  CrdtDocumentManager documentManager,
  RemoteDocumentMerger merger,
  RdfCore rdfCore,
) {
  final p = loaded.prepared;
  final shardIri = p.shardIri;
  final shardDocumentIri = shardIri.getDocumentIri();

  // When a 200 response was received, merge remote CRDT framework metadata
  // (foreign clock entries, tombstones) into the local shard before applying
  // local entry changes. Without this, multi-installation scenarios lose
  // the foreign installation's CRDT history entirely.
  final StoredDocument? effectiveDoc;
  if (p.remoteShardGraph != null) {
    final mergeResult = merger.merge(
      mergeContract: loaded.mergeContract,
      documentIri: shardDocumentIri,
      localGraph: p.localDoc?.document,
      remoteGraph: p.remoteShardGraph!.graph,
    );
    effectiveDoc = StoredDocument(
      documentIri: shardDocumentIri,
      document: mergeResult.mergedGraph,
      metadata: p.localDoc?.metadata ??
          DocumentMetadata(ourPhysicalClock: 0, updatedAt: 0),
    );
  } else {
    effectiveDoc = p.localDoc;
  }

  // CRDT-merge via sync path — picks up existing HLC clock.
  final prepared = documentManager.prepareModifyWithContract(
    IdxShard.classIri,
    shardIri,
    (oldAppData) =>
        buildShardAppData(oldAppData, shardIri, p.indexIri, p.entryTriples),
    effectiveDoc,
    loaded.mergeContract,
    acceptMissing: true,
  );
  if (prepared == null) {
    // No changes — shard is already up-to-date locally.
    // No local changes detected — use the effective (merged) graph as-is.
    // effectiveDoc is either the merged remote shard (200 response) or the
    // existing local shard (304 / local-only path). It is never null here
    // because acceptMissing=true guarantees at least RdfGraph() is passed.
    final baseGraph = effectiveDoc?.document;
    if (baseGraph == null) return const [];

    final encodedBytes =
        rdfCore.encodeBinary(baseGraph, contentType: jelly.primaryMimeType);

    return [
      MergedShard(
        shardIri,
        DecodedGraphSource(baseGraph),
        BinaryGraphSource(encodedBytes, contentType: jelly.primaryMimeType),
        newEtag: p.newEtag,
        needsUpload: !p.existsOnRemote,
        ourPhysicalClock: effectiveDoc?.metadata.ourPhysicalClock ?? 0,
      ),
    ];
  }

  // Encode merged shard document.
  final mergedGraph = prepared.crdtDocument;
  final encodedBytes =
      rdfCore.encodeBinary(mergedGraph, contentType: jelly.primaryMimeType);
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
