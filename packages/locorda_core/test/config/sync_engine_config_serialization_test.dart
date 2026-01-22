import 'package:locorda_core/src/config/sync_engine_config.dart';
import 'package:locorda_core/src/index/index_config_base.dart';
import 'package:locorda_core/src/sync/sync_manager.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:test/test.dart';

void main() {
  group('Config Serialization Round-Trip Tests', () {
    test('IndexItemGraphConfig serialization', () {
      final original = IndexItemData({
        IriTerm('http://schema.org/name'),
        IriTerm('http://schema.org/description'),
      });

      final json = original.toJson();
      final deserialized = IndexItemData.fromJson(json);

      expect(deserialized.properties, equals(original.properties));
    });

    test('RegexTransform serialization', () {
      const original = RegexTransform(r'^(\d{4})-(\d{2})', r'$1-$2');

      final json = original.toJson();
      final deserialized = RegexTransform.fromJson(json);

      expect(deserialized.pattern, equals(original.pattern));
      expect(deserialized.replacement, equals(original.replacement));
    });

    test('GroupingProperty serialization with transforms', () {
      final original = GroupingProperty(
        IriTerm('http://schema.org/dateCreated'),
        hierarchyLevel: 2,
        missingValue: 'unknown',
        transforms: [
          const RegexTransform(r'^(\d{4})-(\d{2})', r'$1-$2'),
        ],
      );

      final json = original.toJson();
      final deserialized = GroupingProperty.fromJson(json);

      expect(deserialized.predicate, equals(original.predicate));
      expect(deserialized.hierarchyLevel, equals(original.hierarchyLevel));
      expect(deserialized.missingValue, equals(original.missingValue));
      expect(deserialized.transforms?.length, equals(1));
      expect(deserialized.transforms![0].pattern, equals(r'^(\d{4})-(\d{2})'));
    });

    test('FullIndexGraphConfig serialization', () {
      final original = FullIndexData(
        localName: 'allNotes',
        itemFetchPolicy: ItemFetchPolicy.prefetch,
        item: IndexItemData({
          IriTerm('http://schema.org/name'),
        }),
      );

      final json = original.toJson();
      final deserialized = FullIndexData.fromJson(json);

      expect(deserialized.localName, equals(original.localName));
      expect(deserialized.itemFetchPolicy, equals(ItemFetchPolicy.prefetch));
      expect(deserialized.item?.properties, equals(original.item?.properties));
    });

    test('GroupIndexGraphConfig serialization', () {
      final original = GroupIndexData(
        localName: 'byMonth',
        groupingProperties: [
          GroupingProperty(
            IriTerm('http://schema.org/dateCreated'),
            hierarchyLevel: 1,
            transforms: [
              const RegexTransform(r'^(\d{4})-(\d{2})', r'$1-$2'),
            ],
          ),
        ],
        item: IndexItemData({
          IriTerm('http://schema.org/name'),
        }),
      );

      final json = original.toJson();
      final deserialized = GroupIndexData.fromJson(json);

      expect(deserialized.localName, equals(original.localName));
      expect(deserialized.groupingProperties.length, equals(1));
      expect(deserialized.item?.properties, equals(original.item?.properties));
    });

    test('DocumentIriTemplate serialization', () {
      final original =
          DocumentIriTemplate.fromJson('https://example.com/notes/{id}');

      final json = original.toJson();
      final deserialized = DocumentIriTemplate.fromJson(json);

      expect(deserialized.template, equals(original.template));
      expect(deserialized.variables, equals(original.variables));
    });

    test('AutoSyncConfig serialization', () {
      const original = AutoSyncConfig.enabled(
        interval: Duration(minutes: 10),
        syncOnStartup: false,
      );

      final json = original.toJson();
      final deserialized = AutoSyncConfig.fromJson(json);

      expect(deserialized.enabled, equals(original.enabled));
      expect(deserialized.interval, equals(original.interval));
      expect(deserialized.syncOnStartup, equals(original.syncOnStartup));
    });

    test('ResourceGraphConfig serialization', () {
      final original = ResourceConfigData(
        typeIri: IriTerm('http://schema.org/Note'),
        crdtMapping: Uri.parse('http://example.com/mappings/note-v1'),
        documentIriTemplate: 'https://example.com/notes/{id}',
        indices: [
          FullIndexData(
            localName: 'allNotes',
            itemFetchPolicy: ItemFetchPolicy.prefetch,
          ),
          GroupIndexData(
            localName: 'byMonth',
            groupingProperties: [
              GroupingProperty(
                IriTerm('http://schema.org/dateCreated'),
                hierarchyLevel: 1,
              ),
            ],
          ),
        ],
      );

      final json = original.toJson();
      final deserialized = ResourceConfigData.fromJson(json);

      expect(deserialized.typeIri, equals(original.typeIri));
      expect(deserialized.crdtMapping, equals(original.crdtMapping));
      expect(deserialized.documentIriTemplate?.template,
          equals(original.documentIriTemplate?.template));
      expect(deserialized.indices.length, equals(2));
      expect(deserialized.indices[0].localName, equals('allNotes'));
      expect(deserialized.indices[1].localName, equals('byMonth'));
    });

    test('SyncEngineConfig full serialization', () {
      final original = SyncEngineConfig(
        resources: [
          ResourceConfigData(
            typeIri: IriTerm('http://schema.org/Note'),
            crdtMapping: Uri.parse('http://example.com/mappings/note-v1'),
            documentIriTemplate: 'https://example.com/notes/{id}',
            indices: [
              FullIndexData(
                localName: 'allNotes',
                itemFetchPolicy: ItemFetchPolicy.onRequest,
                item: IndexItemData({
                  IriTerm('http://schema.org/name'),
                  IriTerm('http://schema.org/description'),
                }),
              ),
              GroupIndexData(
                localName: 'byMonth',
                groupingProperties: [
                  GroupingProperty(
                    IriTerm('http://schema.org/dateCreated'),
                    hierarchyLevel: 1,
                    missingValue: 'unknown',
                    transforms: [
                      const RegexTransform(r'^(\d{4})-(\d{2})', r'$1-$2'),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ],
        autoSyncConfig: const AutoSyncConfig.enabled(
          interval: Duration(minutes: 15),
          syncOnStartup: true,
        ),
      );

      final json = original.toJson();
      final deserialized = SyncEngineConfig.fromJson(json);

      expect(deserialized.resources.length, equals(1));
      expect(deserialized.resources[0].typeIri,
          equals(original.resources[0].typeIri));
      expect(deserialized.resources[0].indices.length, equals(2));
      expect(deserialized.autoSyncConfig.enabled, equals(true));
      expect(deserialized.autoSyncConfig.interval,
          equals(const Duration(minutes: 15)));
      expect(deserialized.autoSyncConfig.syncOnStartup, equals(true));
    });
  });
}
