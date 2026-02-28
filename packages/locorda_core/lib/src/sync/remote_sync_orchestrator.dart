import 'package:collection/collection.dart';
import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_core/src/hlc_service.dart';
import 'package:locorda_core/src/index/index_config_base.dart';
import 'package:locorda_core/src/index/index_manager.dart';
import 'package:locorda_core/src/index/index_rdf_generator.dart';
import 'package:locorda_core/src/index/shard_determiner.dart';
import 'package:locorda_core/src/local_document_merger.dart';
import 'package:locorda_core/src/mapping/merge_contract.dart';
import 'package:locorda_core/src/mapping/merge_contract_loader.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/storage/remote_storage.dart';
import 'package:locorda_core/src/sync/dataset_based_graph_sync_storage.dart';
import 'package:locorda_core/src/sync/remote_document_merger.dart';
import 'package:locorda_core/src/sync/shard_document_generator.dart';
import 'package:locorda_core/src/util/retry.dart';
import 'package:locorda_core/src/vocab/generated/_index.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:logging/logging.dart';

final _log = Logger('RemoteSyncOrchestrator');

/// Specification for syncing an index with its shards
sealed class IndexSyncSpec {
  /// The IRI of the index to sync
  final IriTerm indexIri;

  const IndexSyncSpec({required this.indexIri});
}

/// Full index sync: Download all shards and apply fetch policy for new items
final class FullIndexSync extends IndexSyncSpec {
  /// Policy determining which items to download from remote
  final RootResourceFetchPolicy fetchPolicy;

  const FullIndexSync(
    IriTerm indexIri,
    this.fetchPolicy,
  ) : super(indexIri: indexIri);
  @override
  String toString() {
    return 'FullIndexSync(indexIri: ${indexIri.debug}, fetchPolicy: ${fetchPolicy.toString()})';
  }
}

/// Partial index sync: Upload-only for specific shards containing known items
final class PartialIndexSync extends IndexSyncSpec {
  /// Map of shard IRIs to the map of resource IRIs with their local clockHashes
  /// Only these specific items will be synced (upload local changes, no remote downloads)
  final Map<IriTerm /*shardIri*/,
      Map<IriTerm /*resourceIri*/, String /*localClockHash*/ >> shardItems;

  const PartialIndexSync({
    required super.indexIri,
    required this.shardItems,
  });

  @override
  String toString() {
    return 'PartialIndexSync(indexIri: ${indexIri.debug}, shardItems: ${shardItems.entries.map((e) => '\nShard ${e.key.debug}:\n\t${e.value.entries.map((e) => '${e.key.debug}: ${e.value}').join('\n\t')}').join('')}\n)';
  }
}

sealed class ShardSyncSpec {
  final IriTerm shardIri;

  const ShardSyncSpec({required this.shardIri});
}

final class FullShardSync extends ShardSyncSpec {
  final RootResourceFetchPolicy fetchPolicy;
  const FullShardSync({required super.shardIri, required this.fetchPolicy});
}

/// Partial shard sync for foreign indices.
/// Only syncs specific resources from the shard (upload-only, no prefetch).
final class PartialShardSync extends ShardSyncSpec {
  /// Map of resource IRIs to their local clockHashes
  final Map<IriTerm, String> resourceClockHashes;

  const PartialShardSync({
    required super.shardIri,
    required this.resourceClockHashes,
  });
}

typedef _DownloadAndMergeResult<T> = ({
  RdfGraph mergedDocument,
  RdfGraph? originalLocalDocument,
  T? originalRemoteDocument,
  MergeContract mergeContract,
  String? etag,
  int? localUpdatedAt
});

typedef PreparedShardSync<T> = ({
  IriTerm shardIri,
  _DownloadAndMergeResult<T> merged,
  ShardSyncSpec shardSpec,
});

typedef _BatchSyncCandidate = ({
  IriTerm documentIri,
  String debugName,
});

/// DB-only result of [RemoteSyncOrchestrator._collectIndexSpecs].
typedef _CollectedIndexSpecs = ({
  List<IndexSyncSpec> allSpecs,
  Set<IriTerm> groupIndexIris,
});

typedef _DeferredBatchCommit = ({
  List<SaveDocumentRequest> saveRequests,
  List<SaveIndexEntryRequest> indexEntryRequests,
  Map<IriTerm, String> etagUpdates,
});

/// Entry in the document queue tracking sync metadata for a resource
final class _DocumentQueueEntry {
  /// Resource IRI (not document IRI)
  final IriTerm resourceIri;

  /// Clock hash from local index entry, null if not present locally
  final String? localClockHash;

  /// Clock hash from remote shard entry, null if not present remotely
  final String? remoteClockHash;

  /// Filter values from local entry (for PrefetchFiltered policies)
  final Set<RdfObject>? localFilterValues;

  /// Filter values from remote entry (for PrefetchFiltered policies)
  final Set<RdfObject>? remoteFilterValues;

  const _DocumentQueueEntry({
    required this.resourceIri,
    required this.localClockHash,
    required this.remoteClockHash,
    this.localFilterValues,
    this.remoteFilterValues,
  });

  /// Whether this resource needs synchronization (different clock hashes)
  bool get needsSync => localClockHash != remoteClockHash;

  /// Whether this resource exists locally
  bool get existsLocally => localClockHash != null;

  /// Whether this resource exists remotely
  bool get existsRemotely => remoteClockHash != null;
}

/// Orchestrates remote synchronization following the revised algorithm.
///
/// Implements the process from "Synchronization Algorithm Sketch.md":
/// - Phase A: Metadata Reconciliation & Queue Building
/// - Phase B: Document & Shard Finalization
///
/// Assumes Phase 0 (Sync Preparation) has already been completed by
/// _ensureShardDocumentsAreUpToDate, which materialized shard state in DB.
class RemoteSyncOrchestrator {
  final RemoteSyncStorage _remoteSyncStorage;
  final RemoteId _remoteId;
  final Storage _storage;
  final IndexRdfGenerator _indexRdfGenerator;
  final _DocumentSyncHelper _docSync;
  final bool _useShardDatasets;
  late final _ShardSyncOrchestrator _shardSyncOrchestrator;

  RemoteSyncOrchestrator({
    required RemoteSyncStorage remoteSyncStorage,
    required RemoteId remoteId,
    required Storage storage,
    required RemoteDocumentMerger merger,
    required IndexRdfGenerator indexRdfGenerator,
    required IndexManager indexManager,
    required ShardDeterminer shardDeterminer,
    required HlcService hlcService,
    required MergeContractLoader mergeContractLoader,
    required LocalDocumentMerger localDocumentMerger,
    required ShardDocumentGenerator shardDocumentGenerator,
    required PhysicalTimestampFactory physicalTimestampFactory,
    required bool useShardDatasets,
  })  : _remoteSyncStorage = remoteSyncStorage,
        _remoteId = remoteId,
        _storage = storage,
        _indexRdfGenerator = indexRdfGenerator,
        _useShardDatasets = useShardDatasets,
        _docSync = _DocumentSyncHelper(
          storage: storage,
          remoteId: remoteId,
          mergeContractLoader: mergeContractLoader,
          merger: merger,
          indexManager: indexManager,
          shardDeterminer: shardDeterminer,
          hlcService: hlcService,
          localDocumentMerger: localDocumentMerger,
          physicalTimestampFactory: physicalTimestampFactory,
        ) {
    _shardSyncOrchestrator = _ShardSyncOrchestrator(
      storage: storage,
      hlcService: hlcService,
      shardDocumentGenerator: shardDocumentGenerator,
      localDocumentMerger: localDocumentMerger,
      documentSyncHelper: _docSync,
    );
  }

  /// Execute complete remote synchronization cycle.
  ///
  /// Sync order:
  /// 1. Meta-types (idx:FullIndex, idx:GroupIndexTemplate) sequentially via
  ///    [_syncResourceType] — preserves the index-of-indices-first invariant.
  /// 2. All remaining content types via [_syncContentResourceTypes], which
  ///    batches GroupIndex document syncs across all types before processing
  ///    shards, eliminating the per-document roundtrip storm.
  Future<void> sync(
    DateTime syncTime,
    int lastSyncTimestamp, {
    required SyncEngineConfig config,
  }) async {
    _log.info('Starting remote synchronization cycle');
    try {
      const metaTypes = [IdxFullIndex.classIri, IdxGroupIndexTemplate.classIri];
      final contentTypes = config.resourcesInSyncOrder
          .map((r) => r.typeIri)
          .where((t) => !metaTypes.contains(t))
          .toList();

      // Phase 1+2: Meta-types sequentially — index-of-indices must precede content.
      for (final resourceType in metaTypes) {
        if (config.resources.any((r) => r.typeIri == resourceType)) {
          await _syncResourceType(
            resourceType,
            lastSyncTimestamp,
            syncTime,
            remoteSyncStorage: _remoteSyncStorage,
            config: config,
          );
        }
      }

      // Phase 3+: Content types — flat batched approach.
      if (contentTypes.isNotEmpty) {
        await _syncContentResourceTypes(
          contentTypes,
          lastSyncTimestamp,
          syncTime,
          remoteSyncStorage: _remoteSyncStorage,
          config: config,
        );
      }

      _log.info('Remote synchronization cycle completed successfully');
    } catch (e, st) {
      // TODO: should we catch the exception per resource type and continue with others?
      _log.severe('Remote synchronization cycle failed', e, st);
      rethrow;
    }
  }

