/// Stage 7: CRDT Merge — decode on demand, merge, reconcile shards, encode.
///
/// **Implementation**: `asyncExpand` — merge contract loading and shard
/// reconciliation are async (though typically served from cache).
///
/// **Input**: `Stream<FetchedCandidateEvent>`
/// **Output**: `Stream<MergedResourceEvent>`
library;

import 'package:locorda_core/src/mapping/merge_contract_loader.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/sync/pipeline/document_shard_reconciler.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart'
    hide MergeResult;
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart' as pipeline
    show
        MergeResult,
        MergedResourceEvent,
        FetchedCandidateEvent,
        FetchedCandidate;
import 'package:locorda_core/src/sync/remote_document_merger.dart'
    as merger_lib;
import 'package:locorda_rdf_core/core.dart';
import 'package:logging/logging.dart';

final _log = Logger('Stage7.CrdtMerge');

/// Returns an asyncExpand function for Stage 7.
///
/// Usage: `stream.asyncExpand(crdtMerge(merger, mergeContractLoader, reconciler, rdfCore))`
///
/// FIXME: should be .expand or .map, but certainly not async. We need to replace all async operations.
Stream<pipeline.MergedResourceEvent> Function(pipeline.FetchedCandidateEvent)
    crdtMerge(
  merger_lib.RemoteDocumentMerger merger,
  MergeContractLoader mergeContractLoader,
  DocumentShardReconciler reconciler,
  RdfCore rdfCore,
) {
  return (pipeline.FetchedCandidateEvent event) async* {
    switch (event) {
      case PhaseComplete():
        yield event;
      case ShardComplete():
        yield event;
      case pipeline.FetchedCandidate():
        yield* _mergeFetched(
            event, merger, mergeContractLoader, reconciler, rdfCore);
    }
  };
}

Stream<pipeline.MergeResult> _mergeFetched(
  pipeline.FetchedCandidate fetched,
  merger_lib.RemoteDocumentMerger merger,
  MergeContractLoader mergeContractLoader,
  DocumentShardReconciler reconciler,
  RdfCore rdfCore,
) async* {
  final candidate = fetched.loaded.candidate;
  final typeIri = candidate.typeIri;
  final localUpdatedAt = fetched.loaded.localUpdatedAt;
  final remoteEtag = fetched.remoteEtag;
  final documentIri = candidate.resourceIri.getDocumentIri();

  // Decode sources on demand
  final remoteGraph = fetched.remoteSource?.decodeWith(rdfCore).graph;
  final localGraph = fetched.loaded.localSource?.decodeWith(rdfCore).graph;

  final RdfGraph mergedGraph;

  // Determine effective direction: if a remoteOnly resource already exists
  // locally (e.g. modified via a different shard), upgrade to conflictCandidate
  // so the CRDT merge runs and both versions are compared.
  final effectiveDirection =
      candidate.direction == SyncDirection.remoteOnly && localGraph != null
          ? SyncDirection.conflictCandidate
          : candidate.direction;

  switch (effectiveDirection) {
    case SyncDirection.remoteOnly:
      mergedGraph = remoteGraph!;

    case SyncDirection.localOnly:
      // Local is already correct — upload without DB write
      mergedGraph = localGraph!;

    case SyncDirection.conflictCandidate:
      final governanceIris = mergeContractLoader.getMergedGovernanceIris(
        [
          if (localGraph != null) localGraph,
          if (remoteGraph != null) remoteGraph
        ],
        documentIri,
      );
      final mergeContract = await mergeContractLoader.load(governanceIris);

      final mergeResult = merger.merge(
        mergeContract: mergeContract,
        documentIri: documentIri,
        localGraph: localGraph,
        remoteGraph: remoteGraph,
      );
      mergedGraph = mergeResult.mergedGraph;

    case SyncDirection.remoteRemoved:
      // TODO: Apply proper deletion semantics
      if (localGraph == null) {
        _log.warning(
            'remoteRemoved but no local graph for ${candidate.resourceIri.debug}');
        return;
      }
      mergedGraph = localGraph;
  }

  // Reconcile shard assignments in the merged document.
  // Note: determineShards() calls discoverIndices() which uses cached data
  // during the content phase (meta-indices synced before content phase).
  final reconciled =
      await reconciler.reconcile(documentIri, mergedGraph, typeIri);

  final reconciledChanged = reconciled.graph != localGraph;
  final needsUpload = switch (effectiveDirection) {
    SyncDirection.remoteOnly => false,
    SyncDirection.localOnly => true,
    SyncDirection.conflictCandidate => reconciledChanged,
    SyncDirection.remoteRemoved => true,
  };

  final needsDbWrite = switch (effectiveDirection) {
    SyncDirection.remoteOnly => true,
    SyncDirection.localOnly => reconciledChanged,
    SyncDirection.conflictCandidate => true,
    SyncDirection.remoteRemoved => true,
  };

  yield _buildResult(
    resourceIri: candidate.resourceIri,
    typeIri: typeIri,
    reconciled: reconciled,
    rdfCore: rdfCore,
    needsUpload: needsUpload,
    needsDbWrite: needsDbWrite,
    localUpdatedAt: localUpdatedAt,
    resourceEtag: remoteEtag,
  );
}

pipeline.MergeResult _buildResult({
  required IriTerm resourceIri,
  required IriTerm typeIri,
  required ReconciledDocument reconciled,
  required RdfCore rdfCore,
  required bool needsUpload,
  required bool needsDbWrite,
  int? localUpdatedAt,
  String? resourceEtag,
}) {
  final decoded = DecodedGraphSource(reconciled.graph);
  final encodedBytes = rdfCore.encodeBinary(reconciled.graph);
  final encoded =
      BinaryGraphSource(encodedBytes, contentType: 'application/x-jelly-rdf');

  return pipeline.MergeResult(
    resourceIri,
    typeIri,
    decoded,
    encoded,
    needsUpload: needsUpload,
    needsDbWrite: needsDbWrite,
    clock: reconciled.clock,
    resolvedGroupIndices: reconciled.resolvedGroupIndices,
    localUpdatedAt: localUpdatedAt,
    resourceEtag: resourceEtag,
  );
}
