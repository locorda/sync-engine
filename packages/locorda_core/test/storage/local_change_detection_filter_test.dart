import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:test/test.dart';

/// Regression tests for local-change detection queries.
///
/// Both [Storage.getShardsWithLocalChangesSince] and
/// [Storage.getLocallyChangedEntriesForShard] must exclude
/// `isRemoteOnly = true` entries, even when their `updatedAt` timestamp
/// is newer than `sinceTimestamp`. Without this filter, the
/// [syncRemoteOnlyShardEntries] timestamp fix (which sets `updated_at = now`
/// instead of `0`) would cause remote-only entries to be incorrectly
/// classified as local changes, triggering downstream Stage7c crashes.
void main() {
  group('local change detection filters remote-only entries', () {
    const sinceTimestamp = 1000;

    final shardIri = IriTerm.validated('https://example.com/shard/1');
    final indexIri = IriTerm.validated('https://example.com/index/1');
    final typeIri = IriTerm.validated('https://example.com/Type');
    final localResource = IriTerm.validated('https://example.com/res/local');
    final remoteOnlyResource =
        IriTerm.validated('https://example.com/res/remote-only');

    Future<void> seedEntries(
      Storage storage, {
      required bool includeLocalEntry,
      required bool includeRemoteOnlyEntry,
    }) async {
      if (includeLocalEntry) {
        await storage.saveIndexEntry(
          shardIri: shardIri,
          indexIri: indexIri,
          resourceIri: localResource,
          resourceType: typeIri,
          clockHash: 'local-hash',
          isDeleted: false,
          isRemoteOnly: false,
          updatedAt: sinceTimestamp + 1,
          ourPhysicalClock: 42,
        );
      }
      if (includeRemoteOnlyEntry) {
        await storage.saveIndexEntry(
          shardIri: shardIri,
          indexIri: indexIri,
          resourceIri: remoteOnlyResource,
          resourceType: typeIri,
          clockHash: 'remote-hash',
          isDeleted: false,
          isRemoteOnly: true,
          // Simulates the fixed syncRemoteOnlyShardEntries behaviour:
          // updated_at = now (not 0).
          updatedAt: sinceTimestamp + 1,
          ourPhysicalClock: 0,
        );
      }
    }

    group('InMemoryStorage', () {
      late InMemoryStorage storage;

      setUp(() async {
        storage = InMemoryStorage();
        await storage.initialize();
      });

      tearDown(() async {
        await storage.close();
      });

      group('getShardsWithLocalChangesSince', () {
        test('excludes shard when only remote-only entry changed', () async {
          await seedEntries(storage,
              includeLocalEntry: false, includeRemoteOnlyEntry: true);

          final shards = await storage
              .getShardsWithLocalChangesSince(sinceTimestamp, limit: 20);

          expect(shards, isEmpty);
        });

        test('includes shard when local entry changed', () async {
          await seedEntries(storage,
              includeLocalEntry: true, includeRemoteOnlyEntry: false);

          final shards = await storage
              .getShardsWithLocalChangesSince(sinceTimestamp, limit: 20);

          expect(shards, contains(shardIri));
        });

        test('includes shard when both local and remote-only entries changed',
            () async {
          await seedEntries(storage,
              includeLocalEntry: true, includeRemoteOnlyEntry: true);

          final shards = await storage
              .getShardsWithLocalChangesSince(sinceTimestamp, limit: 20);

          expect(shards, contains(shardIri));
        });
      });

      group('getLocallyChangedEntriesForShard', () {
        test('excludes remote-only entry with recent updatedAt', () async {
          await seedEntries(storage,
              includeLocalEntry: false, includeRemoteOnlyEntry: true);

          final entries = await storage.getLocallyChangedEntriesForShard(
              shardIri, sinceTimestamp);

          expect(entries, isEmpty);
        });

        test('includes local entry with recent updatedAt', () async {
          await seedEntries(storage,
              includeLocalEntry: true, includeRemoteOnlyEntry: false);

          final entries = await storage.getLocallyChangedEntriesForShard(
              shardIri, sinceTimestamp);

          expect(entries, hasLength(1));
          expect(entries.first.resourceIri, equals(localResource));
        });

        test('excludes remote-only entry when mixed with local entry',
            () async {
          await seedEntries(storage,
              includeLocalEntry: true, includeRemoteOnlyEntry: true);

          final entries = await storage.getLocallyChangedEntriesForShard(
              shardIri, sinceTimestamp);

          expect(entries, hasLength(1));
          expect(entries.first.resourceIri, equals(localResource));
        });
      });
    });
  });
}