  /// Collects all [IndexSyncSpec]s for a content resource type without any
  /// network I/O — pure DB + config reads.
  ///
  /// Separates the spec-collection concern from the network-sync concern so
  /// that [_syncContentResourceTypes] can batch the GroupIndex document syncs
  /// across all types before processing shards.
  Future<_CollectedIndexSpecs> _collectIndexSpecs(
    IriTerm resourceType,
    SyncEngineConfig config,
  ) async {
    final resourceConfig =
        config.resources.firstWhere((r) => r.typeIri == resourceType);

    final fullIndices =
        resourceConfig.indices.whereType<FullIndexData>().map((index) {
      final iri = _indexRdfGenerator.generateFullIndexIri(index, resourceType);
      return FullIndexSync(iri, index.rootResourceFetchPolicy);
    }).toList();

    final groupIndices = await _storage.getSubscribedGroupIndices(resourceType);
    final groupIndexTuples = groupIndices
        .map((tuple) => FullIndexSync(tuple.$1,
            _useShardDatasets ? RootResourceFetchPolicy.prefetch : tuple.$3))
        .toList();
    final groupIndexIris = groupIndices.map((tuple) => tuple.$1).toSet();

    final configuredIndices = <IndexSyncSpec>[
      ...fullIndices,
      ...groupIndexTuples,
    ];
    final configuredIndexIris =
        configuredIndices.map((spec) => spec.indexIri).toSet();

    final foreignIndices = await _findForeignIndices(
      resourceType: resourceType,
      configuredIndexIris: configuredIndexIris,
    );

    _log.fine(
        'Collected ${configuredIndices.length} configured and ${foreignIndices.length} foreign indices for ${resourceType.debug}');

    return (
      allSpecs: [...configuredIndices, ...foreignIndices],
      groupIndexIris: groupIndexIris,
    );
  }

  /// Syncs all content resource types using a flat batch strategy:
  ///
  /// 1. **DB phase** — collect [IndexSyncSpec]s for every type in parallel
  ///    (pure DB reads, no network).
  /// 2. **Batch GroupIndex sync** — all GroupIndex documents across all types
  ///    are downloaded and uploaded in a single [syncDocumentsBatch] call
  ///    wrapped in [retryOnConflict].
  /// 3. **Shard phase** — shards for each type/index processed as before.
  ///
  /// FullIndex documents for content types do not need individual syncs here
  /// because they were already updated during the meta-type (index-of-indices)
  /// phase.
  Future<void> _syncContentResourceTypes(
    List<IriTerm> resourceTypes,
    int lastSyncTimestamp,
    DateTime syncTime, {
    required RemoteSyncStorage remoteSyncStorage,
    required SyncEngineConfig config,
  }) async {
    // Phase 3a: DB-only — collect specs for all types (parallelisable).
    final specFutures = resourceTypes
        .map((t) => _collectIndexSpecs(t, config).then((s) => (t, s)));
    final specResults = await Future.wait(specFutures);
    final allSpecsByType =
        Map.fromEntries(specResults.map((r) => MapEntry(r.$1, r.$2)));

    // Phase 3b: Network — one batch for all GroupIndex documents.
    final allGroupIndexCandidates = <_BatchSyncCandidate>[];
    for (final entry in allSpecsByType.entries) {
      for (final indexIri in entry.value.groupIndexIris) {
        final documentIri = indexIri.getDocumentIri();
        allGroupIndexCandidates.add((
          documentIri: documentIri,
          debugName: 'GroupIndex ${documentIri.debug}',
        ));
      }
    }

    if (allGroupIndexCandidates.isNotEmpty) {
      _log.info(
          'Batch syncing ${allGroupIndexCandidates.length} GroupIndex documents across ${resourceTypes.length} types');
      await retryOnConflict(
        () => _docSync.syncDocumentsBatch(
          allGroupIndexCandidates,
          lastSyncTimestamp,
          syncTime,
          graphSyncStorage: remoteSyncStorage,
        ),
        debugOperationName: 'batch syncing GroupIndex documents',
      );
    }

    // Phase 3c: Process shards for each type in canonical order.
    for (final resourceType in resourceTypes) {
      final specs = allSpecsByType[resourceType]!;
      _log.info('Syncing shards for resource type: ${resourceType.debug}');
      await _executeInChunks(
          specs.allSpecs.map((index) => () => _syncIndex(
              resourceType, index, lastSyncTimestamp, syncTime,
              remoteSyncStorage: remoteSyncStorage)),
          maxConcurrent: remoteSyncStorage.maxConcurrentIndexSyncs);
      _log.info(
          'Completed shard sync for resource type: ${resourceType.debug}');
    }
  }

  /// Step A.1: Sync Index Documents for a specific resource type.
  ///
  /// For each configured index of this type:
  /// 1. Conditional GET using stored ETag
  /// 2. Handle 200/304/404 responses
  /// 3. Merge if needed
  /// 4. Upload loop with retry on 412 conflict
  ///
  /// Returns list of (indexIri, fetchPolicy) tuples for this type.
  Future<List<IndexSyncSpec>> _syncIndexDocuments(
    IriTerm resourceType,
    int lastSyncTimestamp,
    DateTime syncTime, {
    required RemoteSyncStorage remoteSyncStorage,
    required SyncEngineConfig config,
  }) async {
    /* FIXME: should we skip this or wrap remoteSyncStorage for other resource
    types than index-of-indices? in theory, the index-of-indices sync should 
    sync all indexes already, so we don't need the extra network calls here.
    And especially in shard dataset mode, we cannot fetch individual index documents
    because they are inside datasets.
    */
    _log.fine('Syncing index documents for ${resourceType.debug}');

    // Get resource config for this type
    final resourceConfig =
        config.resources.firstWhere((r) => r.typeIri == resourceType);

    // Collect FullIndex IRIs for this type
    final fullIndices =
        resourceConfig.indices.whereType<FullIndexData>().map((index) {
      final iri = _indexRdfGenerator.generateFullIndexIri(index, resourceType);
      return FullIndexSync(iri, index.rootResourceFetchPolicy);
    }).toList();

    // Collect subscribed GroupIndex IRIs for this type
    // Storage now filters by indexed type automatically
    final groupIndices = await _storage.getSubscribedGroupIndices(resourceType);

    // Convert from 3-tuple to 2-tuple (drop indexedType since we know it)
    final groupIndexTuples = groupIndices
        .map((tuple) => FullIndexSync(
            tuple.$1,
            _useShardDatasets
                // in shard dataset mode, we must use prefetch to ensure all items are present
                ? RootResourceFetchPolicy.prefetch
                : tuple.$3)) // (indexIri, fetchPolicy)
        .toList();
    final groupIndexIris =
        groupIndices.map((tuple) => tuple.$1).toSet(); // indexIri

    final configuredIndices = <IndexSyncSpec>[
      ...fullIndices,
      ...groupIndexTuples,
    ];

    // Collect configured index IRIs for deduplication
    final configuredIndexIris =
        configuredIndices.map((spec) => spec.indexIri).toSet();

    // Find foreign indices: indices with dirty/uncovered entries but not configured
    final foreignIndices = await _findForeignIndices(
      resourceType: resourceType,
      configuredIndexIris: configuredIndexIris,
    );

    final indices = <IndexSyncSpec>[
      ...configuredIndices,
      ...foreignIndices,
    ];

    _log.fine(
        'Found ${configuredIndices.length} configured indices and ${foreignIndices.length} foreign indices for ${resourceType.debug}');

    // We rely on the index of indices sync to have updated the index documents,
    // so we don't need to re-sync them here again - except for:
    // 1. The index-of-indices itself (resourceType == idx:FullIndex)
    // 2. Group indices - these are NOT in the index-of-indices, only their
    //    templates are. We need to sync each group index document separately.
    final bool isIndexOfIndices = resourceType == IdxFullIndex.classIri;

    for (final spec in indices) {
      final documentIri = spec.indexIri.getDocumentIri();

      // Sync if:
      // - This is the index-of-indices itself, OR
      // - This is a GroupIndex (detected by presence in groupIndexIris set)
      if (isIndexOfIndices || groupIndexIris.contains(spec.indexIri)) {
        await _docSync.syncDocument(
          documentIri,
          lastSyncTimestamp,
          syncTime,
          debugName: 'Index ${documentIri.debug}',
          graphSyncStorage: remoteSyncStorage,
        );
      }
    }

    return indices;
  }

