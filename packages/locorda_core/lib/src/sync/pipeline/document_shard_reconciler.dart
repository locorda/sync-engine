/// Shard reconciliation for merged resource documents.
///
/// Extracted from [_RemoteSyncOrchestratorDocSync.reconcileDocumentShards].
/// Recomputes the shard assignments for a merged document and updates the
/// document with correct [idx:belongsToIndexShard] triples.
///
/// Called by Stage 7 (CRDT Merge) after producing the merged graph, so that
/// the reconciled document (with correct shard assignments) is what gets
/// encoded for DB and uploaded.
library;

import 'package:locorda_core/src/hlc_service.dart';
import 'package:locorda_core/src/index/shard_determiner.dart';
import 'package:locorda_core/src/local_document_merger.dart';
import 'package:locorda_core/src/mapping/merge_contract_loader.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/vocab/generated/_index.dart';
import 'package:locorda_rdf_core/core.dart';

/// Result of document shard reconciliation.
typedef ReconciledDocument = ({
  RdfGraph graph,
  CurrentCrdtClock clock,
  List<ResolvedGroupIndex> resolvedGroupIndices,
});

/// Recomputes shard assignments for a merged document and updates the
/// [idx:belongsToIndexShard] triples in-place via CRDT [replaceInDocument].
class DocumentShardReconciler {
  final ShardDeterminer _shardDeterminer;
  final LocalDocumentMerger _localDocumentMerger;
  final HlcService _hlcService;
  final MergeContractLoader _mergeContractLoader;

  DocumentShardReconciler({
    required ShardDeterminer shardDeterminer,
    required LocalDocumentMerger localDocumentMerger,
    required HlcService hlcService,
    required MergeContractLoader mergeContractLoader,
  })  : _shardDeterminer = shardDeterminer,
        _localDocumentMerger = localDocumentMerger,
        _hlcService = hlcService,
        _mergeContractLoader = mergeContractLoader;

  /// Reconcile shard assignments in [mergedDocument].
  ///
  /// Determines which shards the resource belongs to based on its current
  /// properties, replaces [idx:belongsToIndexShard] triples in the document
  /// via CRDT metadata (so remote peers can CRDT-merge this update), and
  /// returns the reconciled document together with the CRDT clock and any
  /// missing GroupIndex documents.
  Future<ReconciledDocument> reconcile(
    IriTerm documentIri,
    RdfGraph mergedDocument,
    IriTerm typeIri,
  ) async {
    final resourceIri = mergedDocument.expectSingleObject<IriTerm>(
        documentIri, SyncManagedDocument.foafPrimaryTopic)!;

    final shards = await _shardDeterminer.determineShards(
      typeIri,
      resourceIri,
      // Full document contains app data alongside framework data.
      mergedDocument,
      mode: ShardDeterminationMode.strict,
    );

    final clock = _hlcService.getCurrentClock(mergedDocument, documentIri);

    // Load merge contract for the document (cached after first load).
    final governanceIris = _mergeContractLoader
        .getMergedGovernanceIris([mergedDocument], documentIri);
    final mergeContract = await _mergeContractLoader.load(governanceIris);

    // Replace shard assignments with CRDT metadata.
    final reconciledGraph = _localDocumentMerger.replaceInDocument(
      documentIri: documentIri,
      document: mergedDocument,
      mergeContract: mergeContract,
      physicalClock: clock.physicalTime,
      changes: [
        (
          subject: documentIri,
          subjectTypeIri: SyncManagedDocument.classIri,
          predicate: SyncManagedDocument.idxBelongsToIndexShard,
          newObjects: shards.shards,
        )
      ],
    );

    return (
      graph: reconciledGraph,
      clock: clock,
      resolvedGroupIndices: shards.resolvedGroupIndices.toList(),
    );
  }
}
