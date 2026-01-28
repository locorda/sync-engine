import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_core/src/storage/sync_timestamp_storage.dart';
import 'package:locorda_core/src/sync/remote_sync_orchestrator.dart';
import 'package:locorda_core/src/sync/shard_document_generator.dart';
import 'package:logging/logging.dart';

final _log = Logger('SyncFunction');

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
  final SyncEngineConfig _config;
  final RemoteSyncOrchestrator Function(
          RemoteSyncStorage syncStorage, RemoteId remoteId)
      _remoteSyncOrchestratorFactory;

  SyncFunction({
    required List<Backend> backends,
    required Storage storage,
    required SyncEngineConfig config,
    required RemoteSyncOrchestrator Function(
            RemoteSyncStorage syncStorage, RemoteId remoteId)
        remoteSyncOrchestratorFactory,
    required ShardDocumentGenerator shardDocumentGenerator,
  })  : _backends = backends,
        _storage = storage,
        _config = config,
        _shardDocumentGenerator = shardDocumentGenerator,
        _remoteSyncOrchestratorFactory = remoteSyncOrchestratorFactory;

  Future<void> call(DateTime syncTime) async {
    // Phase 0: Sync Preparation (materialize local shard state)
    await _prepareSync(syncTime);

    // Phase A+B: Remote Synchronization (metadata + documents + shards)
    await _syncRemote(syncTime);
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
    for (final backend in _backends) {
      _log.fine('Using backend: ${backend.name}');
      for (final remote in backend.remotes) {
        _log.fine('Configured remote: ${remote.remoteId}');

        // Check if remote storage is available
        final remoteAvailable = await remote.isAvailable();
        if (!remoteAvailable) {
          _log.info('Remote storage not available - skipping remote sync');
          return;
        }

        // Create sync session with backend (e.g., load type index)
        _log.fine(
            'Creating sync storage session for backend: ${remote.remoteId}');
        final remoteSyncStorage = await remote.createSyncStorage(_config);

        final remoteSyncOrchestrator = _remoteSyncOrchestratorFactory(
          remoteSyncStorage,
          remote.remoteId,
        );

        _log.info('Starting Phase A+B: Remote Synchronization');

        final lastSyncTimestamp =
            await _storage.getLastRemoteSyncTimestamp(remote.remoteId);
        try {
          await remoteSyncOrchestrator.sync(syncTime, lastSyncTimestamp);
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