  Future<List<ShardSyncSpec>> _buildShardSyncSpecs(
    IndexSyncSpec idxSpec,
  ) async {
    // Context indices were already filtered by resourceType in _reconcileMetadata
    // Extract shards from all synced indices
    switch (idxSpec) {
      case FullIndexSync():
        final result =
            await _storage.getDocument(idxSpec.indexIri.getDocumentIri());
        if (result == null) {
          // index document does not exist - this can happen for group indices
          // if the application subscribes to groups, but there are no members yet
          // and thus no index document is created
          return [];
        }
        return result
            .document // we synced it at least once already, must be present
            .getMultiValueObjects<IriTerm>(idxSpec.indexIri, IdxIndex.hasShard)
            .map((shardIri) => FullShardSync(
                shardIri: shardIri, fetchPolicy: idxSpec.fetchPolicy))
            .toList();
      case PartialIndexSync():
        return Future.value(idxSpec.shardItems.entries
            .map((entry) => PartialShardSync(
                shardIri: entry.key, resourceClockHashes: entry.value))
            .toList());
    }
  }

  // =========================================================================
  // Helper Methods
  // =========================================================================

  /// Find foreign indices that need partial sync for a given resource type.
  ///
  /// Foreign indices are those not explicitly configured/subscribed but containing
  /// items that:
  /// 1. Were modified locally (dirty entries need upload)
  /// 2. Are present in our local DB but not covered by any configured shard
  ///
  /// Returns PartialIndexSync specs for each foreign index with its shards.
  Future<List<PartialIndexSync>> _findForeignIndices({
    required IriTerm resourceType,
    required Set<IriTerm> configuredIndexIris,
  }) async {
    // Get last sync timestamp to find dirty entries
    final lastSync = await _storage.getLastRemoteSyncTimestamp(_remoteId);

    // Query for foreign index shards
    // This finds indices (not in configured set) with:
    // - Entries modified since last sync (dirty), OR
    // - Entries in shards not yet synced (uncovered)
    final foreignIndexShards = await _storage.getForeignIndexShardsToSync(
      sinceTimestamp: lastSync,
      resourceType: resourceType,
      excludeIndexIris: configuredIndexIris,
    );
    // print(
    //    'Configured indices: ${configuredIndexIris.map((e) => e.debug).join(', ')} for resource type ${resourceType.debug}');
    // print(
    //   'Foreign index shards to sync: ${foreignIndexShards.entries.map((e) => e.key.debug).join(', ')}');
    // Convert to PartialIndexSync specs
    final foreignIndices = foreignIndexShards.entries
        .map((entry) => PartialIndexSync(
              indexIri: entry.key,
              shardItems: entry.value,
            ))
        .toList();

    if (foreignIndices.isNotEmpty) {
      final totalShards = foreignIndices
          .map((i) => i.shardItems.length)
          .reduce((a, b) => a + b);
      _log.info(
          'Found ${foreignIndices.length} foreign indices with $totalShards shards to sync for ${resourceType.debug}');
    }

    return foreignIndices;
  }

  Future<void> _syncResourceType(
    IriTerm resourceType,
    int lastSyncTimestamp,
    DateTime syncTime, {
    required RemoteSyncStorage remoteSyncStorage,
    required SyncEngineConfig config,
  }) async {
    _log.info('Syncing resource type: ${resourceType.debug}');

    // Step 1: Sync Index Documents for this type
    final allIndices = await _syncIndexDocuments(
      resourceType,
      lastSyncTimestamp,
      syncTime,
      remoteSyncStorage: remoteSyncStorage,
      config: config,
    );

    // Step 2: For each index, sync its shards and documents
    await _executeInChunks(
        allIndices.map((index) => () => _syncIndex(
            resourceType, index, lastSyncTimestamp, syncTime,
            remoteSyncStorage: remoteSyncStorage)),
        maxConcurrent: remoteSyncStorage.maxConcurrentIndexSyncs);

    _log.info('Completed sync for resource type: ${resourceType.debug}');
  }

  Future<void> _syncIndex(
    IriTerm resourceType,
    IndexSyncSpec index,
    int lastSyncTimestamp,
    DateTime syncTime, {
    required RemoteSyncStorage remoteSyncStorage,
  }) async {
    _log.fine('Syncing index: ${index}');

    final allShards = await _buildShardSyncSpecs(index);

    await _executeInChunks(
        allShards.map((shard) => () => _syncShard(
            resourceType, index, shard, lastSyncTimestamp, syncTime,
            remoteSyncStorage: remoteSyncStorage)),
        maxConcurrent: remoteSyncStorage.maxConcurrentShardSyncs);

    _log.info('Completed sync for index: ${index.indexIri.debug}');
  }

  Future<void> _syncShard(
    IriTerm resourceType,
    IndexSyncSpec index,
    ShardSyncSpec shard,
    int lastSyncTimestamp,
    DateTime syncTime, {
    required RemoteSyncStorage remoteSyncStorage,
  }) async {
    final shardIri = shard.shardIri;
    final debugName = 'Shard ${shardIri.debug}';
    final bool shouldUseShardDataset = _useShardDatasets;
    _log.fine('Syncing: ${debugName}');
    await retryOnConflict(() async {
      final _ShardSyncAdapter adapter = shouldUseShardDataset
          ? FilePerShardShardSyncAdapter(
              remoteSyncStorage: remoteSyncStorage,
            )
          : FilePerResourceShardSyncAdapter(
              remoteSyncStorage: remoteSyncStorage);

      return await _shardSyncOrchestrator.syncShard(
        resourceType,
        index,
        shard,
        lastSyncTimestamp,
        syncTime,
        adapter: adapter,
        shardIri: shardIri,
        debugName: debugName,
      );
    }, debugOperationName: 'syncing ${debugName}');
  }
}

/// Execute tasks in parallel chunks with concurrency limit
Future<void> _executeInChunks<T>(
  Iterable<Future<T> Function()> tasks, {
  int maxConcurrent = 10,
}) async {
  final iterator = tasks.iterator;
  while (iterator.moveNext()) {
    final chunk = <Future<T> Function()>[iterator.current];

    // Collect up to maxConcurrent tasks
    for (var i = 1; i < maxConcurrent && iterator.moveNext(); i++) {
      chunk.add(iterator.current);
    }

    // Execute chunk in parallel
    await Future.wait(chunk.map((task) => task()), eagerError: false);
  }
}

class _DocumentSyncHelper {
  final Storage _storage;
  final RemoteId _remoteId;
  final MergeContractLoader _mergeContractLoader;
  final RemoteDocumentMerger _merger;
  final IndexManager _indexManager;
  final ShardDeterminer _shardDeterminer;
  final HlcService _hlcService;
  final LocalDocumentMerger _localDocumentMerger;
  final PhysicalTimestampFactory _physicalTimestampFactory;

  _DocumentSyncHelper({
    required Storage storage,
    required RemoteId remoteId,
    required MergeContractLoader mergeContractLoader,
    required RemoteDocumentMerger merger,
    required IndexManager indexManager,
    required ShardDeterminer shardDeterminer,
    required HlcService hlcService,
    required LocalDocumentMerger localDocumentMerger,
    required PhysicalTimestampFactory physicalTimestampFactory,
  })  : _storage = storage,
        _remoteId = remoteId,
        _mergeContractLoader = mergeContractLoader,
        _merger = merger,
        _indexManager = indexManager,
        _shardDeterminer = shardDeterminer,
        _hlcService = hlcService,
        _localDocumentMerger = localDocumentMerger,
        _physicalTimestampFactory = physicalTimestampFactory;

  /// Get local document with metadata from storage
  Future<StoredDocument?> _getLocalDocumentWithMetadata(IriTerm documentIri,
      {int? ifChangedSincePhysicalClock}) async {
    return await _storage.getDocument(
      documentIri,
      ifChangedSincePhysicalClock: ifChangedSincePhysicalClock,
    );
  }

