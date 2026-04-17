import 'dart:convert';
import 'dart:io';

import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_core/src/index/group_key_generator.dart';
import 'package:locorda_core/src/index/index_rdf_generator.dart';
import 'package:locorda_core/src/index/shard_manager.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/vocab/generated/_index.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:test/test.dart';

import 'test_fetcher.dart';

void main() {
  group('auto group index subscription on save', () {
    test(
        'subscribes existing group index instances that are not reported as missing',
        () async {
      final storage = InMemoryStorage();
      final testAssetsDir = Directory('test/assets/graph');
      final allTestsJson = jsonDecode(
        File('${testAssetsDir.path}/all_tests.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      final configJson = jsonDecode(
        File('${testAssetsDir.path}/shared/configs/group_index_config.json')
            .readAsStringSync(),
      ) as Map<String, dynamic>;
      final config = SyncEngineConfig.fromJson(configJson);
      final fetcher = TestFetcher.fromTestJson(allTestsJson, testAssetsDir);

      final sync = await SyncEngine.create(
        config: config,
        engineParams: EngineParams(
          storage: storage,
          backends: const [],
          fetcher: fetcher,
        ),
      );

      final resource = config.resources.single;
      final typeIri = resource.typeIri;
      final indexConfig = resource.indices.whereType<GroupIndexData>().single;
      final generator = IndexRdfGenerator(
        resourceLocator:
            LocalResourceLocator(iriTermFactory: IriTerm.validated),
        shardManager: const ShardManager(),
      );
      final templateIri =
          generator.generateGroupIndexTemplateIri(indexConfig, typeIri);

      final appResourceIri = IriTerm('https://example.org/recipes/r1#it');
      final recipeCategory = IriTerm('https://schema.org/recipeCategory');
      final appData = RdfGraph.fromTriples([
        Triple(appResourceIri, Rdf.type, typeIri),
        Triple(appResourceIri, recipeCategory, LiteralTerm('Dessert')),
      ]);

      final groupKeys =
          GroupKeyGenerator(indexConfig).generateGroupKeys(appData);
      expect(groupKeys, hasLength(1));

      final groupIndexIri =
          generator.generateGroupIndexIri(templateIri, groupKeys.single);

      await storage.saveDocument(
        groupIndexIri.getDocumentIri(),
        IdxGroupIndex.classIri,
        RdfGraph.fromTriples([
          Triple(groupIndexIri, Rdf.type, IdxGroupIndex.classIri),
        ]),
        DocumentMetadata(ourPhysicalClock: 1, updatedAt: 1),
        const [],
      );

      final before = await storage.getSubscribedGroupIndices(typeIri);
      expect(before, isEmpty);

      await sync.save(typeIri, appData);

      final after = await storage.getSubscribedGroupIndices(typeIri);
      expect(after.map((entry) => entry.$1), contains(groupIndexIri));
    });

    test('updates stored fetch policy when ensure override changes', () async {
      final storage = InMemoryStorage();
      final testAssetsDir = Directory('test/assets/graph');
      final allTestsJson = jsonDecode(
        File('${testAssetsDir.path}/all_tests.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      final configJson = jsonDecode(
        File('${testAssetsDir.path}/shared/configs/group_index_config.json')
            .readAsStringSync(),
      ) as Map<String, dynamic>;
      final config = SyncEngineConfig.fromJson(configJson);
      final fetcher = TestFetcher.fromTestJson(allTestsJson, testAssetsDir);

      final sync = await SyncEngine.create(
        config: config,
        engineParams: EngineParams(
          storage: storage,
          backends: const [],
          fetcher: fetcher,
        ),
      );

      final resource = config.resources.single;
      final typeIri = resource.typeIri;
      final indexConfig = resource.indices.whereType<GroupIndexData>().single;
      final groupKeyGraph = RdfGraph.fromTriples([
        Triple(
          IriTerm('https://example.org/group-key#it'),
          IriTerm('https://schema.org/recipeCategory'),
          LiteralTerm('Dessert'),
        ),
      ]);

      await sync.ensureGroupIndexSubscription(
        indexName: indexConfig.localName,
        groupKeyGraph: groupKeyGraph,
        rootResourceFetchPolicy: RootResourceFetchPolicy.onRequest,
        triggerSync: false,
      );

      final first = await storage.getSubscribedGroupIndices(typeIri);
      expect(first, hasLength(1));
      expect(first.single.$3.toMap()['type'], 'onRequest');

      await sync.ensureGroupIndexSubscription(
        indexName: indexConfig.localName,
        groupKeyGraph: groupKeyGraph,
        rootResourceFetchPolicy: RootResourceFetchPolicy.prefetch,
        triggerSync: false,
      );

      final second = await storage.getSubscribedGroupIndices(typeIri);
      expect(second, hasLength(1));
      expect(second.single.$3.toMap()['type'], 'prefetch');
    });

    test('ensure subscription creates local group index and shard mapping',
        () async {
      final storage = InMemoryStorage();
      final testAssetsDir = Directory('test/assets/graph');
      final allTestsJson = jsonDecode(
        File('${testAssetsDir.path}/all_tests.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      final configJson = jsonDecode(
        File('${testAssetsDir.path}/shared/configs/group_index_config.json')
            .readAsStringSync(),
      ) as Map<String, dynamic>;
      final config = SyncEngineConfig.fromJson(configJson);
      final fetcher = TestFetcher.fromTestJson(allTestsJson, testAssetsDir);

      final sync = await SyncEngine.create(
        config: config,
        engineParams: EngineParams(
          storage: storage,
          backends: const [],
          fetcher: fetcher,
        ),
      );

      final resource = config.resources.single;
      final typeIri = resource.typeIri;
      final indexConfig = resource.indices.whereType<GroupIndexData>().single;
      final groupKeyGraph = RdfGraph.fromTriples([
        Triple(
          IriTerm('https://example.org/group-key#it'),
          IriTerm('https://schema.org/recipeCategory'),
          LiteralTerm('Dessert'),
        ),
      ]);

      await sync.ensureGroupIndexSubscription(
        indexName: indexConfig.localName,
        groupKeyGraph: groupKeyGraph,
        triggerSync: false,
      );

      final generator = IndexRdfGenerator(
        resourceLocator:
            LocalResourceLocator(iriTermFactory: IriTerm.validated),
        shardManager: const ShardManager(),
      );
      final templateIri =
          generator.generateGroupIndexTemplateIri(indexConfig, typeIri);
      final groupKey = GroupKeyGenerator(indexConfig)
          .generateGroupKeys(groupKeyGraph)
          .single;
      final groupIndexIri =
          generator.generateGroupIndexIri(templateIri, groupKey);

      final groupIndexDoc =
          await storage.getDocument(groupIndexIri.getDocumentIri());
      expect(groupIndexDoc, isNotNull);

      final shardsByIndex = await storage.getIndexShards([groupIndexIri]);
      final shardIris = shardsByIndex[groupIndexIri];
      expect(shardIris, isNotNull);
      expect(shardIris, hasLength(1));

      final shardDoc =
          await storage.getDocument(shardIris!.single.getDocumentIri());
      expect(shardDoc, isNotNull);
    });
  });
}
