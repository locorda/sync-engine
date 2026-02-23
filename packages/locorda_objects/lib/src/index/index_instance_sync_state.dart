library;

import 'package:meta/meta.dart';

/// Sync phase for a single remote × index instance combination.
enum RemoteSyncPhase {
  /// Subscribed, but this remote has never synced this index instance.
  notSynced,

  /// Sync cycle started and this index instance is queued.
  syncPlanned,

  /// This index instance is currently being synchronized.
  syncing,

  /// The last sync attempt completed successfully.
  ready,

  /// The last sync attempt failed.
  error,
}

/// Per-remote sync state snapshot for one index instance.
@immutable
class RemoteSyncEntry {
  final String remoteId;
  final RemoteSyncPhase phase;
  final DateTime? syncStartedAt;
  final DateTime? lastSyncedAt;
  final String? errorMessage;

  const RemoteSyncEntry({
    required this.remoteId,
    required this.phase,
    this.syncStartedAt,
    this.lastSyncedAt,
    this.errorMessage,
  });

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is RemoteSyncEntry &&
        other.remoteId == remoteId &&
        other.phase == phase &&
        other.syncStartedAt == syncStartedAt &&
        other.lastSyncedAt == lastSyncedAt &&
        other.errorMessage == errorMessage;
  }

  @override
  int get hashCode => Object.hash(
        remoteId,
        phase,
        syncStartedAt,
        lastSyncedAt,
        errorMessage,
      );
}

/// Aggregate sync state for one index instance across all configured remotes.
@immutable
class IndexInstanceSyncState {
  /// Keyed by remoteId. Empty when no backend is configured.
  final Map<String, RemoteSyncEntry> perRemote;

  const IndexInstanceSyncState({required this.perRemote});

  /// Empty state — no backend configured; data is local-only.
  const IndexInstanceSyncState.local() : perRemote = const {};

  /// Any remote is actively transferring or queued.
  bool get isSyncing => perRemote.values.any(
        (entry) =>
            entry.phase == RemoteSyncPhase.syncing ||
            entry.phase == RemoteSyncPhase.syncPlanned,
      );

  /// All remotes are in the `ready` phase — no errors and no pending work.
  bool get isReady =>
      perRemote.isNotEmpty &&
      perRemote.values.every((entry) => entry.phase == RemoteSyncPhase.ready);

  /// True if every configured remote has synced at least once.
  ///
  /// Vacuously true when no backend is configured.
  bool get hasCompletedInitialSync =>
      perRemote.values.every((entry) => entry.lastSyncedAt != null);

  /// True if any remote is currently in error state.
  bool get hasError =>
      perRemote.values.any((entry) => entry.phase == RemoteSyncPhase.error);

  /// True if any remote has an error after a previous successful sync.
  bool get hasStaleError => perRemote.values.any(
        (entry) =>
            entry.phase == RemoteSyncPhase.error && entry.lastSyncedAt != null,
      );

  /// True if any remote errored before initial sync completion.
  bool get hasInitialSyncError => perRemote.values.any(
        (entry) =>
            entry.phase == RemoteSyncPhase.error && entry.lastSyncedAt == null,
      );

  /// True if at least one configured remote has never synced successfully.
  bool get hasUnsyncedRemote =>
      perRemote.values.any((entry) => entry.lastSyncedAt == null);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! IndexInstanceSyncState) {
      return false;
    }
    if (perRemote.length != other.perRemote.length) {
      return false;
    }

    for (final entry in perRemote.entries) {
      if (other.perRemote[entry.key] != entry.value) {
        return false;
      }
    }

    return true;
  }

  @override
  int get hashCode {
    final sortedEntries = perRemote.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key));
    return Object.hashAll(
      sortedEntries.map((entry) => Object.hash(entry.key, entry.value)),
    );
  }
}
