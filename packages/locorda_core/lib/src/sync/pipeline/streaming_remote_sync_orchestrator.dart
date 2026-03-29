/// Streaming pipeline orchestrator for remote synchronization.
///
/// Composes the 14-stage streaming pipeline from proposal 007 and runs it
/// against a [RemoteSyncPipelineSupport]-capable backend.
///
/// Replaces [RemoteSyncOrchestrator] when the backend supports streaming.
/// Both orchestrators share the same [Storage], [CrdtDocumentManager],
/// [IndexManager], etc. and produce identical results.
library;

import 'dart:async';

import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_core/src/crdt_document_manager.dart';
import 'package:locorda_core/src/index/index_manager.dart';
import 'package:locorda_core/src/index/index_rdf_generator.dart';
import 'package:locorda_core/src/mapping/merge_contract_loader.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/sync/pipeline/document_shard_reconciler.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_support.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';
import 'package:locorda_core/src/sync/pipeline/stages/stage10_shard_entry_load.dart';
import 'package:locorda_core/src/sync/pipeline/stages/stage11_shard_crdt_merge.dart';
import 'package:locorda_core/src/sync/pipeline/stages/stage13_shard_db_commit.dart';
import 'package:locorda_core/src/sync/pipeline/stages/stage14_feedback.dart';
import 'package:locorda_core/src/sync/pipeline/stages/stage1_shard_resolution.dart';
import 'package:locorda_core/src/sync/pipeline/stages/stage3_shard_parse.dart';
import 'package:locorda_core/src/sync/pipeline/stages/stage4_change_detection.dart';
import 'package:locorda_core/src/sync/pipeline/stages/stage5_local_content_load.dart';
import 'package:locorda_core/src/sync/pipeline/stages/stage7_crdt_merge.dart';
import 'package:locorda_core/src/sync/pipeline/stages/stage9_db_commit.dart';
import 'package:locorda_core/src/sync/remote_document_merger.dart';
import 'package:locorda_core/src/sync/shard_document_generator.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:logging/logging.dart';

final _log = Logger('StreamingRemoteSyncOrchestrator');

var _syncCounter = 0;

class StreamingRemoteSyncOrchestrator {
  final Storage _storage;
  final RemoteId _remoteId;
  final RemoteSyncPipelineSupport _pipelineSupport;
  final RdfCore _rdfCore;
  final RemoteDocumentMerger _merger;
  final MergeContractLoader _mergeContractLoader;
  final DocumentShardReconciler _reconciler;
  final IndexManager _indexManager;
  final CrdtDocumentManager _documentManager;
  final ShardDocumentGenerator _shardDocGen;
  final IndexRdfGenerator _indexRdfGenerator;
  final SyncEngineConfig _config;

  StreamingRemoteSyncOrchestrator({
    required Storage storage,
    required RemoteId remoteId,
    required RemoteSyncPipelineSupport pipelineSupport,
    required RdfCore rdfCore,
    required RemoteDocumentMerger merger,
    required MergeContractLoader mergeContractLoader,
    required DocumentShardReconciler reconciler,
    required IndexManager indexManager,
    required CrdtDocumentManager documentManager,
    required ShardDocumentGenerator shardDocGen,
    required IndexRdfGenerator indexRdfGenerator,
    required SyncEngineConfig config,
  })  : _storage = storage,
        _remoteId = remoteId,
        _pipelineSupport = pipelineSupport,
        _rdfCore = rdfCore,
        _merger = merger,
        _mergeContractLoader = mergeContractLoader,
        _reconciler = reconciler,
        _indexManager = indexManager,
        _documentManager = documentManager,
        _shardDocGen = shardDocGen,
        _indexRdfGenerator = indexRdfGenerator,
        _config = config;