  Future<_DownloadAndMergeResult<T>?> downloadAndMerge<T>(
    IriTerm documentIri,
    int lastSyncTimestamp, {
    String debugName = '',
    required Future<RemoteDownloadResult<T>> Function(IriTerm,
            {String? ifNoneMatch})
        downloadFunction,
    required RdfGraph Function(T) extractGraph,
    String? cachedEtagOverride,
    RemoteDownloadResult<T>? downloadResultOverride,
    StoredDocument? localDocumentOverride,
  }) async {
    // 1. Conditional GET
    final cachedETag = cachedEtagOverride ??
        await _storage.getRemoteETag(
          _remoteId,
          documentIri,
        );

    final downloadResult = downloadResultOverride ??
        await downloadFunction(
          documentIri,
          ifNoneMatch: cachedETag,
        );

    late final RdfGraph documentToUpload;
    late final MergeContract mergeContract;
    StoredDocument?
        loadedLocalDocument; // Track loaded document with metadata for optimistic locking

    // 2. Handle response cases
    if (downloadResult.notModified) {
      // Case: 304 Not Modified
      _log.fine('$debugName unchanged (304)');
      loadedLocalDocument = localDocumentOverride ??
          await _getLocalDocumentWithMetadata(documentIri,
              ifChangedSincePhysicalClock: lastSyncTimestamp);
      if (localDocumentOverride != null &&
          localDocumentOverride.metadata.ourPhysicalClock <=
              lastSyncTimestamp) {
        _log.fine('Local $debugName has no changes since last sync');
        return null;
      }
      if (loadedLocalDocument == null) {
        _log.fine('Local $debugName has no changes since last sync');
        // Return null to indicate no changes
        return null;
      }
      documentToUpload = loadedLocalDocument.document;
      mergeContract = await _mergeContractLoader.load(_mergeContractLoader
          .extractGovernanceIris(loadedLocalDocument.document, documentIri));
    } else if (downloadResult.graph != null) {
      final remoteGraph = extractGraph(downloadResult.graph!);
      // Case: 200 OK - Remote changed
      _log.fine('$debugName changed remotely');
      // Theoretically, we could skip merge if local unchanged since last sync
      // but just to be safe, always merge if remote changed and then compare
      loadedLocalDocument = localDocumentOverride ??
          await _getLocalDocumentWithMetadata(documentIri);
      final localDocument = loadedLocalDocument?.document;
      final governanceIris = _mergeContractLoader.getMergedGovernanceIris(
          [if (localDocument != null) localDocument, remoteGraph], documentIri);
      mergeContract = await _mergeContractLoader.load(governanceIris);
      // CRDT merge local + remote
      final mergeResult = await _merger.merge(
        mergeContract: mergeContract,
        documentIri: documentIri,
        localGraph: localDocument,
        remoteGraph: remoteGraph,
      );
      //_log.fine('Local graph: ${turtle.encode(localDocument ?? RdfGraph())}');
      //_log.fine('Remote graph: ${turtle.encode(remoteGraph)}');
      //_log.fine(
      //    'Merged graph for $debugName: ${turtle.encode(mergeResult.mergedGraph)}');
      final actualGovernanceIris = _mergeContractLoader.extractGovernanceIris(
          mergeResult.mergedGraph, documentIri);
      if (!ListEquality().equals(actualGovernanceIris, governanceIris)) {
        _log.severe('Governance IRIs mismatch after merge for $debugName. '
            'Expected: $governanceIris, '
            'Found: $actualGovernanceIris');
      }
      if (localDocument == mergeResult.mergedGraph) {
        _log.finest('No changes after merging $debugName');
        // Note: it would be more correct to use rdf canonicalization here,
        // but for performance reasons we just use graph equality, assuming
        // that the merger produces consistent output and that blank nodes
        // are not re-created but reused.
        return null; // No changes after merge
      }
      documentToUpload = mergeResult.mergedGraph;
    } else {
      // Case: 404 Not Found - New index
      _log.fine('$debugName not found remotely (404)');
      loadedLocalDocument = localDocumentOverride ??
          await _getLocalDocumentWithMetadata(documentIri);
      if (loadedLocalDocument == null) {
        _log.warning(
            '$debugName was found neither remotely nor locally, will skip');
        return null; // Nothing to upload
      }
      documentToUpload = loadedLocalDocument.document;
      mergeContract = await _mergeContractLoader.load(_mergeContractLoader
          .extractGovernanceIris(documentToUpload, documentIri));
    }

    return (
      mergedDocument: documentToUpload,
      originalLocalDocument: loadedLocalDocument?.document,
      originalRemoteDocument: downloadResult.graph,
      mergeContract: mergeContract,
      etag: downloadResult.etag,
      localUpdatedAt: loadedLocalDocument?.metadata.updatedAt
    );
  }

  /// Sync a single document with retry loop on 412
  Future<void> syncDocument(
    IriTerm documentIri,
    int lastSyncTimestamp,
    DateTime syncTime, {
    required GraphSyncStorage graphSyncStorage,
    String debugName = '',
  }) async {
    _log.fine('Syncing ${debugName}');

    await retryOnConflict(() async {
      try {
        final merged = await downloadAndMerge(
          documentIri,
          lastSyncTimestamp,
          debugName: debugName,
          downloadFunction: (documentIri, {ifNoneMatch}) async =>
              (await graphSyncStorage.downloadMany([
            RemoteDownloadRequest(
              documentIri: documentIri,
              ifNoneMatch: ifNoneMatch,
            ),
          ]))
                  .single,
          extractGraph: (RdfGraph graph) => graph,
        );
        if (merged == null) {
          return; // No changes, nothing to do
        }
        final (typeIri, documentToUpload, clock, missingGroupIndices) =
            await reconcileDocumentShards(
          documentIri,
          merged.mergedDocument,
          merged.mergeContract,
        );

        // Will throw [ConcurrentUpdateException] on conflict
        await applyAndStoreMergedDocument(
          uploadFunction: (documentIri, data, {ifMatch}) async =>
              (await graphSyncStorage.uploadMany([
            RemoteUploadRequest<RdfGraph>(
              documentIri: documentIri,
              document: data,
              ifMatch: ifMatch,
            ),
          ]))
                  .single,
          extractGraph: (RdfGraph graph) => graph,
          documentIri: documentIri,
          clock: clock,
          documentToUpload: documentToUpload,
          localUpdatedAt: merged.localUpdatedAt,
          missingGroupIndices: missingGroupIndices,
          syncTime: syncTime,
          typeIri: typeIri,
          etag: merged.etag,
          debugName: debugName,
        );
      } on ConcurrentUpdateException {
        // Conflict detected during upload or local save - retry entire download+merge+upload
        _log.fine('Conflict detected while syncing $debugName, retrying...');
        rethrow;
      } catch (e, st) {
        _log.warning('Error syncing $debugName', e, st);
        rethrow;
      }
    }, debugOperationName: 'syncing $debugName');
  }

