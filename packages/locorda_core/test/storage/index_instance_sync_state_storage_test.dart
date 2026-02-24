import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:test/test.dart';

void main() {
  group('InMemoryStorage index instance sync state', () {
    late InMemoryStorage storage;

    setUp(() async {
      storage = InMemoryStorage();
      await storage.initialize();
    });

    tearDown(() async {
      await storage.close();
    });

    test('preserves lastSuccessfulSyncAt on later error update', () async {
      final indexInstanceIri =
          IriTerm.validated('https://example.com/index/instance');
      final remote = RemoteId('solid', 'https://alice.example/');
      final successAt = DateTime.utc(2026, 2, 1, 11);

      await storage.upsertIndexInstanceSyncState(
        indexInstanceIri: indexInstanceIri,
        remoteId: remote,
        phase: RemoteSyncPhase.ready,
        lastSuccessfulSyncAt: successAt,
      );

      await storage.upsertIndexInstanceSyncState(
        indexInstanceIri: indexInstanceIri,
        remoteId: remote,
        phase: RemoteSyncPhase.error,
        lastErrorMessage: 'offline',
      );

      final snapshot =
          await storage.getIndexInstanceSyncState(indexInstanceIri);
      final entry = snapshot.perRemote[remote];

      expect(entry, isNotNull);
      expect(entry!.phase, RemoteSyncPhase.error);
      expect(entry.lastSuccessfulSyncAt, successAt);
      expect(entry.lastErrorMessage, 'offline');
    });

    test('watchConfiguredRemoteIds emits when remote is observed', () async {
      final events = <Set<RemoteId>>[];
      final subscription =
          storage.watchConfiguredRemoteIds().listen(events.add);

      await storage.updateLastRemoteSyncTimestamp(
        RemoteId('solid', 'https://bob.example/'),
        123,
      );

      await Future<void>.delayed(Duration.zero);
      await subscription.cancel();

      expect(events, isNotEmpty);
      expect(events.last, contains(RemoteId('solid', 'https://bob.example/')));
    });
  });
}