  Future<void> sync(
    DateTime syncTime,
    int lastSyncTimestamp, {
    required SyncEngineConfig config,
  }) async {
    _syncCounter++;
    print('DEBUG SRSO: ===== SYNC #$_syncCounter START =====');
    _log.info('Starting streaming pipeline sync');

    // Compute IoI, IoGI, and IoGIT IRIs from config
    final ioiIri = _computeMetaIndexIri(IdxFullIndex.classIri, 'fullIndices');
    final iogiIri =
        _computeMetaIndexIri(IdxGroupIndex.classIri, 'groupIndices');
    final iogitIri = _computeMetaIndexIri(
        IdxGroupIndexTemplate.classIri, 'groupIndexTemplates');

    if (ioiIri == null || iogiIri == null || iogitIri == null) {
      _log.warning('Meta-index IRIs not found in config — skipping sync');
      return;
    }

    // Read current clock hashes for stability detection
    final metaIndexClockHashes =
        await _readClockHashes([ioiIri, iogiIri, iogitIri]);

    // Build index infos for the meta phase
    final metaIndexInfos =
        _buildMetaIndexInfos(config, ioiIri, iogiIri, iogitIri);

    // Compose and run the pipeline
    final inputController = StreamController<SyncInput>();

    final pipeline = inputController.stream
            .asyncExpand(shardResolution(_storage, _remoteId)) // Stage 1
            .transform(_pipelineSupport.shardFetch()) // Stage 2
            .map(shardParse(_rdfCore)) // Stage 3
            .asyncExpand(
                changeDetection(_storage, lastSyncTimestamp)) // Stage 4
            .transform(localContentLoad(_storage, _remoteId)) // Stage 5
            .transform(_pipelineSupport.resourceFetch()) // Stage 6
            .asyncExpand(crdtMerge(_merger, _mergeContractLoader, _reconciler,
                _rdfCore)) // Stage 7
            .transform(_pipelineSupport.resourceUpload()) // Stage 8
            .asyncExpand(
                dbCommit(_storage, _indexManager, _remoteId)) // Stage 9
            .asyncExpand(shardEntryLoad(_storage)) // Stage 10
            .asyncExpand(shardCrdtMerge(
                _documentManager, _shardDocGen, _rdfCore)) // Stage 11
            .transform(_pipelineSupport.shardUpload()) // Stage 12
            .asyncExpand(shardDbCommit(_storage, _remoteId)) // Stage 13
            .asyncExpand(feedback(inputController.sink, _storage,
                () => _contentIndicesFactory(config))) // Stage 14
        ;

    // Seed with meta-index phase
    _log.fine('Seeding pipeline with meta indices: '
        '${ioiIri.debug}, ${iogiIri.debug}, ${iogitIri.debug}');
    inputController.add(SyncInput(
      [ioiIri, iogiIri, iogitIri],
      metaIndexClockHashes: metaIndexClockHashes,
      indexInfos: metaIndexInfos,
    ));

    await pipeline.drain();
    _log.info('Streaming pipeline sync completed');
  }

  /// Compute a meta-index IRI from config by matching the resource type and
  /// index local name.
  IriTerm? _computeMetaIndexIri(IriTerm typeIri, String indexNameField) {
    final resourceConfig =
        _config.resources.where((r) => r.typeIri == typeIri).firstOrNull;
    if (resourceConfig == null) return null;

    final fullIndex =
        resourceConfig.indices.whereType<FullIndexData>().firstOrNull;
    if (fullIndex == null) return null;

    return _indexRdfGenerator.generateFullIndexIri(fullIndex, typeIri);
  }

  /// Read clock hashes for the given index IRIs from storage.
  ///
  /// Returns a map of document IRIs → clock hash strings.
  /// Uses the same approach as Stage 14 for consistency.
  Future<Map<IriTerm, String>> _readClockHashes(List<IriTerm> indexIris) async {
    final result = <IriTerm, String>{};
    for (final indexIri in indexIris) {
      final docIri = indexIri.getDocumentIri();
      final doc = await _storage.getDocument(docIri);
      if (doc != null) {
        final clockHash = doc.document
            .findSingleObject<LiteralTerm>(
                docIri, SyncManagedDocument.crdtClockHash)
            ?.value;
        if (clockHash != null) {
          result[docIri] = clockHash;
        }
      }
    }
    return result;
  }

  /// Build [IndexInputInfo] map for meta-indices (IoI, IoGI, IoGIT).
  Map<IriTerm, IndexInputInfo> _buildMetaIndexInfos(
    SyncEngineConfig config,
    IriTerm ioiIri,
    IriTerm iogiIri,
    IriTerm iogitIri,
  ) {
    final infos = <IriTerm, IndexInputInfo>{};

    // IoI indexes FullIndex documents
    final ioiConfig =
        config.resources.firstWhere((r) => r.typeIri == IdxFullIndex.classIri);
    final ioiFullIndex = ioiConfig.indices.whereType<FullIndexData>().first;
    infos[ioiIri] = IndexInputInfo(
        ioiFullIndex.rootResourceFetchPolicy, IdxFullIndex.classIri);

    // IoGI indexes GroupIndex documents — force Prefetch so all group index
    // instance documents are downloaded during the meta phase. The content
    // phase needs these documents to resolve shard IRIs via Stage 1.
    infos[iogiIri] = IndexInputInfo(
        RootResourceFetchPolicy.prefetch, IdxGroupIndex.classIri);

    // IoGIT indexes GroupIndexTemplate documents — force Prefetch so all
    // template documents are available before the content phase. Content-phase
    // shard reconciliation needs templates to create missing group indices.
    infos[iogitIri] = IndexInputInfo(
        RootResourceFetchPolicy.prefetch, IdxGroupIndexTemplate.classIri);

    return infos;
  }

