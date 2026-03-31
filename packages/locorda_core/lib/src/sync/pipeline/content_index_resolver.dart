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
    final allGroupIndices = await _storage
        .getAllSubscribedGroupIndices(contentResources.map((r) => r.typeIri));
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
        // TODO(perf): The non-pipeline uses PartialIndexSync to limit sync to
        //   only the specific shards with dirty/uncovered entries. Here we
        //   sync all shards of the foreign index (downloading all shard
        //   documents) even though only a subset is relevant. Consider
        //   introducing a PartialIndexInputInfo type that carries the shard
        //   set from getForeignIndexShardsToSyncForTypes so Stage 1 can apply
        //   the same pruning.
        result[indexIri] = IndexInputInfo(
            indexIri, RootResourceFetchPolicy.onRequest, typeIri);
      }
    }

    _log.fine('Resolved ${result.length} content indices');
    return result;
  }
}