  Future<_DeferredBatchCommit?> syncDocumentsBatch(
    List<_BatchSyncCandidate> candidates,
    int lastSyncTimestamp,
    DateTime syncTime, {
    required GraphSyncStorage graphSyncStorage,
    bool deferLocalCommit = false,
  }) async {
    if (candidates.isEmpty) {
      return null;
    }

    final documentIris =
        candidates.map((candidate) => candidate.documentIri).toList();

    Future<
        ({
          Map<IriTerm, StoredDocument?> localDocumentsByIri,
          Map<IriTerm, String?> cachedEtagsByIri,
        })> readPhase() async {
      final localDocumentsByIri =
          await _storage.getDocumentsByIri(documentIris);
      final cachedEtagsByIri =
          await _storage.getRemoteETags(_remoteId, documentIris);
      return (
        localDocumentsByIri: localDocumentsByIri,
        cachedEtagsByIri: cachedEtagsByIri,
      );
    }

    final ({
      Map<IriTerm, StoredDocument?> localDocumentsByIri,
      Map<IriTerm, String?> cachedEtagsByIri,
    }) readData;
    if (_storage case final TransactionalStorage txStorageRead) {
      readData = await txStorageRead.inTransaction(readPhase);
    } else {
      readData = await readPhase();
    }

    final localDocumentsByIri = readData.localDocumentsByIri;
    final cachedEtagsByIri = readData.cachedEtagsByIri;

    final downloadResults = await graphSyncStorage.downloadMany(
      documentIris
          .map((documentIri) => RemoteDownloadRequest(
                documentIri: documentIri,
                ifNoneMatch: cachedEtagsByIri[documentIri],
              ))
          .toList(growable: false),
    );

    final prepared = <({
      IriTerm documentIri,
      IriTerm typeIri,
      RdfGraph documentToUpload,
      CurrentCrdtClock clock,
      int? localUpdatedAt,
      Iterable<MissingGroupIndex> missingGroupIndices,
      String? ifMatch,
      String debugName,
    })>[];

    for (var i = 0; i < candidates.length; i++) {
      final candidate = candidates[i];
      final merged = await downloadAndMerge<RdfGraph>(
        candidate.documentIri,
        lastSyncTimestamp,
        debugName: candidate.debugName,
        downloadFunction: (documentIri, {ifNoneMatch}) =>
            graphSyncStorage.download(documentIri, ifNoneMatch: ifNoneMatch),
        extractGraph: (graph) => graph,
        cachedEtagOverride: cachedEtagsByIri[candidate.documentIri],
        downloadResultOverride: downloadResults[i],
        localDocumentOverride: localDocumentsByIri[candidate.documentIri],
      );

      if (merged == null) {
        continue;
      }

      final (typeIri, documentToUpload, clock, missingGroupIndices) =
          await reconcileDocumentShards(
        candidate.documentIri,
        merged.mergedDocument,
        merged.mergeContract,
      );

      prepared.add((
        documentIri: candidate.documentIri,
        typeIri: typeIri,
        documentToUpload: documentToUpload,
        clock: clock,
        localUpdatedAt: merged.localUpdatedAt,
        missingGroupIndices: missingGroupIndices,
        ifMatch: merged.etag,
        debugName: candidate.debugName,
      ));
    }

    if (prepared.isEmpty) {
      return null;
    }

    final uploadResults = await graphSyncStorage.uploadMany(
      prepared
          .map((entry) => RemoteUploadRequest<RdfGraph>(
                documentIri: entry.documentIri,
                document: entry.documentToUpload,
                ifMatch: entry.ifMatch,
              ))
          .toList(growable: false),
    );

    final uploadedEtags = <IriTerm, String>{};
    for (var i = 0; i < uploadResults.length; i++) {
      final uploadResult = uploadResults[i];
      final preparedEntry = prepared[i];
      switch (uploadResult) {
        case ConflictUploadResult():
          throw ConcurrentUpdateException(
              'Remote document ${preparedEntry.debugName} changed during batch upload');
        case SuccessUploadResult():
          uploadedEtags[preparedEntry.documentIri] = uploadResult.etag;
      }
    }

    final etagUpdates = <IriTerm, String>{};
    final saveRequests = <SaveDocumentRequest>[];
    final indexEntryRequests = <SaveIndexEntryRequest>[];

    for (final entry in prepared) {
      final updatedAtTimestamp =
          _physicalTimestampFactory().millisecondsSinceEpoch;
      saveRequests.add(
        SaveDocumentRequest(
          documentIri: entry.documentIri,
          typeIri: entry.typeIri,
          document: entry.documentToUpload,
          metadata: DocumentMetadata(
            ourPhysicalClock: entry.clock.physicalTime,
            updatedAt: updatedAtTimestamp,
          ),
          changes: const <PropertyChange>[],
          ifMatchUpdatedAt: entry.localUpdatedAt,
        ),
      );

      final entryWrites = await _indexManager.prepareIndexEntryWrites(
        document: entry.documentToUpload,
        documentIri: entry.documentIri,
        physicalTime: entry.clock.physicalTime,
        resourceTypeIri: entry.typeIri,
        missingGroupIndices: entry.missingGroupIndices,
        updatedAt: updatedAtTimestamp,
      );
      indexEntryRequests.addAll(entryWrites);

      final etag = uploadedEtags[entry.documentIri];
      if (etag != null) {
        etagUpdates[entry.documentIri] = etag;
      }
    }

    final deferred = (
      saveRequests: saveRequests,
      indexEntryRequests: indexEntryRequests,
      etagUpdates: etagUpdates,
    );

    if (deferLocalCommit) {
      return deferred;
    }

    await commitDeferredBatch(deferred);
    return null;
  }

  Future<void> commitDeferredBatch(_DeferredBatchCommit deferred) async {
    final commit = () async {
      await _storage.saveDocuments(deferred.saveRequests);
      if (deferred.indexEntryRequests.isNotEmpty) {
        await _storage.saveIndexEntries(deferred.indexEntryRequests);
      }
      if (deferred.etagUpdates.isNotEmpty) {
        await _storage.setRemoteETags(_remoteId, deferred.etagUpdates);
      }
    };

    if (_storage case final TransactionalStorage txStorage) {
      await txStorage.inTransaction(commit);
    } else {
      await commit();
    }
  }

  Future<
      (
        IriTerm typeIri,
        RdfGraph document,
        CurrentCrdtClock clock,
        List<MissingGroupIndex> missingGroupIndices
      )> reconcileDocumentShards(
    IriTerm documentIri,
    RdfGraph mergedDocument,
    MergeContract mergeContract,
  ) async {
    final resourceIri = mergedDocument.expectSingleObject<IriTerm>(
        documentIri, SyncManagedDocument.foafPrimaryTopic)!;
    final typeIri =
        mergedDocument.expectSingleObject<IriTerm>(resourceIri, Rdf.type)!;
    final shards = await _shardDeterminer.determineShards(
      typeIri,
      resourceIri,
      // app data is requested here, but since this is an rdf graph
      // we can simply pass in the full document which contains the app data (amongst the framework data)
      mergedDocument,
      // Important: we really have to be able to compute all shards here, better be strict and fail early.
      mode: ShardDeterminationMode.strict,
    );
    final clock = _hlcService.getCurrentClock(mergedDocument, documentIri);

    // Replace shards in the document and generate metadata for the change
    final document = await _localDocumentMerger.replaceInDocument(
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
        ]);
    return (typeIri, document, clock, shards.missingGroupIndices);
  }

  ///
  /// Throws [ConcurrentUpdateException] on conflict
  Future<void> applyAndStoreMergedDocument<T>({
    required Future<RemoteUploadResult>
            Function(IriTerm documentIri, T document, {String? ifMatch})
        uploadFunction,
    required RdfGraph Function(T data) extractGraph,
    required IriTerm typeIri,
    required IriTerm documentIri,
    required T documentToUpload,
    required String? etag,
    required CurrentCrdtClock clock,
    required int? localUpdatedAt,
    required Iterable<MissingGroupIndex> missingGroupIndices,
    required DateTime syncTime,
    String debugName = '',
  }) async {
    final uploadResult = await uploadFunction(
      documentIri,
      documentToUpload,
      ifMatch: etag,
    );

    final String mergedETag = switch (uploadResult) {
      ConflictUploadResult() => throw ConcurrentUpdateException(
          'Remote document $debugName changed during upload'),
      SuccessUploadResult() => uploadResult.etag,
    };

    final int physicalTime = clock.physicalTime;
    final graph = extractGraph(documentToUpload);

    // Optimistic locking for local save: prevent lost updates from concurrent local changes
    // Use updatedAt as version marker - it's updated on EVERY save (local + remote),
    // unlike ourPhysicalClock which only changes when WE modify the document.
    // This ensures we catch conflicts even if the concurrent change was a remote merge.
    final expectedUpdatedAt = localUpdatedAt;
    final updatedAtTimestamp =
        _physicalTimestampFactory().millisecondsSinceEpoch;
    // save locally with optimistic lock - retry if conflict detected
    try {
      await _storage.saveDocument(
        documentIri,
        typeIri,
        graph,
        DocumentMetadata(
            ourPhysicalClock: physicalTime, updatedAt: updatedAtTimestamp),
        // no property changes - this is a concept for user-triggered edits
        // that is supposed to help us with crdt merges, so we leave it empty here
        const <PropertyChange>[],
        ifMatchUpdatedAt: expectedUpdatedAt,
      );
    } on ConcurrentUpdateException {
      // Local conflict detected! Document was modified locally since we read it.
      // This can happen if user edits document while sync is running - rethrow it
      rethrow;
    }

    // Now that the locally stored document is based on the remote version,
    // we need to update the stored ETag for future conditional requests.
    // Success - cache new ETag
    await _storage.setRemoteETag(
      _remoteId,
      documentIri,
      mergedETag,
    );

    // TODO: how do we assure that the updateIndices call is also
    // executed if sync was aborted shortly before here (e.g. app crash)?
    await _indexManager.updateIndices(
      document: graph,
      documentIri: documentIri,
      physicalTime: physicalTime,
      resourceTypeIri: typeIri,
      missingGroupIndices: missingGroupIndices,
      updatedAt: updatedAtTimestamp,
    );
    // Success
  }
}

