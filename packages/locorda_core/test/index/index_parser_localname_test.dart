import 'package:locorda_core/src/config/sync_engine_config.dart';
import 'package:locorda_core/src/index/index_config_base.dart';
import 'package:locorda_core/src/index/index_parser.dart';
import 'package:locorda_core/src/index/index_rdf_generator.dart';
import 'package:locorda_core/src/index/shard_manager.dart';
import 'package:locorda_core/src/mapping/resource_locator.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:test/test.dart';

void main() {
  group('IndexParser local name resolution', () {
    late IndexRdfGenerator generator;
    late LocalResourceLocator resourceLocator;
    late SyncEngineConfig knownConfig;

    setUp(() {
      resourceLocator = LocalResourceLocator(iriTermFactory: IriTerm.validated);
      generator = IndexRdfGenerator(
        resourceLocator: resourceLocator,
        shardManager: const ShardManager(),
      );

      // Create a known config with a GroupIndex
      knownConfig = SyncEngineConfig(
        resources: [
          ResourceConfigData(
            typeIri: IriTerm('https://schema.org/Recipe'),
            crdtMapping: Uri.parse('tag:test'),
            indices: [
              GroupIndexData(
                localName: 'recipes-by-category',
                groupingProperties: [
                  GroupingProperty(
                    IriTerm('https://schema.org/recipeCategory'),
                    hierarchyLevel: 1,
                  ),
                ],
              ),
              FullIndexData(
                localName: 'all-recipes',
              ),
            ],
          ),
        ],
      );
    });

    test('returns configured localName for known GroupIndexTemplate', () {
      // Create parser with known config
      final parser = IndexParser(
        knownConfig: knownConfig,
        rdfGenerator: generator,
      );

      final typeIri = IriTerm('https://schema.org/Recipe');
      final groupConfig =
          knownConfig.resources.first.indices.first as GroupIndexData;

      // Generate the template
      final templateIri =
          generator.generateGroupIndexTemplateIri(groupConfig, typeIri);
      final installationIri = IriTerm('https://example.org/installations/test');

      final graph = generator.generateGroupIndexTemplate(
        config: groupConfig,
        resourceType: typeIri,
        resourceIri: templateIri,
        installationIri: installationIri,
      );

      // Parse it back
      final parsed = parser.parseGroupIndexTemplate(graph, templateIri);

      expect(parsed, isNotNull);
      expect(parsed!.config.localName, equals('recipes-by-category'),
          reason: 'Should use configured local name from known config');
    });

    test('returns configured localName for known FullIndex', () {
      // Create parser with known config
      final parser = IndexParser(
        knownConfig: knownConfig,
        rdfGenerator: generator,
      );

      final typeIri = IriTerm('https://schema.org/Recipe');
      final fullIndexConfig =
          knownConfig.resources.first.indices[1] as FullIndexData;

      // Generate the index
      final indexIri = generator.generateFullIndexIri(fullIndexConfig, typeIri);
      final installationIri = IriTerm('https://example.org/installations/test');

      final graph = generator.generateFullIndex(
        config: fullIndexConfig,
        resourceType: typeIri,
        resourceIri: indexIri,
        installationIri: installationIri,
        shards: [],
      );

      // Parse it back
      final parsed = parser.parseFullIndex(graph, indexIri);

      expect(parsed, isNotNull);
      expect(parsed!.config.localName, equals('all-recipes'),
          reason: 'Should use configured local name from known config');
    });

    test('uses IRI value as localName for unknown indices', () {
      // Create parser with empty config (all indices are unknown)
      final emptyConfig = SyncEngineConfig(resources: []);
      final parser =
          IndexParser(knownConfig: emptyConfig, rdfGenerator: generator);

      final typeIri = IriTerm('https://schema.org/Task');
      final unknownConfig = GroupIndexData(
        localName: 'original-name-should-not-be-used',
        groupingProperties: [
          GroupingProperty(
            IriTerm('https://schema.org/status'),
            hierarchyLevel: 1,
          ),
        ],
      );

      // Generate template for unknown type
      final templateIri =
          generator.generateGroupIndexTemplateIri(unknownConfig, typeIri);
      final installationIri = IriTerm('https://example.org/installations/test');

      final graph = generator.generateGroupIndexTemplate(
        config: unknownConfig,
        resourceType: typeIri,
        resourceIri: templateIri,
        installationIri: installationIri,
      );

      // Parse it back
      final parsed = parser.parseGroupIndexTemplate(graph, templateIri);

      expect(parsed, isNotNull);
      // Should use the full IRI value as localName for unknown indices
      expect(parsed!.config.localName, equals(templateIri.value),
          reason: 'Unknown indices should use IRI value as localName');
      expect(parsed.config.localName,
          isNot(equals('original-name-should-not-be-used')),
          reason:
              'Should not use original name since this is treated as unknown index');
    });
  });
}
