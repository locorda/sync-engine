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

import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_core/src/hlc_service.dart';
import 'package:locorda_core/src/index/shard_determiner.dart';
import 'package:locorda_core/src/local_document_merger.dart';
import 'package:locorda_core/src/mapping/merge_contract.dart';
import 'package:locorda_core/src/mapping/merge_contract_loader.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/sync/pipeline/pipeperf.dart';
import 'package:locorda_rdf_core/core.dart';

/// Result of document shard reconciliation.
typedef ReconciledDocument = ({
  RdfGraph graph,
  CurrentCrdtClock clock,
  List<ResolvedGroupIndex> resolvedGroupIndices,

  /// Maps each shard IRI to its parent index IRI (FullIndex or GroupIndex).
  /// Propagated from [ShardDeterminationResult] for Stage 7c index entry
  /// building without I/O.
  Map<IriTerm, IriTerm> shardToIndex,

  /// Whether shard reconciliation changed the document (e.g. updated
  /// [idx:belongsToIndexShard] triples). Used together with clock-hash
  /// comparison to decide [needsUpload] / [needsDbWrite] in Stage 7c.
  bool hasChanges,
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
  @Deprecated('delete me ')
  Future<ReconciledDocument> reconcile(
    IriTerm documentIri,
    RdfGraph mergedDocument,
    IriTerm typeIri,
  ) async {
    final resourceIri = mergedDocument.expectSingleObject<IriTerm>(
        documentIri, SyncManagedDocument.foafPrimaryTopic)!;

    final shards = await _shardDeterminer.determineShardsFromStorage(
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

    final hasChanges =
        _shardsChanged(mergedDocument, documentIri, shards.shards);

    // Replace shard assignments with CRDT metadata.
    final reconciledGraph = hasChanges
        ? _localDocumentMerger.replaceInDocument(
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
          )
        : mergedDocument;

    return (
      graph: reconciledGraph,
      clock: clock,
      resolvedGroupIndices: shards.resolvedGroupIndices.toList(),
      shardToIndex: shards.shardToIndex,
      hasChanges: hasChanges,
    );
  }

  /// Sync variant using pre-loaded data. All I/O (merge contract loading,
  /// index discovery, document loading) must be completed beforehand.
  ///
  /// Used by Stage 7c where batch preloading (7b) provides everything needed.
  ReconciledDocument reconcileSync({
    required IriTerm documentIri,
    required RdfGraph mergedDocument,
    required IriTerm typeIri,
    required IriTerm resourceIri,
    required MergeContract mergeContract,
    required Iterable<CrdtIndexData> indexConfigs,
    required DocumentLookup getDocument,
    PipeperfCollector? perf,
  }) {
    final sw = perf?.start('S07c.CrdtMerge.reconcile');

    final shards = _shardDeterminer.determineShards(
      typeIri,
      resourceIri,
      mergedDocument,
      mode: ShardDeterminationMode.strict,
      indexConfigs: indexConfigs,
      getDocument: getDocument,
    );
    sw?.stopSection('shards');

    final clock = _hlcService.getCurrentClock(mergedDocument, documentIri);

    sw?.stopSection('clock');

    final hasChanges =
        _shardsChanged(mergedDocument, documentIri, shards.shards);

    final reconciledGraph = hasChanges
        ? _localDocumentMerger.replaceInDocument(
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
          )
        : mergedDocument;

    sw?.stopSection('replace');

    return (
      graph: reconciledGraph,
      clock: clock,
      resolvedGroupIndices: shards.resolvedGroupIndices.toList(),
      shardToIndex: shards.shardToIndex,
      hasChanges: hasChanges,
    );
  }

  /// Compares current shard assignments in [document] with [newShards].
  bool _shardsChanged(
      RdfGraph document, IriTerm documentIri, Set<IriTerm> newShards) {
    final existing = document
        .findTriples(
          subject: documentIri,
          predicate: SyncManagedDocument.idxBelongsToIndexShard,
        )
        .map((t) => t.object)
        .toSet();
    return existing.length != newShards.length ||
        !newShards.every(existing.contains);
  }
}