/// Adapter for file-per-resource sync mode.
///
/// In this mode:
/// - Each resource document is synced individually via [RemoteSyncStorage]
/// - The shard document itself is just a metadata container listing entries
/// - No dataset/named graphs are used for resource documents
/// - Full concurrency is possible since each document is independent
/// - GraphSyncStorage delegates directly to the remote backend
///
/// This is the traditional/default mode suitable for most backends.
class FilePerResourceShardSyncAdapter
    implements _ShardSyncAdapter<RdfGraph, RemoteSyncStorage> {
  final RemoteSyncStorage _remoteSyncStorage;

  FilePerResourceShardSyncAdapter({
    required RemoteSyncStorage remoteSyncStorage,
  }) : _remoteSyncStorage = remoteSyncStorage;

  @override
  Future<RemoteDownloadResult<RdfGraph>> downloadShard(IriTerm documentIri,
          {String? ifNoneMatch}) async =>
      (await _remoteSyncStorage.downloadMany([
        RemoteDownloadRequest(
          documentIri: documentIri,
          ifNoneMatch: ifNoneMatch,
        ),
      ]))
          .single;

  @override
  Future<RemoteUploadResult> uploadShard(IriTerm documentIri, RdfGraph document,
          {String? ifMatch}) async =>
      (await _remoteSyncStorage.uploadMany([
        RemoteUploadRequest<RdfGraph>(
          documentIri: documentIri,
          document: document,
          ifMatch: ifMatch,
        ),
      ]))
          .single;

  @override
  RdfGraph extractGraph(RdfGraph graph) => graph;

  @override
  int get maxConcurrentDocumentSyncs =>
      _remoteSyncStorage.maxConcurrentDocumentSyncs;

  @override
  RemoteSyncStorage getGraphSyncStorage(RdfGraph? data) => _remoteSyncStorage;

  /// In file-per-resource mode, no finalization is needed.
  ///
  /// The [graphSyncStorage] parameter is unused since resource documents
  /// are synced directly to the remote backend, not stored in a dataset.
  @override
  RdfGraph finalizeDocumentToUpload(RdfGraph documentToUpload,
          {required RemoteSyncStorage graphSyncStorage}) =>
      documentToUpload;
}

/// Adapter for file-per-shard (dataset) sync mode.
///
/// In this mode:
/// - The shard document is an [RdfDataset] containing all resource documents as named graphs
/// - Resource documents are synced by modifying the dataset's named graphs in-memory
/// - The entire dataset (shard + all resources) is uploaded as one unit at the end
/// - Concurrency is limited to 1 since all documents share the same in-memory dataset
/// - [DatasetBasedGraphSyncStorage] provides in-memory read/write for resource documents
///
/// This mode is more efficient for backends supporting RDF datasets (e.g., TriG format)
/// as it reduces the number of HTTP requests from O(n) to O(1) per shard.
///
/// **Dataset Structure:**
/// ```
/// Default Graph: Shard metadata (idx:Shard with idx:containsEntry links)
/// Named Graph <resource1-doc-iri>: Resource 1 document
/// Named Graph <resource2-doc-iri>: Resource 2 document
/// ...
/// ```
class FilePerShardShardSyncAdapter
    implements _ShardSyncAdapter<RdfDataset, DatasetBasedGraphSyncStorage> {
  final RemoteSyncStorage _remoteSyncStorage;

  FilePerShardShardSyncAdapter({
    required RemoteSyncStorage remoteSyncStorage,
  }) : _remoteSyncStorage = remoteSyncStorage;

  @override
  Future<RemoteDownloadResult<RdfDataset>> downloadShard(IriTerm documentIri,
          {String? ifNoneMatch}) async =>
      (await _remoteSyncStorage.downloadManyDatasets([
        RemoteDownloadRequest(
          documentIri: documentIri,
          ifNoneMatch: ifNoneMatch,
        ),
      ]))
          .single;

  @override
  Future<RemoteUploadResult> uploadShard(
          IriTerm documentIri, RdfDataset document,
          {String? ifMatch}) async =>
      (await _remoteSyncStorage.uploadManyDatasets([
        RemoteUploadRequest<RdfDataset>(
          documentIri: documentIri,
          document: document,
          ifMatch: ifMatch,
        ),
      ]))
          .single;

  @override
  RdfGraph extractGraph(RdfDataset data) => data.defaultGraph;

  /// In dataset mode, all resource documents are stored in the same in-memory
  /// [DatasetBasedGraphSyncStorage]. Concurrent modifications would require
  /// synchronization, so we process documents sequentially.
  ///
  /// This is acceptable because:
  /// 1. Document processing is CPU-bound (CRDT merge), not I/O-bound
  /// 2. We gain efficiency by uploading the entire dataset once
  /// 3. Shards are processed concurrently, so parallelism exists at that level
  @override
  int get maxConcurrentDocumentSyncs => 1;

  @override
  DatasetBasedGraphSyncStorage getGraphSyncStorage(RdfDataset? data) =>
      DatasetBasedGraphSyncStorage(data?.namedGraphs ?? []);

  /// Finalize the shard dataset for upload.
  ///
  /// Combines:
  /// 1. [documentToUpload]: The shard metadata graph (default graph)
  /// 2. [graphSyncStorage.namedGraphs]: All resource documents synced during this cycle
  ///
  /// The resulting [RdfDataset] contains the complete shard with all its resources.
  ///
  /// Validates dataset consistency: All resources referenced in shard entries
  /// must be present as named graphs. Throws [StateError] if validation fails.
  @override
  RdfDataset finalizeDocumentToUpload(RdfGraph documentToUpload,
      {required DatasetBasedGraphSyncStorage graphSyncStorage}) {
    // Extract shard IRI from document (there should be exactly one idx:Shard subject)
    final shardIri = documentToUpload.getIdentifier(IdxShard.classIri);

    // Validate: All resources referenced in shard entries must be present as named graphs
    final entryResourceDocumentIris = documentToUpload
        .getMultiValueObjects<IriTerm>(shardIri, IdxShard.containsEntry)
        .map((entryIri) => documentToUpload.expectSingleObject<IriTerm>(
            entryIri, IdxShardEntry.resource))
        .whereType<IriTerm>()
        .map((resourceIri) => resourceIri.getDocumentIri())
        .toSet();

    final namedGraphIris = graphSyncStorage.namedGraphs.keys.toSet();

    final missingDocuments =
        entryResourceDocumentIris.difference(namedGraphIris);
    if (missingDocuments.isNotEmpty) {
      throw StateError('Dataset validation failed for ${shardIri.debug}: '
          'Shard entries reference ${missingDocuments.length} resource(s) '
          'not present in dataset named graphs: '
          '${missingDocuments.map((i) => i.debug).take(5).join(", ")}'
          '${missingDocuments.length > 5 ? "..." : ""}');
    }

    return RdfDataset(
      defaultGraph: documentToUpload,
      namedGraphs: graphSyncStorage.namedGraphs,
    );
  }
}

/// Adapter interface for different shard sync modes.
///
/// This interface abstracts the differences between:
/// - **File-per-resource mode**: Each document synced individually as RdfGraph
/// - **File-per-shard mode**: All documents synced together as RdfDataset
///
/// Type parameters:
/// - [T]: The data type used for shard download/upload (RdfGraph or RdfDataset)
/// - [G]: The GraphSyncStorage implementation for resource document sync
abstract interface class _ShardSyncAdapter<T, G extends GraphSyncStorage> {
  /// Download the shard document from remote storage.
  ///
  /// Returns the shard in the adapter-specific format:
  /// - File-per-resource: RdfGraph with shard metadata only
  /// - File-per-shard: RdfDataset with shard metadata + all resource documents
  Future<RemoteDownloadResult<T>> downloadShard(IriTerm documentIri,
      {String? ifNoneMatch});

  /// Upload the finalized shard document to remote storage.
  ///
  /// The [document] parameter type depends on the mode:
  /// - File-per-resource: RdfGraph with shard metadata
  /// - File-per-shard: RdfDataset with shard metadata + all synced resources
  Future<RemoteUploadResult> uploadShard(IriTerm documentIri, T document,
      {String? ifMatch});

  /// Extract the shard metadata graph from the downloaded data.
  ///
  /// - File-per-resource: Returns the graph as-is
  /// - File-per-shard: Returns the default graph from the dataset
  RdfGraph extractGraph(T data);

  /// Create a GraphSyncStorage for syncing resource documents within the shard.
  ///
  /// - File-per-resource: Returns the remote storage (documents synced individually)
  /// - File-per-shard: Returns in-memory storage backed by dataset's named graphs
  ///
  /// The [data] parameter is the downloaded shard data, or null if the shard
  /// doesn't exist remotely yet (404 case).
  G getGraphSyncStorage(T? data);

  /// Finalize the shard document before upload.
  ///
  /// - File-per-resource: Returns the graph unchanged (resources already uploaded)
  /// - File-per-shard: Assembles dataset from graph + synced resource documents
  ///
  /// The [graphSyncStorage] contains any resource documents modified during sync.
  T finalizeDocumentToUpload(RdfGraph documentToUpload,
      {required G graphSyncStorage});

