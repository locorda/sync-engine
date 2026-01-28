/// Sync manager for coordinating synchronization operations and status.
library;

import 'dart:async';
import 'package:locorda_core/src/hlc_service.dart';
import 'package:logging/logging.dart';
import 'sync_state.dart';
import 'sync_manager.dart';

final _log = Logger('StandardSyncManager');

/// Manager for coordinating synchronization operations with reactive status updates.
///
/// Provides:
/// - Stream-based sync status for reactive UI updates
/// - Manual sync triggering
/// - Automatic sync with configurable intervals
/// - Startup sync support
///
/// Usage:
/// ```dart
/// final syncManager = SyncManager(
///   syncFunction: () async {
///     // Perform actual sync operations
///   },
///   autoSyncConfig: AutoSyncConfig.enabled(interval: Duration(minutes: 10)),
/// );
///
/// // Listen to status changes
/// syncManager.statusStream.listen((state) {
///   print('Sync status: ${state.status}');
/// });
///
/// // Trigger manual sync
/// await syncManager.sync();
///
/// // Clean up
/// await syncManager.dispose();
/// ```
class StandardSyncManager implements SyncManager {
  final Future<void> Function(DateTime syncTime) _syncFunction;
  final AutoSyncConfig _autoSyncConfig;

  final _statusController = StreamController<SyncState>.broadcast();
  SyncState _currentState = const SyncState.idle();
  Timer? _autoSyncTimer;
  bool _isDisposed = false;
  Completer<void>? _syncCompleter;
  PhysicalTimestampFactory _physicalTimestampFactory;

  /// Stream of sync state changes.
  ///
  /// Emits a new [SyncState] whenever the sync status changes.
  /// This is a broadcast stream, so multiple listeners are supported.
  Stream<SyncState> get statusStream => _statusController.stream;

  /// Current sync state (synchronous access).
  SyncState get currentState => _currentState;

  /// Whether a sync operation is currently in progress.
  bool get isSyncing => _currentState.status == SyncStatus.syncing;

  StandardSyncManager({
    required Future<void> Function(DateTime syncTime) syncFunction,
    AutoSyncConfig autoSyncConfig = const AutoSyncConfig.disabled(),
    required PhysicalTimestampFactory physicalTimestampFactory,
  })  : _syncFunction = syncFunction,
        _autoSyncConfig = autoSyncConfig,
        _physicalTimestampFactory = physicalTimestampFactory {
    _initialize();
  }

  void _initialize() {
    // Trigger startup sync if configured
    if (_autoSyncConfig.syncOnStartup) {
      _log.info('Triggering startup sync');
      // Schedule for next event loop to allow initialization to complete
      Future.microtask(() => sync(trigger: SyncTrigger.startup));
    }

    // Setup automatic sync timer if enabled
    if (_autoSyncConfig.enabled) {
      _log.info(
          'Enabling automatic sync with interval: ${_autoSyncConfig.interval}');
      _setupAutoSync();
    }
  }

  void _setupAutoSync() {
    _autoSyncTimer?.cancel();
    if (_autoSyncConfig.interval <= Duration.zero) {
      _autoSyncTimer = null;
      return;
    }
    _autoSyncTimer = Timer.periodic(_autoSyncConfig.interval, (_) {
      _log.fine('Auto-sync timer triggered');
      sync(trigger: SyncTrigger.scheduled);
    });
  }

  /// Trigger a manual sync operation.
  ///
  /// If a sync is already in progress, this will wait for it to complete
  /// and then return without triggering another sync.
  ///
  /// Returns a [Future] that completes when the sync operation finishes
  /// (either successfully or with an error).
  @override
  Future<void> sync({SyncTrigger trigger = SyncTrigger.manual}) async {
    if (_isDisposed) {
      _log.warning('Attempted to sync after disposal');
      return;
    }

    // If already syncing, wait for current sync to complete
    if (_syncCompleter != null) {
      _log.fine('Sync already in progress, waiting for completion');
      return _syncCompleter!.future;
    }

    _syncCompleter = Completer<void>();

    try {
      _log.info('Starting sync operation (trigger: $trigger)');
      _updateState(SyncState.syncing(
        lastSyncTime: _currentState.lastSyncTime,
        lastTrigger: trigger,
      ));

      // Perform the actual sync
      final syncTime = _physicalTimestampFactory();
      await _syncFunction(syncTime);

      _log.info('Sync completed successfully');
      _updateState(SyncState.success(syncTime, trigger: trigger));
      _syncCompleter!.complete();
    } catch (error, stackTrace) {
      _log.severe('Sync failed', error, stackTrace);

      final errorMessage = error.toString();
      final exception =
          error is Exception ? error : Exception(error.toString());

      _updateState(SyncState.error(
        errorMessage: errorMessage,
        error: exception,
        lastSyncTime: _currentState.lastSyncTime,
        lastTrigger: trigger,
      ));

      _syncCompleter!.completeError(error, stackTrace);
    } finally {
      _syncCompleter = null;
    }
  }

  void _updateState(SyncState newState) {
    if (_isDisposed) return;

    _currentState = newState;
    _statusController.add(newState);
  }

  /// Enable automatic sync with the given interval.
  ///
  /// If automatic sync is already enabled, this will update the interval.
  @override
  void enableAutoSync({Duration interval = const Duration(minutes: 5)}) {
    if (_isDisposed) {
      _log.warning('Attempted to enable auto-sync after disposal');
      return;
    }

    _log.info('Enabling automatic sync with interval: $interval');
    _autoSyncTimer?.cancel();
    if (interval <= Duration.zero) {
      _autoSyncTimer = null;
      return;
    }
    _autoSyncTimer = Timer.periodic(interval, (_) {
      _log.fine('Auto-sync timer triggered');
      sync(trigger: SyncTrigger.scheduled);
    });
  }

  /// Disable automatic sync.
  ///
  /// Any in-progress sync will complete normally.
  void disableAutoSync() {
    _log.info('Disabling automatic sync');
    _autoSyncTimer?.cancel();
    _autoSyncTimer = null;
  }

  /// Clean up resources.
  ///
  /// Should be called when the sync manager is no longer needed.
  /// After disposal, no further operations are allowed.
  Future<void> dispose() async {
    if (_isDisposed) return;

    _log.info('Disposing SyncManager');
    _isDisposed = true;

    _autoSyncTimer?.cancel();
    _autoSyncTimer = null;

    await _statusController.close();
    
  }
}
