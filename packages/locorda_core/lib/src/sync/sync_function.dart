import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_core/src/index/index_config_base.dart';
import 'package:locorda_core/src/standard_sync_engine.dart';
import 'package:locorda_core/src/storage/sync_timestamp_storage.dart';
import 'package:locorda_core/src/sync/remote_sync_orchestrator.dart';
import 'package:locorda_core/src/sync/shard_document_generator.dart';
import 'package:logging/logging.dart';

final _log = Logger('SyncFunction');
typedef OrchestratorFactory = RemoteSyncOrchestrator Function(
  RemoteSyncStorage syncStorage,
  RemoteId remoteId, {
  required bool useShardDatasets,
});

/// Synchronization function orchestrating complete sync cycle.
///
/// The sync function is triggered periodically or manually and performs
/// a complete synchronization cycle following the revised algorithm from
/// "Synchronization Algorithm Sketch.md":
///
/// **Phase 0: Sync Preparation**
/// - Materialize current_local_shard_state via shard document generation
/// - Verify index items table consistency
/// - (Reuses _ensureShardDocumentsAreUpToDate with DB persistence)
///
/// **Phase A: Metadata Reconciliation & Queue Building**
/// 1. Sync Index Documents (conditional GET + CRDT merge + upload loop)
/// 2. Build Document Sync Queue (compare local/remote shards, create merged_shell)
///
/// **Phase B: Document & Shard Finalization**
/// 1. Process Document Sync Queue (download + merge + upload each document)
/// 2. Finalize Shards (transactional upload with retry on 412)
///
/// All remote operations use conditional requests (ETag) to minimize bandwidth
/// and ensure correct conflict resolution through 412 retry loops.
class SyncFunction {
  final ShardDocumentGenerator _shardDocumentGenerator;
  final Storage _storage;
  final List<Backend> _backends;
  final ConfigService _configService;
  final OrchestratorFactory _remoteSyncOrchestratorFactory;

  SyncFunction({
    required List<Backend> backends,
    required Storage storage,
    required ConfigService configService,
    required OrchestratorFactory remoteSyncOrchestratorFactory,
    required ShardDocumentGenerator shardDocumentGenerator,
  })  : _backends = backends,
        _storage = storage,
        _configService = configService,
        _shardDocumentGenerator = shardDocumentGenerator,
        _remoteSyncOrchestratorFactory = remoteSyncOrchestratorFactory;

  Future<void> call(DateTime syncTime) async {
    // Phase 0: Sync Preparation (materialize local shard state)
    await _prepareSync(syncTime);

    // Phase A+B: Remote Synchronization (metadata + documents + shards)
    await _syncRemote(syncTime);
  }

  /// Validate that configuration and data support the given backend's dataset mode.
  ///
  /// When backend uses `useShardDatasets = true`, we must ensure:
  /// 1. **Config constraint**: All ItemFetchPolicy must be Prefetch()
  ///    - OnRequest/PrefetchFiltered lazy loading is incompatible with dataset shards
  ///    - Cannot fetch individual resources from a dataset file
  /// 2. **Data constraint**: No missing documents for index entries
  ///    - All resources referenced in index must exist in storage
  ///    - Dataset upload would fail with incomplete data
  ///
  /// Throws [StateError] if constraints are violated.
  Future<void> _validateDatasetCompatibilityForBackend(
      RemoteSyncStorage backend, SyncEngineConfig config) async {
    _log.fine(
        'Validating dataset compatibility for backend using shard datasets');

    // FIXME: what about the group index fetch policies?

    // 1. Validate config: Check that all fetch policies are Prefetch()
    final nonPrefetchResources = config.resources.where((resource) {
      return resource.indices.whereType<FullIndexData>().any((index) {
        final policy = index.itemFetchPolicy;
        return policy is! Prefetch;
      });
    }).toList();

    if (nonPrefetchResources.isNotEmpty) {
      final resourceNames =
          nonPrefetchResources.map((r) => r.typeIri.value).join(', ');
      throw StateError(
          'Cannot use shard datasets with non-Prefetch ItemFetchPolicy. '
          'Lazy loading (OnRequest/PrefetchFiltered) is incompatible with dataset shards '
          'because individual resources cannot be fetched from a dataset file. '
          'Resources with non-Prefetch policies: $resourceNames. '
          'Please change all ItemFetchPolicy to Prefetch() for dataset shard backends.');
    }

    // 2. Validate data: Check for missing documents
    // TODO: apparently, checking for missing documents at least
    // does not work with index documents - we are creating index
    // and shard documents on the fly during sync preparation.
    // Maybe we should still do this check for other types?
    /*
    final missingDocuments =
        await _storage.getMissingDocumentsForIndexEntries();
    if (missingDocuments.isNotEmpty) {
      final missingCount = missingDocuments.length;
      final samples =
          missingDocuments.take(5).map((iri) => iri.debug).join(', ');
      final more = missingDocuments.length > 5
          ? ' and ${missingDocuments.length - 5} more'
          : '';
      throw StateError('Cannot use shard datasets with incomplete storage. '
          'Found $missingCount index entries without corresponding documents. '
          'Dataset shards require all referenced resources to be present locally. '
          'Missing documents: $samples$more. '
          'Please sync with a non-dataset backend first to fetch all resources, '
          'or manually ensure all documents are present.');
    }
    */

    _log.fine('Dataset compatibility validation passed');
  }