  /// Build content-phase index map: all FullIndex + subscribed GroupIndex IRIs
  /// for non-meta resource types.
  ///
  /// Called by Stage 14 exactly once when transitioning from meta to content.
  Future<Map<IriTerm, IndexInputInfo>> _contentIndicesFactory(
    SyncEngineConfig config,
  ) async {
    final metaTypes = {
      IdxFullIndex.classIri,
      IdxGroupIndexTemplate.classIri,
      IdxGroupIndex.classIri,
    };

    final result = <IriTerm, IndexInputInfo>{};

    for (final resourceConfig in config.resources) {
      final typeIri = resourceConfig.typeIri;
      if (metaTypes.contains(typeIri)) continue;

      // FullIndex IRIs from config
      for (final index in resourceConfig.indices.whereType<FullIndexData>()) {
        final indexIri =
            _indexRdfGenerator.generateFullIndexIri(index, typeIri);
        result[indexIri] =
            IndexInputInfo(index.rootResourceFetchPolicy, typeIri);
      }

      // Subscribed GroupIndex IRIs from DB
      final groupIndices = await _storage.getSubscribedGroupIndices(typeIri);
      for (final (groupIndexIri, _, fetchPolicy) in groupIndices) {
        result[groupIndexIri] = IndexInputInfo(fetchPolicy, typeIri);
      }
    }

    // Foreign indices from dirty entries
    final configuredIris = result.keys.toSet();
    for (final resourceConfig in config.resources) {
      final typeIri = resourceConfig.typeIri;
      if (metaTypes.contains(typeIri)) continue;

      final foreignShards = await _storage.getForeignIndexShardsToSync(
        resourceType: typeIri,
        sinceTimestamp: await _storage.getLastRemoteSyncTimestamp(_remoteId),
        excludeIndexIris: configuredIris,
      );

      for (final indexIri in foreignShards.keys) {
        // Foreign indices use OnRequest fetch policy — Stage 4 skips
        // remoteOnly entries, giving upload-only behavior.
        result[indexIri] =
            IndexInputInfo(RootResourceFetchPolicy.onRequest, typeIri);
      }
    }

    // Foreign indices discovered from meta-phase: FullIndex/GroupIndex
    // instance documents downloaded during meta-phase may reference content
    // types not covered by the local config.
    await _discoverForeignIndicesFromMeta(config, metaTypes, result);

    _log.fine('Content indices factory: ${result.length} indices');
    return result;
  }

  /// Discover foreign indices by reading index instance documents downloaded
  /// during the meta-phase. Checks `idx:indexesClass` to determine what
  /// resource type each index serves.
  Future<void> _discoverForeignIndicesFromMeta(
    SyncEngineConfig config,
    Set<IriTerm> metaTypes,
    Map<IriTerm, IndexInputInfo> result,
  ) async {
    final contentTypes = config.resources
        .where((r) => !metaTypes.contains(r.typeIri))
        .map((r) => r.typeIri)
        .toSet();

    // Read IoI to find all FullIndex instance IRIs
    final ioiIri = _computeMetaIndexIri(IdxFullIndex.classIri, 'fullIndices');
    if (ioiIri == null) return;

    final ioiDocIri = ioiIri.getDocumentIri();
    final ioiDoc = await _storage.getDocument(ioiDocIri);
    if (ioiDoc == null) return;

    final shardIris = ioiDoc.document
        .getMultiValueObjects<IriTerm>(ioiIri, IdxIndex.hasShard);

    for (final shardIri in shardIris) {
      final entries = await _storage.getActiveIndexEntriesForShard(shardIri);
      for (final entry in entries) {
        if (result.containsKey(entry.resourceIri)) continue;

        // Load the FullIndex instance document to check what it indexes
        final instanceDocIri = entry.resourceIri.getDocumentIri();
        final instanceDoc = await _storage.getDocument(instanceDocIri);
        if (instanceDoc == null) continue;

        final indexedClass = instanceDoc.document.findSingleObject<IriTerm>(
            entry.resourceIri, IdxIndex.indexesClass);
        if (indexedClass != null && contentTypes.contains(indexedClass)) {
          result[entry.resourceIri] =
              IndexInputInfo(RootResourceFetchPolicy.prefetch, indexedClass);
          _log.fine('Discovered foreign FullIndex: ${entry.resourceIri.debug} '
              'for ${indexedClass.debug}');
        }
      }
    }

    // Read IoGI to find foreign GroupIndex instances
    final iogiIri =
        _computeMetaIndexIri(IdxGroupIndex.classIri, 'groupIndices');
    if (iogiIri == null) return;

    final iogiDocIri = iogiIri.getDocumentIri();
    final iogiDoc = await _storage.getDocument(iogiDocIri);
    if (iogiDoc == null) return;

    final iogiShardIris = iogiDoc.document
        .getMultiValueObjects<IriTerm>(iogiIri, IdxIndex.hasShard);

    for (final shardIri in iogiShardIris) {
      final entries = await _storage.getActiveIndexEntriesForShard(shardIri);
      for (final entry in entries) {
        if (result.containsKey(entry.resourceIri)) continue;

        final instanceDocIri = entry.resourceIri.getDocumentIri();
        final instanceDoc = await _storage.getDocument(instanceDocIri);
        if (instanceDoc == null) continue;

        final indexedClass = instanceDoc.document.findSingleObject<IriTerm>(
            entry.resourceIri, IdxIndex.indexesClass);
        if (indexedClass != null && contentTypes.contains(indexedClass)) {
          result[entry.resourceIri] =
              IndexInputInfo(RootResourceFetchPolicy.prefetch, indexedClass);
          _log.fine('Discovered foreign GroupIndex: ${entry.resourceIri.debug} '
              'for ${indexedClass.debug}');
        }
      }
    }
  }
}