  /// Maximum number of resource documents to sync concurrently within a shard.
  ///
  /// - File-per-resource: High concurrency OK (independent HTTP requests)
  /// - File-per-shard: Must be 1 (shared in-memory dataset)
  int get maxConcurrentDocumentSyncs;
}

class _ShardSyncOrchestrator {
  final Storage _storage;
  final HlcService _hlcService;
  final ShardDocumentGenerator _shardDocumentGenerator;
  final LocalDocumentMerger _localDocumentMerger;
  final _DocumentSyncHelper _docSync;

  _ShardSyncOrchestrator({
    required Storage storage,
    required HlcService hlcService,
    required ShardDocumentGenerator shardDocumentGenerator,
    required LocalDocumentMerger localDocumentMerger,
    required _DocumentSyncHelper documentSyncHelper,
  })  : _storage = storage,
        _hlcService = hlcService,
        _shardDocumentGenerator = shardDocumentGenerator,
        _localDocumentMerger = localDocumentMerger,
        _docSync = documentSyncHelper;

  Future<void> syncShard<T, G extends GraphSyncStorage>(
    IriTerm resourceType,
    IndexSyncSpec index,
    ShardSyncSpec shard,
    int lastSyncTimestamp,
    DateTime syncTime, {
    required _ShardSyncAdapter<T, G> adapter,
    required IriTerm shardIri,
    required String debugName,
  }) async {
    // Build Document Sync Queue for this type
    final shardDocumentIri = shardIri.getDocumentIri();
    final merged = await _docSync.downloadAndMerge<T>(
      shardDocumentIri,
      lastSyncTimestamp,
      debugName: debugName,
      downloadFunction: adapter.downloadShard,
      extractGraph: adapter.extractGraph,
    );
    if (merged == null) {
      // We do ensure the shards are up to date in Phase 0 of sync function, so
      // we can assume that if there are no changes here, the local and remote shards are
      // already up to date.
      // No changes, nothing to do
      return;
    }
    final originalRemoteShard = merged.originalRemoteDocument == null
        ? null
        : adapter.extractGraph(merged.originalRemoteDocument!);
    final graphSyncStorage =
        adapter.getGraphSyncStorage(merged.originalRemoteDocument);
    // FIXME: how and when do we make sure that all items of the shard are present locally?
    final documentQueue = await _buildDocumentQueue(
      shard,
      originalRemoteShard,
    );
    //_log.fine(
    //    'Document queue for ${shardIri.debug}: ${documentQueue.map((e) => e.resourceIri.debug).join(', ')}');
    final syncCandidates = _createSyncCandidates(
      documentQueue,
      shard,
      debugName,
    );

    final deferredLocalCommit = await _docSync.syncDocumentsBatch(
      syncCandidates,
      lastSyncTimestamp,
      syncTime,
      graphSyncStorage: graphSyncStorage,
      deferLocalCommit: adapter is FilePerShardShardSyncAdapter,
    );

    // Phase B: Document & Shard Finalization for this type
    // 1. Determine final_entry_set from index items table
    //
    // For full shard sync with Prefetch: Use all entries from index items table
    // For other cases: Only use entries for resources in documentQueue
    // (resources that exist either locally or remotely)
    final Set<IriTerm>? limitToResources = switch (shard) {
      FullShardSync(fetchPolicy: Prefetch()) => null, // All entries
      FullShardSync(fetchPolicy: OnRequest() || PrefetchFiltered()) =>
        documentQueue.map((e) => e.resourceIri).toSet(),
      PartialShardSync() => documentQueue.map((e) => e.resourceIri).toSet(),
    };

    final finalEntrySet = await _getFinalEntrySet(
      shardIri,
      limitToResourceIris: limitToResources,
      pendingIndexEntryWrites:
          deferredLocalCommit?.indexEntryRequests ?? const [],
    );
    //print('Final entry set for shard ${shardIri.debug}: '
    //    '${finalEntrySet.map((e) => e.resourceIri.debug).toList()}\n limitToResources: ${limitToResources?.map((e) => e.debug).toList()}');

    // 2. Generate shard nodes from final entry set
    //
    // For partial sync, we need to merge these with existing remote entries
    // rather than replacing everything
    final newShardNodes = _shardDocumentGenerator.generateShardNodes(
        shardDocumentIri: shardDocumentIri,
        shardResourceIri: shardIri,
        entries: finalEntrySet);

    final RdfGraph updatedShardDocument;
    final entriesToKeep = _computeEntriesToKeep(
        limitToResources, merged.mergedDocument, shardIri);

    // Build document with kept entries but without the other old ones
    final withoutEntries = merged.mergedDocument.subgraph(
      shardDocumentIri,
      filter: (triple, depth) {
        if (triple.predicate == IdxShard.containsEntry &&
            (entriesToKeep == null || !entriesToKeep.contains(triple.object))) {
          return TraversalDecision.skip;
        }
        return TraversalDecision.include;
      },
    );

    // Add new/current entries
    updatedShardDocument = withoutEntries.withNodes(
        shardIri, IdxShard.containsEntry, newShardNodes);

    // Determine if we need to increment the clock for this shard.
    // Shard documents contain derived state from index items, but they participate
    // in CRDT synchronization. We increment our clock when we have local changes
    // to reflect in the shard - i.e., when any of our local index entries are
    // newer than the merged shard's current clock.
    final ourCurrentShardClock =
        _hlcService.getCurrentClock(merged.mergedDocument, shardDocumentIri);

    // Check if any of our final entry set items have a higher physical clock
    // than our current clock entry in the merged shard document.
    // This indicates we have local changes that need to be reflected.
    final bool hasLocalChanges = finalEntrySet.any(
        (entry) => entry.ourPhysicalClock > ourCurrentShardClock.physicalTime);

    final clock = hasLocalChanges
        ? _hlcService.createOrIncrementClock(
            merged.mergedDocument, shardDocumentIri)
        : ourCurrentShardClock;

// FIXME: is this correct?
    final (oldBlankNodes: _, newBlankNodes: _, metadata: metadata) =
        _localDocumentMerger.generateMetadata(
      shardDocumentIri,
      updatedShardDocument,
      merged.mergedDocument,
      merged.mergedDocument,
      merged.mergeContract,
      clock,
      appDataTypeIri: IdxShard.classIri,
      // optimization: shard documents should not have blank nodes
      computeCanonicalBlankNodes: false,
    );
    final finalShardDocument = _applyMetadataToDocument(
        updatedShardDocument, metadata, shardDocumentIri);

    final (_, documentToUpload, clock2, missingGroupIndices) =
        await _docSync.reconcileDocumentShards(
      shardDocumentIri,
      finalShardDocument,
      merged.mergeContract,
    );
    final finalDocumentToUpload = adapter.finalizeDocumentToUpload(
        documentToUpload,
        graphSyncStorage: graphSyncStorage);
    // 3. Upload with conditional PUT - this might throw ConcurrentUpdateException
    await _docSync.applyAndStoreMergedDocument(
      uploadFunction: adapter.uploadShard,
      extractGraph: adapter.extractGraph,
      documentIri: shardDocumentIri,
      clock: clock2,
      documentToUpload: finalDocumentToUpload,
      localUpdatedAt: merged.localUpdatedAt,
      missingGroupIndices: missingGroupIndices,
      syncTime: syncTime,
      typeIri: IdxShard.classIri,
      etag: merged.etag,
      debugName: debugName,
    );

    // In shard-dataset mode we stage local resource/index updates and persist
    // them only after the shard upload succeeded (remote-first semantics).
    if (deferredLocalCommit != null) {
      await _docSync.commitDeferredBatch(deferredLocalCommit);
    }
  }

