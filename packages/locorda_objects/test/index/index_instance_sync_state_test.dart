import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_rdf_core/core.dart' show IriTerm;
import 'package:test/test.dart';

RemoteId _remote(String id) => RemoteId('test-backend', id);

IndexInstanceSyncState _state(Map<RemoteId, RemoteSyncEntry> perRemote) {
  return IndexInstanceSyncState(
    indexInstanceIri: IriTerm('https://example.org/index#it'),
    perRemote: perRemote,
  );
}

void main() {
  group('IndexInstanceSyncState', () {
    test('empty map (no backend)', () {
      final state = IndexInstanceSyncState.empty(
        IriTerm('urn:locorda:local-index-state'),
      );

      expect(state.hasCompletedInitialSync, isTrue);
      expect(state.isSyncing, isFalse);
      expect(state.isReady, isFalse);
      expect(state.hasStaleError, isFalse);
      expect(state.hasInitialSyncError, isFalse);
    });

    test('one remote ready with lastSyncedAt', () {
      final state = _state({
        _remote('r1'): RemoteSyncEntry(
          remoteId: _remote('r1'),
          phase: RemoteSyncPhase.ready,
          lastSuccessfulSyncAt: DateTime.utc(2026, 1, 1),
        ),
      });

      expect(state.hasCompletedInitialSync, isTrue);
      expect(state.isSyncing, isFalse);
      expect(state.isReady, isTrue);
      expect(state.hasStaleError, isFalse);
      expect(state.hasInitialSyncError, isFalse);
    });

    test('one remote syncing without lastSyncedAt', () {
      final state = _state({
        _remote('r1'): RemoteSyncEntry(
          remoteId: _remote('r1'),
          phase: RemoteSyncPhase.syncing,
          lastAttemptStartedAt: DateTime.utc(2026, 1, 1),
        ),
      });

      expect(state.hasCompletedInitialSync, isFalse);
      expect(state.isSyncing, isTrue);
      expect(state.isReady, isFalse);
      expect(state.hasStaleError, isFalse);
      expect(state.hasInitialSyncError, isFalse);
    });

    test('one remote error with lastSyncedAt is stale error', () {
      final state = _state({
        _remote('r1'): RemoteSyncEntry(
          remoteId: _remote('r1'),
          phase: RemoteSyncPhase.error,
          lastSuccessfulSyncAt: DateTime.utc(2026, 1, 1),
        ),
      });

      expect(state.hasCompletedInitialSync, isTrue);
      expect(state.isSyncing, isFalse);
      expect(state.isReady, isFalse);
      expect(state.hasStaleError, isTrue);
      expect(state.hasInitialSyncError, isFalse);
    });

    test('one remote error without lastSyncedAt is initial sync error', () {
      final state = _state({
        _remote('r1'): RemoteSyncEntry(
          remoteId: _remote('r1'),
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
      final state = _state({
        _remote('r1'): RemoteSyncEntry(
          remoteId: _remote('r1'),
          phase: RemoteSyncPhase.ready,
          lastSuccessfulSyncAt: DateTime.utc(2026, 1, 1),
        ),
        _remote('r2'): RemoteSyncEntry(
          remoteId: _remote('r2'),
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
      final state = _state({
        _remote('r1'): RemoteSyncEntry(
          remoteId: _remote('r1'),
          phase: RemoteSyncPhase.ready,
          lastSuccessfulSyncAt: DateTime.utc(2026, 1, 1),
        ),
        _remote('r2'): RemoteSyncEntry(
          remoteId: _remote('r2'),
          phase: RemoteSyncPhase.ready,
          lastSuccessfulSyncAt: DateTime.utc(2026, 1, 2),
        ),
      });

      expect(state.hasCompletedInitialSync, isTrue);
      expect(state.isSyncing, isFalse);
      expect(state.isReady, isTrue);
      expect(state.hasStaleError, isFalse);
      expect(state.hasInitialSyncError, isFalse);
    });

    test('value equality uses deep map comparison', () {
      final left = _state({
        _remote('r1'): RemoteSyncEntry(
          remoteId: _remote('r1'),
          phase: RemoteSyncPhase.ready,
          lastSuccessfulSyncAt: DateTime.utc(2026, 1, 1),
        ),
      });
      final right = _state({
        _remote('r1'): RemoteSyncEntry(
          remoteId: _remote('r1'),
          phase: RemoteSyncPhase.ready,
          lastSuccessfulSyncAt: DateTime.utc(2026, 1, 1),
        ),
      });

      expect(left, equals(right));
      expect(left.hashCode, equals(right.hashCode));
    });
  });
}
