/// Resolves index IRIs and their [IndexInputInfo] for pipeline phases.
///
/// Encapsulates the index resolution logic extracted from
/// [StreamingRemoteSyncOrchestrator] so the orchestrator only needs to compose
/// and run the pipeline.
library;

import 'package:locorda_core/src/config/sync_engine_config.dart'
    show FullIndexData, SyncEngineConfig;
import 'package:locorda_core/src/index/index_config_base.dart'
    show RootResourceFetchPolicy;
import 'package:locorda_core/src/index/index_rdf_generator.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/storage/remote_id.dart' show RemoteId;
import 'package:locorda_core/src/storage/storage_interface.dart' show Storage;
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart'
    show IndexInputInfo;
import 'package:locorda_core/src/vocab/generated/_index.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:logging/logging.dart';

final _log = Logger('ContentIndexResolver');

class ContentIndexResolver {
  final Storage _storage;
  final IndexRdfGenerator _indexRdfGenerator;
  final RemoteId _remoteId;
  final SyncEngineConfig _config;

  ContentIndexResolver({
    required Storage storage,
    required IndexRdfGenerator indexRdfGenerator,
    required RemoteId remoteId,
    required SyncEngineConfig config,
  })  : _storage = storage,
        _indexRdfGenerator = indexRdfGenerator,
        _remoteId = remoteId,
        _config = config;

  /// Compute the meta-index IRI for a given index resource type.
  ///
  /// Each meta resource type (FullIndex, GroupIndex, GroupIndexTemplate) must
  /// have exactly one FullIndex in the config. Throws if the resource type is
  /// not configured.
  IndexInputInfo _computeMetaIndexIri(IriTerm typeIri) {
    final resourceConfig = _config.getResourceConfig(typeIri);
    final fullIndex = resourceConfig.indices.whereType<FullIndexData>().single;
    final iri = _indexRdfGenerator.generateFullIndexIri(fullIndex, typeIri);
    return IndexInputInfo(iri, fullIndex.rootResourceFetchPolicy, typeIri);
  }

  ({IndexInputInfo ioi, IndexInputInfo iogi, IndexInputInfo iogit})
      computeMetaIndexIris() => (
            ioi: _computeMetaIndexIri(IdxFullIndex.classIri),
            iogi: _computeMetaIndexIri(IdxGroupIndex.classIri),
            iogit: _computeMetaIndexIri(IdxGroupIndexTemplate.classIri),
          );

  /// Build content-phase index map: all FullIndex + subscribed GroupIndex IRIs
  /// for non-meta resource types.
  ///
  /// Called by Stage 14 exactly once when transitioning from meta to content.
  Future<Map<IriTerm, IndexInputInfo>> resolveContentIndices() async {
    final metaTypes = {
      IdxFullIndex.classIri,
      IdxGroupIndexTemplate.classIri,
      IdxGroupIndex.classIri,
    };

    final result = <IriTerm, IndexInputInfo>{};
    final contentResources =
        _config.resources.where((r) => !metaTypes.contains(r.typeIri)).toList();

    // FullIndex IRIs from config — pure computation, no DB
    for (final resourceConfig in contentResources) {
      final typeIri = resourceConfig.typeIri;
      for (final index in resourceConfig.indices.whereType<FullIndexData>()) {
        final indexIri =
            _indexRdfGenerator.generateFullIndexIri(index, typeIri);
        result[indexIri] =
            IndexInputInfo(indexIri, index.rootResourceFetchPolicy, typeIri);
      }
    }

    // Subscribed GroupIndex IRIs — all types in a single batch query
    final allGroupIndices = await _storage.getAllSubscribedGroupIndices(
        contentResources.map((r) => r.typeIri));
    for (final resourceConfig in contentResources) {
      final typeIri = resourceConfig.typeIri;
      final groupSubs = allGroupIndices[typeIri];
      if (groupSubs == null) continue;
      for (final (groupIndexIri, _, fetchPolicy) in groupSubs) {
        result[groupIndexIri] =
            IndexInputInfo(groupIndexIri, fetchPolicy, typeIri);
      }
    }

    // Foreign indices — all types in a single batch query
    final sinceTimestamp = await _storage.getLastRemoteSyncTimestamp(_remoteId);
    final configuredIris = result.keys.toSet();
    final allForeignShards = await _storage.getForeignIndexShardsToSyncForTypes(
      resourceTypes: contentResources.map((r) => r.typeIri),
      sinceTimestamp: sinceTimestamp,
      excludeIndexIris: configuredIris,
    );
    for (final MapEntry(key: typeIri, value: indexMap)
        in allForeignShards.entries) {
      for (final indexIri in indexMap.keys) {
        // Foreign indices use OnRequest fetch policy — Stage 4 skips
        // remoteOnly entries, giving upload-only behavior.
        result[indexIri] =
            IndexInputInfo(indexIri, RootResourceFetchPolicy.onRequest, typeIri);
      }
    }

    // Foreign indices discovered from meta-phase: FullIndex/GroupIndex
    // instance documents downloaded during meta-phase may reference content
    // types not covered by the local config.
    await _discoverForeignIndicesFromMeta(metaTypes, result);

    _log.fine('Resolved ${result.length} content indices');
    return result;
  }

  /// Discover foreign indices by reading index instance documents downloaded
  /// during the meta-phase. Batches all DB access into three queries regardless
  /// of how many meta-index shards or candidate entries exist.
  Future<void> _discoverForeignIndicesFromMeta(
    Set<IriTerm> metaTypes,
    Map<IriTerm, IndexInputInfo> result,
  ) async {
    final contentTypes = _config.resources
        .where((r) => !metaTypes.contains(r.typeIri))
        .map((r) => r.typeIri)
        .toSet();

    // 1. Resolve all shard IRIs for IoI + IoGI meta-indices in one query
    final ioiMetaIri = _computeMetaIndexIri(IdxFullIndex.classIri).iri;
    final iogiMetaIri = _computeMetaIndexIri(IdxGroupIndex.classIri).iri;
    final shardsByMeta =
        await _storage.getIndexShards([ioiMetaIri, iogiMetaIri]);
    final allShardIris = [
      ...?shardsByMeta[ioiMetaIri],
      ...?shardsByMeta[iogiMetaIri],
    ];
    if (allShardIris.isEmpty) return;

    // 2. Batch-load all entries across all shards
    final entriesByShard =
        await _storage.getActiveIndexEntriesForShards(allShardIris);

    // Collect candidate instance document IRIs, skipping already-known indices
    final candidateDocToResource = <IriTerm, IriTerm>{}; // docIri → resourceIri
    for (final entries in entriesByShard.values) {
      for (final entry in entries) {
        if (!result.containsKey(entry.resourceIri)) {
          candidateDocToResource[entry.resourceIri.getDocumentIri()] =
              entry.resourceIri;
        }
      }
    }
    if (candidateDocToResource.isEmpty) return;

    // 3. Batch-fetch all candidate instance documents
    final docs = await _storage.getDocumentsByIri(candidateDocToResource.keys);
    for (final MapEntry(:key, :value) in candidateDocToResource.entries) {
      final doc = docs[key];
      if (doc == null) continue;
      final indexedClass =
          doc.document.findSingleObject<IriTerm>(value, IdxIndex.indexesClass);
      if (indexedClass != null && contentTypes.contains(indexedClass)) {
        result[value] = IndexInputInfo(
            value, RootResourceFetchPolicy.prefetch, indexedClass);
        _log.fine(
            'Discovered foreign index: ${value.debug} for ${indexedClass.debug}');
      }
    }
  }
}