  /// Populate document queue by comparing local and remote shard entries
  ///
  /// Builds queue entries containing both local and remote clock hashes for each resource.
  /// This enables:
  /// 1. Determining which documents need sync (different clock hashes)
  /// 2. Determining which resources should appear in shard (all from local or remote)
  /// 3. Detecting deletions (present remotely but not locally, or vice versa)
  Future<Set<_DocumentQueueEntry>> _buildDocumentQueue(
    ShardSyncSpec shard,
    RdfGraph? originalRemoteShard,
  ) async {
    //_log.fine('Building document queue for shard $shard');
    // For PartialShardSync, we already have the local clockHashes from the query
    // Just need to load remote entries
    if (shard is PartialShardSync) {
      Map<IriTerm, String> remoteEntries =
          _extractResourceClockHashes(originalRemoteShard, shard.shardIri)
              .map((key, value) => MapEntry(key, value.$1));
      //_log.fine('PartialShardSync Remote entries: $remoteEntries');
      // Build queue entries for resources in PartialShardSync
      return shard.resourceClockHashes.entries.map((entry) {
        return _DocumentQueueEntry(
          resourceIri: entry.key,
          localClockHash: entry.value,
          remoteClockHash: remoteEntries[entry.key],
        );
      }).toSet();
    }

    // FullShardSync: Load both local and remote entries from database/document
    final fullShard = shard as FullShardSync;
    final filter = fullShard.fetchPolicy is PrefetchFiltered
        ? (fullShard.fetchPolicy as PrefetchFiltered)
        : null;
    final shardIri = shard.shardIri;

    // Parse local entries from index items table
    final localEntries = <IriTerm,
        (
      String clockHash,
      Set<RdfObject>? filterValues
    )>{}; // resourceIri -> (clockHash, filterValues)
    final localIndexEntries =
        await _storage.getActiveIndexEntriesForShard(shardIri);
    for (final entry in localIndexEntries) {
      final Set<RdfObject>? filterValues;
      if (filter != null && entry.headerProperties != null) {
        final graph = turtle.decode(entry.headerProperties!);
        filterValues = graph.getMultiValueObjects(
            entry.resourceIri, filter.filterPredicate);
      } else {
        filterValues = null;
      }
      localEntries[entry.resourceIri] = (entry.clockHash, filterValues);
    }

    // Parse remote entries from original remote shard document
    final remoteEntries = _extractResourceClockHashes(
        originalRemoteShard, shardIri,
        filterPredicate: filter?.filterPredicate);
    //_log.fine('Remote entries: ${remoteEntries.keys.map((k) => k.debug)}');
    //_log.fine('Local entries: ${localEntries.keys.map((k) => k.debug)}');
    // Build queue entries for all resources present locally or remotely
    return <IriTerm>{
      ...localEntries.keys,
      ...remoteEntries.keys,
    }.map((resourceIri) {
      final localData = localEntries[resourceIri];
      final remoteData = remoteEntries[resourceIri];

      return _DocumentQueueEntry(
        resourceIri: resourceIri,
        localClockHash: localData?.$1,
        remoteClockHash: remoteData?.$1,
        localFilterValues: localData?.$2,
        remoteFilterValues: remoteData?.$2,
      );
    }).toSet();
  }

  Map<IriTerm, (String hash, Set<RdfObject>? filterValues)>
      _extractResourceClockHashes(
          RdfGraph? originalRemoteShard, IriTerm shardIri,
          {IriTerm? filterPredicate}) {
    final remoteEntries = <IriTerm, (String, Set<RdfObject>?)>{};

    if (originalRemoteShard != null) {
      for (final entryIri in originalRemoteShard
          .getMultiValueObjectList<IriTerm>(shardIri, IdxShard.containsEntry)) {
        //_log.fine('Processing remote entry ${entryIri.debug}');
        final resourceIri = originalRemoteShard.expectSingleObject<IriTerm>(
            entryIri, IdxShardEntry.resource);
        final clockHash = originalRemoteShard.expectSingleObject<LiteralTerm>(
            entryIri, IdxShardEntry.crdtClockHash);
        if (resourceIri != null && clockHash != null) {
          Set<RdfObject>? filterValues = filterPredicate == null
              ? null
              : originalRemoteShard.getMultiValueObjects<RdfObject>(
                  entryIri, filterPredicate);
          remoteEntries[resourceIri] = (clockHash.value, filterValues);
        }
      }
    }
    return remoteEntries;
  }

  List<_BatchSyncCandidate> _createSyncCandidates(
    Set<_DocumentQueueEntry> documentQueue,
    ShardSyncSpec shard,
    String debugName,
  ) {
    return documentQueue
        .map((queueEntry) {
          // Determine if this document should be synced:
          // 1. Local exists, remote doesn't (upload new)
          // 2. Both exist with different clockHashes (merge & sync)
          // 3. Remote exists, local doesn't + Prefetch policy (download)
          // 4. Remote exists, local doesn't + PrefetchFiltered with matching filter (download)

          final needsUpload =
              queueEntry.existsLocally && !queueEntry.existsRemotely;
          final needsMerge = queueEntry.existsLocally &&
              queueEntry.existsRemotely &&
              queueEntry.needsSync;

          final bool needsDownload;
          if (!queueEntry.existsLocally &&
              queueEntry.existsRemotely &&
              shard is FullShardSync) {
            final policy = shard.fetchPolicy;
            needsDownload = policy is Prefetch ||
                (policy is PrefetchFiltered &&
                    _matchesFilter(queueEntry, policy));
          } else {
            needsDownload = false;
          }

          final shouldSync = needsUpload || needsMerge || needsDownload;
          return (
            shouldSync: shouldSync,
            documentIri: queueEntry.resourceIri.getDocumentIri(),
          );
        })
        .where((params) => params.shouldSync)
        .map((params) => (
              documentIri: params.documentIri,
              debugName:
                  'Document ${params.documentIri.debug} (as part of ${debugName})',
            ))
        .toList(growable: false);
  }

  Set<IriTerm>? _computeEntriesToKeep(
      Set<IriTerm>? limitToResources, RdfGraph document, IriTerm shardIri) {
    if (limitToResources != null) {
      final Set<IriTerm> entriesToKeep = {};
      // Partial sync: Keep remote entries for resources not in our sync set
      // Only update/remove entries for resources we explicitly synced

      // Extract existing entries from merged document, keeping only those
      // not in our synced set
      final existingEntries = document.getMultiValueObjects<IriTerm>(
          shardIri, IdxShard.containsEntry);

      for (final entryIri in existingEntries) {
        final resourceIri = document.expectSingleObject<IriTerm>(
            entryIri, IdxShardEntry.resource);
        if (resourceIri != null && !limitToResources.contains(resourceIri)) {
          // Keep this remote entry - it's not one we synced
          entriesToKeep.add(entryIri);
        }
      }
      return entriesToKeep;
    }
    return null;
  }

  RdfGraph _applyMetadataToDocument(RdfGraph document,
      CrdtMetadataResult metadata, IriTerm shardDocumentIri) {
    if (metadata.triplesToRemove.isEmpty && metadata.statements.isEmpty) {
      return document;
    }
    final finalShardDocumentTriples = document.triples.toSet();
    finalShardDocumentTriples.removeAll(metadata.triplesToRemove);
    finalShardDocumentTriples.addNodes(shardDocumentIri,
        SyncManagedDocument.hasStatement, metadata.statements);
    final finalShardDocument = RdfGraph.fromTriples(finalShardDocumentTriples);
    return finalShardDocument;
  }

  /// Get final entry set for a shard from index items table
  Future<Set<IndexEntryWithIri>> _getFinalEntrySet(IriTerm shardIri,
      {Set<IriTerm>? limitToResourceIris,
      Iterable<SaveIndexEntryRequest> pendingIndexEntryWrites =
          const <SaveIndexEntryRequest>[]}) async {
    final activeEntries =
        await _storage.getActiveIndexEntriesForShard(shardIri);

    final entriesByResource = <IriTerm, IndexEntryWithIri>{
      for (final entry in activeEntries) entry.resourceIri: entry,
    };

    for (final write in pendingIndexEntryWrites) {
      if (write.shardIri != shardIri) {
        continue;
      }
      if (write.isDeleted) {
        entriesByResource.remove(write.resourceIri);
        continue;
      }

      entriesByResource[write.resourceIri] = IndexEntryWithIri(
        resourceIri: write.resourceIri,
        clockHash: write.clockHash,
        headerProperties: write.headerProperties,
        updatedAt: write.updatedAt,
        ourPhysicalClock: write.ourPhysicalClock,
        isDeleted: false,
      );
    }

    final entries = entriesByResource.values;

    // For partial shard sync, filter to only the specified resources
    if (limitToResourceIris != null) {
      return entries
          .where((entry) => limitToResourceIris.contains(entry.resourceIri))
          .toSet();
    }

    return entries.toSet();
  }

  /// Check if a queue entry matches a PrefetchFiltered policy
  bool _matchesFilter(_DocumentQueueEntry entry, PrefetchFiltered filter) {
    // Check remote filter values (for remote-only items)
    if (entry.remoteFilterValues != null) {
      return entry.remoteFilterValues!
          .any((value) => filter.acceptedObjectValues.contains(value));
    }
    // Check local filter values (for items present locally)
    if (entry.localFilterValues != null) {
      return entry.localFilterValues!
          .any((value) => filter.acceptedObjectValues.contains(value));
    }
    // No filter values available - don't filter
    return true;
  }
}