  /// Phase 0: Sync Preparation
  ///
  /// Materializes current_local_shard_state by generating shard documents
  /// from local index items table. This provides the baseline for Phase A
  /// shard comparison.
  ///
  /// NOTE: Specification assumes in-memory result, but we use DB-persisted
  /// shard documents as permitted optimization (same logical state).
  Future<void> _prepareSync(DateTime syncTime) async {
    _log.info('Phase 0: Sync Preparation - materializing local shard state');

    // Get timestamp of last shard sync
    final lastSyncTimestamp = await _storage.getLastShardSyncTimestamp();
    _log.fine('Last shard sync timestamp: $lastSyncTimestamp');

    try {
      // Generate shard documents for all shards with changes since last sync
      // This materializes current_local_shard_state in the DB
      await _shardDocumentGenerator(syncTime, lastSyncTimestamp);

      // Update last shard sync timestamp
      final now = syncTime.millisecondsSinceEpoch;
      await _storage.updateLastShardSyncTimestamp(now);
      _log.fine('Updated last shard sync timestamp to: $now');

      _log.info('Phase 0 complete - local shard state materialized');
    } catch (e, st) {
      _log.severe('Error during Phase 0 sync preparation', e, st);
      rethrow;
    }
  }

  /// Phase A+B: Remote Synchronization
  ///
  /// Performs complete remote sync cycle:
  /// - Phase A: Metadata Reconciliation & Queue Building
  /// - Phase B: Document & Shard Finalization
  ///
  /// If remote storage is not available (offline), this phase is skipped
  /// gracefully (offline-first architecture).
  Future<void> _syncRemote(DateTime syncTime) async {
    final config = await _configService.currentConfig;
    for (final backend in _backends) {
      _log.fine('Using backend: ${backend.name}');
      for (final remote in backend.remotes) {
        _log.fine('Configured remote: ${remote.remoteId}');

        // Check if remote storage is available
        final remoteAvailable = await remote.isAvailable();
        if (!remoteAvailable) {
          _log.info(
              'Remote storage $remote not available - skipping remote sync');
          continue;
        }

        // Create sync session with backend (e.g., load type index)
        _log.fine(
            'Creating sync storage session for backend: ${remote.remoteId}');
        final remoteSyncStorage = await remote.createSyncStorage(config);

        // Validate dataset compatibility if this backend uses shard datasets
        if (remote.useShardDatasets) {
          await _validateDatasetCompatibilityForBackend(
              remoteSyncStorage, config);
        }

        final remoteSyncOrchestrator = _remoteSyncOrchestratorFactory(
          remoteSyncStorage,
          remote.remoteId,
          useShardDatasets: remote.useShardDatasets,
        );

        _log.info('Starting Phase A+B: Remote Synchronization');

        final lastSyncTimestamp =
            await _storage.getLastRemoteSyncTimestamp(remote.remoteId);
        try {
          await remoteSyncOrchestrator.sync(
            syncTime,
            lastSyncTimestamp,
            config: config,
          );
          _log.info('Remote synchronization completed successfully');
          await _storage.updateLastRemoteSyncTimestamp(
              remote.remoteId, syncTime.millisecondsSinceEpoch);
        } catch (e, st) {
          _log.severe('Error during remote synchronization', e, st);
          // Don't update any timestamps on failure - will retry next sync
          // FIXME: Really rethrow? Shouldn't we just log and continue with next remote?
          rethrow;
        } finally {
          // Always finalize, even on error
          await remoteSyncStorage.finalizeSync();
        }
      }
    }
  }
}
