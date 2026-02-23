import 'package:locorda_objects/src/index/index_instance_sync_state.dart';
import 'package:test/test.dart';

void main() {
  group('IndexInstanceSyncState', () {
    test('empty map (no backend)', () {
      const state = IndexInstanceSyncState.local();

      expect(state.hasCompletedInitialSync, isTrue);
      expect(state.isSyncing, isFalse);
      expect(state.isReady, isFalse);
      expect(state.hasStaleError, isFalse);
      expect(state.hasInitialSyncError, isFalse);
    });

    test('one remote ready with lastSyncedAt', () {
      final state = IndexInstanceSyncState(perRemote: {
        'r1': RemoteSyncEntry(
          remoteId: 'r1',
          phase: RemoteSyncPhase.ready,
          lastSyncedAt: DateTime.utc(2026, 1, 1),
        ),
      });

      expect(state.hasCompletedInitialSync, isTrue);
      expect(state.isSyncing, isFalse);
      expect(state.isReady, isTrue);
      expect(state.hasStaleError, isFalse);
      expect(state.hasInitialSyncError, isFalse);
    });

    test('one remote syncing without lastSyncedAt', () {
      final state = IndexInstanceSyncState(perRemote: {
        'r1': RemoteSyncEntry(
          remoteId: 'r1',
          phase: RemoteSyncPhase.syncing,
          syncStartedAt: DateTime.utc(2026, 1, 1),
        ),
      });

      expect(state.hasCompletedInitialSync, isFalse);
      expect(state.isSyncing, isTrue);
      expect(state.isReady, isFalse);
      expect(state.hasStaleError, isFalse);
      expect(state.hasInitialSyncError, isFalse);
    });

    test('one remote error with lastSyncedAt is stale error', () {
      final state = IndexInstanceSyncState(perRemote: {
        'r1': RemoteSyncEntry(
          remoteId: 'r1',
          phase: RemoteSyncPhase.error,
          lastSyncedAt: DateTime.utc(2026, 1, 1),
        ),
      });

      expect(state.hasCompletedInitialSync, isTrue);
      expect(state.isSyncing, isFalse);
      expect(state.isReady, isFalse);
      expect(state.hasStaleError, isTrue);
      expect(state.hasInitialSyncError, isFalse);
    });

    test('one remote error without lastSyncedAt is initial sync error', () {
      final state = IndexInstanceSyncState(perRemote: {
        'r1': RemoteSyncEntry(
          remoteId: 'r1',
          phase: RemoteSyncPhase.error,
        ),
      });

      expect(state.hasCompletedInitialSync, isFalse);
      expect(state.isSyncing, isFalse);
      expect(state.isReady, isFalse);
      expect(state.hasStaleError, isFalse);
      expect(state.hasInitialSyncError, isTrue);
    });

    test('two remotes mixed ready + notSynced', () {
      final state = IndexInstanceSyncState(perRemote: {
        'r1': RemoteSyncEntry(
          remoteId: 'r1',
          phase: RemoteSyncPhase.ready,
          lastSyncedAt: DateTime.utc(2026, 1, 1),
        ),
        'r2': const RemoteSyncEntry(
          remoteId: 'r2',
          phase: RemoteSyncPhase.notSynced,
        ),
      });

      expect(state.hasCompletedInitialSync, isFalse);
      expect(state.isSyncing, isFalse);
      expect(state.isReady, isFalse);
      expect(state.hasStaleError, isFalse);
      expect(state.hasInitialSyncError, isFalse);
    });

    test('two remotes both ready and synced', () {
      final state = IndexInstanceSyncState(perRemote: {
        'r1': RemoteSyncEntry(
          remoteId: 'r1',
          phase: RemoteSyncPhase.ready,
          lastSyncedAt: DateTime.utc(2026, 1, 1),
        ),
        'r2': RemoteSyncEntry(
          remoteId: 'r2',
          phase: RemoteSyncPhase.ready,
          lastSyncedAt: DateTime.utc(2026, 1, 2),
        ),
      });

      expect(state.hasCompletedInitialSync, isTrue);
      expect(state.isSyncing, isFalse);
      expect(state.isReady, isTrue);
      expect(state.hasStaleError, isFalse);
      expect(state.hasInitialSyncError, isFalse);
    });

    test('value equality uses deep map comparison', () {
      final left = IndexInstanceSyncState(perRemote: {
        'r1': RemoteSyncEntry(
          remoteId: 'r1',
          phase: RemoteSyncPhase.ready,
          lastSyncedAt: DateTime.utc(2026, 1, 1),
        ),
      });
      final right = IndexInstanceSyncState(perRemote: {
        'r1': RemoteSyncEntry(
          remoteId: 'r1',
          phase: RemoteSyncPhase.ready,
          lastSyncedAt: DateTime.utc(2026, 1, 1),
        ),
      });

      expect(left, equals(right));
      expect(left.hashCode, equals(right.hashCode));
    });
  });
}
