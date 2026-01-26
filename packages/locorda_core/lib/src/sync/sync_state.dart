/// Sync state model for reactive sync status updates.
library;

/// The reason why a sync operation was triggered.
///
/// This allows UI and analytics to distinguish between different
/// types of sync operations and provide appropriate feedback.
enum SyncTrigger {
  /// User explicitly triggered sync (e.g., "Sync Now" button).
  manual,

  /// Automatic sync on application startup.
  startup,

  /// Automatic sync on a scheduled interval.
  scheduled,

  /// Sync triggered after local data changes.
  dataChange,

  /// Sync triggered after network connectivity is restored.
  connectionRestore,

  /// Sync triggered by pull-to-refresh gesture.
  pullToRefresh,

  /// Sync triggered after user authentication/login.
  login,
}

/// Current status of the sync operation.
enum SyncStatus {
  /// No sync is in progress, waiting for trigger.
  idle,

  /// Sync operation is currently in progress.
  syncing,

  /// Last sync completed successfully.
  success,

  /// Last sync failed with an error.
  error,
}

/// Immutable state representing the current sync status.
///
/// This class is broadcast via [SyncManager.statusStream] to allow
/// UI components to reactively update based on sync state changes.
class SyncState {
  /// Current sync status.
  final SyncStatus status;

  /// Timestamp of the last successful sync, null if never synced.
  final DateTime? lastSyncTime;

  /// Human-readable error message if status is [SyncStatus.error].
  final String? errorMessage;

  /// The exception that caused the error, if status is [SyncStatus.error].
  final Exception? error;

  /// The reason why the last sync was triggered, if known.
  ///
  /// Useful for UI to provide context-appropriate feedback (e.g., showing
  /// a subtle animation for automatic syncs vs. explicit progress for manual syncs).
  final SyncTrigger? lastTrigger;

  const SyncState({
    required this.status,
    this.lastSyncTime,
    this.errorMessage,
    this.error,
    this.lastTrigger,
  });

  /// Initial idle state with no previous sync.
  const SyncState.idle()
      : status = SyncStatus.idle,
        lastSyncTime = null,
        errorMessage = null,
        error = null,
        lastTrigger = null;

  /// Create a syncing state.
  const SyncState.syncing({this.lastSyncTime, this.lastTrigger})
      : status = SyncStatus.syncing,
        errorMessage = null,
        error = null;

  /// Create a success state with the current timestamp.
  SyncState.success(DateTime lastSyncTime, {SyncTrigger? trigger})
      : status = SyncStatus.success,
        lastSyncTime = lastSyncTime,
        errorMessage = null,
        error = null,
        lastTrigger = trigger;

  /// Create an error state with error details.
  SyncState.error({
    required this.errorMessage,
    this.error,
    this.lastSyncTime,
    this.lastTrigger,
  }) : status = SyncStatus.error;

  /// Copy this state with updated fields.
  SyncState copyWith({
    SyncStatus? status,
    DateTime? lastSyncTime,
    String? errorMessage,
    Exception? error,
    SyncTrigger? lastTrigger,
  }) {
    return SyncState(
      status: status ?? this.status,
      lastSyncTime: lastSyncTime ?? this.lastSyncTime,
      errorMessage: errorMessage ?? this.errorMessage,
      error: error ?? this.error,
      lastTrigger: lastTrigger ?? this.lastTrigger,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SyncState &&
          runtimeType == other.runtimeType &&
          status == other.status &&
          lastSyncTime == other.lastSyncTime &&
          errorMessage == other.errorMessage &&
          error == other.error &&
          lastTrigger == other.lastTrigger;

  @override
  int get hashCode =>
      status.hashCode ^
      lastSyncTime.hashCode ^
      errorMessage.hashCode ^
      error.hashCode ^
      lastTrigger.hashCode;

  @override
  String toString() {
    return 'SyncState(status: $status, lastSyncTime: $lastSyncTime, '
        'errorMessage: $errorMessage, error: $error, lastTrigger: $lastTrigger)';
  }
}
