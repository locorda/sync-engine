import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_core/src/standard_sync_engine.dart';
import 'package:locorda_core/src/sync/pipeline/streaming_remote_sync_orchestrator.dart';
import 'package:logging/logging.dart';

final _log = Logger('SyncFunction');
typedef StreamingOrchestratorFactory = StreamingRemoteSyncOrchestrator Function(
  PipelineRemoteSyncStorage pipelineSupport,
  RemoteId remoteId,
  SyncEngineConfig config, {
  required PipeperfCollector perf,
});

/// Synchronization function orchestrating complete sync cycle.
///
/// The sync function is triggered periodically or manually and performs
/// one pipeline synchronization cycle.
///
/// All remote operations use conditional requests (ETag) to minimize bandwidth
/// and ensure correct conflict resolution through 412 retry loops.
class SyncFunction {
  final Storage _storage;
  final List<PipelineBackend> _pipelineBackends;
  final ConfigService _configService;
  final StreamingOrchestratorFactory _streamingOrchestratorFactory;
  final Perflog _perflog;

  SyncFunction({
    required List<PipelineBackend> pipelineBackends,
    required Storage storage,
    required ConfigService configService,
    required StreamingOrchestratorFactory streamingOrchestratorFactory,
    required Perflog perflog,
  })  : _pipelineBackends = pipelineBackends,
        _storage = storage,
        _configService = configService,
        _streamingOrchestratorFactory = streamingOrchestratorFactory,
        _perflog = perflog.create('SyncFunction', 'sync');

  Future<void> call(DateTime syncTime) async {
    // Pipeline synchronization (metadata + documents + shards)
    await _perflog.measure(
        'sync.pipeline', () => _syncRemotePipeline(syncTime));
  }

  Future<void> _syncRemotePipeline(DateTime syncTime) async {
    final config = _configService.currentConfig;
    for (final backend in _pipelineBackends) {
      _log.fine('Using backend: ${backend.name}');
      for (final remote in backend.pipelineRemotes) {
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
        final remoteSyncStorage =
            await remote.createPipelineSyncStorage(config);

        _log.info('Starting Phase A+B: Remote Synchronization');

        final lastSyncTimestamp =
            await _storage.getLastRemoteSyncTimestamp(remote.remoteId);
        final perf = PipeperfCollector();
        SyncFinalizationState finalizationState =
            const SyncFinalizationIncomplete();
        try {
          _log.fine('Using streaming pipeline orchestrator');
          final orchestrator = _streamingOrchestratorFactory(
            remoteSyncStorage,
            remote.remoteId,
            config,
            perf: perf,
          );
          await orchestrator.sync(
            syncTime,
            lastSyncTimestamp,
            config: config,
          );

          finalizationState = const SyncFinalizationSuccess();
          _log.info('Remote synchronization completed successfully');
          await _storage.updateLastRemoteSyncTimestamp(
              remote.remoteId, syncTime.millisecondsSinceEpoch);
        } catch (e, st) {
          _log.severe('Error during remote synchronization', e, st);
          finalizationState = SyncFinalizationFailure(e, st);
          // Don't update any timestamps on failure - will retry next sync
          // FIXME: Really rethrow? Shouldn't we just log and continue with next remote?
          rethrow;
        } finally {
          await remoteSyncStorage.finalizeSync(finalizationState, perf: perf);
          perf.report();
        }
      }
    }
  }
}
