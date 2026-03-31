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
import 'package:locorda_core/src/index/index_discovery.dart';
import 'package:locorda_core/src/index/index_manager.dart';
import 'package:locorda_core/src/index/index_rdf_generator.dart';
import 'package:locorda_core/src/index/shard_determiner.dart';
import 'package:locorda_core/src/mapping/merge_contract_loader.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/sync/pipeline/clock_hash_reader.dart';
import 'package:locorda_core/src/sync/pipeline/content_index_resolver.dart';
import 'package:locorda_core/src/sync/pipeline/document_shard_reconciler.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_support.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';
import 'package:locorda_core/src/sync/pipeline/stages/stage10_shard_entry_load.dart';
import 'package:locorda_core/src/sync/pipeline/stages/stage11a_prepare.dart';
import 'package:locorda_core/src/sync/pipeline/stages/stage11b_contract_load.dart';
import 'package:locorda_core/src/sync/pipeline/stages/stage11c_shard_merge.dart';
import 'package:locorda_core/src/sync/pipeline/stages/stage13_shard_db_commit.dart';
import 'package:locorda_core/src/sync/pipeline/stages/stage14_feedback.dart';
import 'package:locorda_core/src/sync/pipeline/stages/stage1_shard_resolution.dart';
import 'package:locorda_core/src/sync/pipeline/stages/stage3_shard_parse.dart';
import 'package:locorda_core/src/sync/pipeline/stages/stage4_change_detection.dart';
import 'package:locorda_core/src/sync/pipeline/stages/stage5_local_content_load.dart';
import 'package:locorda_core/src/sync/pipeline/stages/stage7a_decode.dart';
import 'package:locorda_core/src/sync/pipeline/stages/stage7b_preload.dart';
import 'package:locorda_core/src/sync/pipeline/stages/stage7c_crdt_merge.dart';
import 'package:locorda_core/src/sync/pipeline/stages/stage9_db_commit.dart';
import 'package:locorda_core/src/storage/document_save_service.dart';
import 'package:locorda_core/src/sync/remote_document_merger.dart';
import 'package:locorda_core/src/sync/shard_document_generator.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:logging/logging.dart';

final _log = Logger('StreamingRemoteSyncOrchestrator');

class StreamingRemoteSyncOrchestrator {
  final Storage _storage;
  final DocumentSaveService _saveService;
  final RemoteId _remoteId;
  final RemoteSyncPipelineSupport _remote;
  final RdfCore _rdfCore;
  final RemoteDocumentMerger _merger;
  final MergeContractLoader _mergeContractLoader;
  final DocumentShardReconciler _reconciler;
  final IndexManager _indexManager;
  final CrdtDocumentManager _documentManager;
  final ShardDocumentGenerator _shardDocGen;
  final IndexRdfGenerator _indexRdfGenerator;
  final IndexDiscovery _indexDiscovery;
  final ShardDeterminer _shardDeterminer;
  final ContentIndexResolver _indexResolver;

  var _syncCounter = 0;

  StreamingRemoteSyncOrchestrator({
    required Storage storage,
    required DocumentSaveService documentSaveService,
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
    required IndexDiscovery indexDiscovery,
    required ShardDeterminer shardDeterminer,
    required ContentIndexResolver indexResolver,
  })  : _storage = storage,
        _saveService = documentSaveService,
        _remoteId = remoteId,
        _remote = pipelineSupport,
        _rdfCore = rdfCore,
        _merger = merger,
        _mergeContractLoader = mergeContractLoader,
        _reconciler = reconciler,
        _indexManager = indexManager,
        _documentManager = documentManager,
        _shardDocGen = shardDocGen,
        _indexRdfGenerator = indexRdfGenerator,
        _indexDiscovery = indexDiscovery,
        _shardDeterminer = shardDeterminer,
        _indexResolver = indexResolver;

  Future<void> sync(
    DateTime syncTime,
    int lastSyncTimestamp, {
    required SyncEngineConfig config,
  }) async {
    _syncCounter++;
    _log.fine('===== SYNC #$_syncCounter START =====');
    _log.info('Starting streaming pipeline sync');

    // Compute meta-index IRIs (IoI, IoGI, IoGIT) from config
    final (:ioi, :iogi, :iogit) = _indexResolver.computeMetaIndexIris();
    final metaIndices = [ioi, iogi, iogit];
    final metaIndexInfos = {
      for (final info in metaIndices) info.iri: info,
    };

    // Read current clock hashes for stability detection (batch).
    // Only 3 meta-index documents — the query/decode/extract overhead is
    // acceptable, but a measurement should verify this is fast enough.
    final docIris = metaIndexInfos.keys.map((iri) => iri.getDocumentIri());
    final metaIndexClockHashes = await readClockHashes(_storage, docIris);

    // Compose and run the pipeline
    final inputController = StreamController<SyncInput>();

    final pipeline = inputController.stream
            .asyncExpand(shardResolution(_storage, _remoteId)) // Stage 1
            .transform(_remote.shardFetch()) // Stage 2
            .map(shardParse(_rdfCore)) // Stage 3
            .asyncExpand(
                changeDetection(_storage, lastSyncTimestamp)) // Stage 4
            .transform(localContentLoad(_storage, _remoteId)) // Stage 5
            .transform(_remote.resourceFetch()) // Stage 6
            .map(decodeCandidates(_mergeContractLoader, _rdfCore)) // Stage 7a
            .transform(preloadCandidates(_mergeContractLoader, _indexDiscovery,
                _shardDeterminer, _storage, _indexRdfGenerator)) // Stage 7b
            .expand(mergeCandidates(_merger, _reconciler, _rdfCore)) // Stage 7c
            .transform(_remote.resourceUpload()) // Stage 8
            .asyncExpand(dbCommit(
                _storage, _indexManager, _remoteId, _saveService)) // Stage 9
            .asyncExpand(shardEntryLoad(_storage)) // Stage 10
            .expand(prepareShards(_shardDocGen, config)) // Stage 11a
            .asyncMap(loadShardContracts(_mergeContractLoader)) // Stage 11b
            .expand(mergeShards(_documentManager, _rdfCore)) // Stage 11c
            .transform(_remote.shardUpload()) // Stage 12
            .asyncExpand(shardDbCommit(_storage, _remoteId)) // Stage 13
            .asyncExpand(feedback(
                inputController.sink, _storage, _indexResolver)) // Stage 14
        ;

    // Seed with meta-index phase
    _log.fine('Seeding pipeline with meta indices: '
        '${ioi.iri.debug}, ${iogi.iri.debug}, ${iogit.iri.debug}');
    inputController.add(SyncInput(
      // Seed with meta-index IRIs and clock hashes for stability checks,
      // ensure the correct order.
      metaIndices.map((info) => info.iri).toList(),
      metaIndexClockHashes: metaIndexClockHashes,
      indexInfos: metaIndexInfos,
    ));

    await pipeline.drain();
    _log.info('Streaming pipeline sync completed');
  }
}
