/// Stage 7c: CRDT Merge — sync merge, shard reconciliation, encode.
///
/// **Implementation**: `.expand()` — pure CPU, no I/O. All required data
/// (merge contract, index configs, index documents) pre-loaded by Stage 7b.
///
/// **Input**: `Stream<PreloadedCandidateEvent>`
/// **Output**: `Stream<MergedResourceEvent>`
library;

import 'package:locorda_core/src/index/index_entry_builder.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/sync/pipeline/document_shard_reconciler.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart'
    hide MergeResult;
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart' as pipeline
    show MergeResult, MergedResourceEvent, PreloadedCandidateEvent;
import 'package:locorda_core/src/sync/remote_document_merger.dart'
    as merger_lib;
import 'package:locorda_rdf_core/core.dart';
import 'package:locorda_rdf_jelly/jelly.dart';
import 'package:logging/logging.dart';

final _log = Logger('Stage7c.CrdtMerge');

/// Returns an `.expand()` function for Stage 7c.
///
/// Performs sync CRDT merge, shard reconciliation, index entry building,
/// and binary encoding. All I/O data was pre-loaded by Stage 7b.
Iterable<pipeline.MergedResourceEvent> Function(
    pipeline.PreloadedCandidateEvent) mergeCandidates(
  merger_lib.RemoteDocumentMerger merger,
  DocumentShardReconciler reconciler,
  RdfCore rdfCore,
) {
  return (pipeline.PreloadedCandidateEvent event) => switch (event) {
        PhaseComplete() => [event],
        ShardComplete() => [event],
        PreloadedCandidate() => _merge(event, merger, reconciler, rdfCore),
      };
}

List<pipeline.MergeResult> _merge(
  PreloadedCandidate preloaded,
  merger_lib.RemoteDocumentMerger merger,
  DocumentShardReconciler reconciler,
  RdfCore rdfCore,
) {
  final d = preloaded.decoded;
  final RdfGraph mergedGraph;

  switch (d.effectiveDirection) {
    case SyncDirection.remoteOnly:
      mergedGraph = d.remoteGraph!;

    case SyncDirection.localOnly:
      mergedGraph = d.localGraph!;

    case SyncDirection.conflictCandidate:
      final mergeResult = merger.merge(
        mergeContract: preloaded.mergeContract,
        documentIri: d.documentIri,
        localGraph: d.localGraph,
        remoteGraph: d.remoteGraph,
      );
      mergedGraph = mergeResult.mergedGraph;

    case SyncDirection.remoteRemoved:
      if (d.localGraph == null) {
        _log.warning(
            'remoteRemoved but no local graph for ${d.resourceIri.debug}');
        return const [];
      }
      mergedGraph = d.localGraph!;
  }

  // Reconcile shard assignments using pre-loaded data (sync).
  final reconciled = reconciler.reconcileSync(
    documentIri: d.documentIri,
    mergedDocument: mergedGraph,
    typeIri: d.typeIri,
    resourceIri: d.resourceIri,
    mergeContract: preloaded.mergeContract,
    indexConfigs: preloaded.indexConfigs,
    getDocument: (iri) => preloaded.documents[iri],
  );

  // Clock hash of the merged (and reconciled) document — reconciliation
  // only touches shard triples, not clock entries, so this equals the
  // merged document's clock hash.
  final mergedClockHash = reconciled.clock.hash;
  final needsUpload =
      mergedClockHash != d.remoteClockHash || reconciled.hasChanges;
  final needsDbWrite =
      mergedClockHash != d.localClockHash || reconciled.hasChanges;

  // Build active index entries from pre-loaded data (pure CPU, no I/O).
  final indexEntries = buildActiveIndexEntries(
    resourceIri: d.resourceIri,
    typeIri: d.typeIri,
    clockHash: mergedClockHash,
    graph: reconciled.graph,
    shardToIndex: reconciled.shardToIndex,
    resolvedGroupIndices: reconciled.resolvedGroupIndices,
    indexedProperties: preloaded.indexedProperties,
    physicalTime: reconciled.clock.physicalTime,
  );

  // Extract tombstoned shard IRIs (pure CPU graph traversal).
  // Stage 9 resolves indexIri per shard from the DB and builds tombstone entries.
  final tombstonedShardIris =
      collectTombstonedShards(reconciled.graph, d.documentIri)
        ..removeAll(reconciled.shardToIndex.keys); // active wins over tombstone

  final decoded = DecodedGraphSource(reconciled.graph);
  // encode for the database.
  final encodedBytes = rdfCore.encodeBinary(reconciled.graph);
  final encoded =
      BinaryGraphSource(encodedBytes, contentType: jelly.primaryMimeType);

  return [
    pipeline.MergeResult(
      d.resourceIri,
      d.typeIri,
      decoded,
      encoded,
      needsUpload: needsUpload,
      needsDbWrite: needsDbWrite,
      clock: reconciled.clock,
      resolvedGroupIndices: reconciled.resolvedGroupIndices,
      indexEntries: indexEntries,
      tombstonedShardIris: tombstonedShardIris,
      localUpdatedAt: d.localUpdatedAt,
      resourceEtag: d.remoteEtag,
    ),
  ];
}
