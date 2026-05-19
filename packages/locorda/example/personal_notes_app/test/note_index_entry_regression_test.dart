import 'package:flutter_test/flutter_test.dart';
import 'package:locorda/locorda.dart';
import 'package:locorda_core/locorda_core.dart'
    show InMemoryStorage, EngineParams;

import 'package:personal_notes_app/init_rdf_mapper.g.dart'
    as personal_notes_mapper;
import 'package:personal_notes_app/locorda_config.g.dart'
    as personal_notes_config;
import 'package:personal_notes_app/models/note.dart';
import 'package:personal_notes_app/models/note_group_key.dart';

Future<ObjectSyncEngine> _createObjectSyncEngine(
  InMemoryStorage storage,
) async {
  return ObjectSyncEngine.create(
    config: personal_notes_config.generateLocordaConfig(),
    mapperInitializer: (context) => personal_notes_mapper.initRdfMapper(
      rdfMapper: context.baseRdfMapper,
      $indexItemIriFactory: context.indexItemIriFactory,
      $resourceIriFactory: context.resourceIriFactory,
      $resourceRefFactory: context.resourceRefFactory,
    ),
    syncEngineFactory: (syncConfig) => SyncEngine.create(
      config: syncConfig,
      engineParams: EngineParams(
        storage: storage,
        backends: const [],
      ),
    ),
  );
}

void main() {
  group('Note index entry regression', () {
    test('saving a note persists a matching group index entry', () async {
      final storage = InMemoryStorage();
      await storage.initialize();
      final sync = await _createObjectSyncEngine(storage);

      final note = Note(
        id: 'note-regression-1',
        title: 'Regression note',
        content: 'This note should produce a NoteIndexEntry.',
        createdAt: DateTime.utc(2026, 4, 22, 15, 55, 4, 377),
        modifiedAt: DateTime.utc(2026, 4, 22, 15, 55, 4, 377),
      );

      await sync.ensureGroupIndexSubscription<NoteGroupKey>(
        NoteGroupKey.fromDate(note.createdAt),
        triggerSync: false,
      );

      final preSaveGroupSyncState = await sync
          .watchGroupIndexSyncState<NoteGroupKey>(
            NoteGroupKey.fromDate(note.createdAt),
          )
          .first;
      final preSaveGroupIndexIri = preSaveGroupSyncState.indexInstanceIri;
      final preSaveShardsByIndex =
          await storage.getIndexShards([preSaveGroupIndexIri]);
      final preSaveShardIris = preSaveShardsByIndex[preSaveGroupIndexIri];

      expect(preSaveShardIris, isNotNull);
      expect(preSaveShardIris, hasLength(1));

      await sync.save(note);
      await sync.syncManager.sync();

      final groupSyncState = await sync
          .watchGroupIndexSyncState<NoteGroupKey>(
            NoteGroupKey.fromDate(note.createdAt),
          )
          .first;
      final groupIndexIri = groupSyncState.indexInstanceIri;

      final shardsByIndex = await storage.getIndexShards([groupIndexIri]);
      final shardIris = shardsByIndex[groupIndexIri];

      expect(shardIris, isNotNull);
      expect(shardIris, hasLength(1));

      final entries =
          await storage.getActiveIndexEntriesForShard(shardIris!.single);

      expect(entries, hasLength(1));
      expect(entries.single.resourceIri.value, contains('#note'));
      await sync.close();
      await storage.close();
    });
  });
}
