import 'package:locorda_core/src/config/sync_engine_config.dart';
import 'package:locorda_core/src/index/index_config_base.dart';
import 'package:locorda_core/src/index/index_rdf_generator.dart';
import 'package:locorda_core/src/index/shard_manager.dart';
import 'package:locorda_core/src/mapping/resource_locator.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:test/test.dart';

void main() {
  group('IndexRdfGenerator - GroupIndex', () {
    late IndexRdfGenerator generator;
    final resourceLocator = LocalResourceLocator(iriTermFactory: IriTerm.new);
    final shardManager = const ShardManager();

    setUp(() {
      generator = IndexRdfGenerator(
        resourceLocator: resourceLocator,
        shardManager: shardManager,
      );
    });

    group('generateGroupIndexTemplateIri', () {
      test('generates deterministic IRI for simple single-property grouping',
          () {
        final config = GroupIndexData(
          localName: 'test-shopping',
          groupingProperties: [
            GroupingPropertyData(
              IriTerm('https://example.org/vocab/meal#requiredForDate'),
              transforms: [
                RegexTransformData(
                  r'^([0-9]{4})-([0-9]{2})-([0-9]{2})$',
                  r'${1}-${2}',
                ),
              ],
            ),
          ],
        );

        final typeIri =
            IriTerm('https://example.org/vocab/meal#ShoppingListEntry');
        final result = generator.generateGroupIndexTemplateIri(config, typeIri);

        // Verify it's a valid IRI
        expect(result.value, isNotEmpty);
        expect(result.value, startsWith('tag:locorda.org,2025:l:'));

        // Verify it contains 'index-grouped-' in the path
        final identifier = resourceLocator.fromIri(result,
            expectedTypeIri: IriTerm(
                'https://w3id.org/solid-crdt-sync/vocab/idx#GroupIndexTemplate'));
        expect(identifier.id,
            matches(RegExp(r'^index-grouped-[a-f0-9]{8}/index$')));
      });

      test('generates deterministic IRI for multi-property grouping', () {
        final config = GroupIndexData(
          localName: 'test-multi',
          groupingProperties: [
            GroupingPropertyData(
              IriTerm('http://www.w3.org/1999/02/22-rdf-syntax-ns#type'),
              hierarchyLevel: 1,
            ),
            GroupingPropertyData(
              IriTerm('https://schema.org/keywords'),
              hierarchyLevel: 2,
              missingValue: 'default',
            ),
          ],
        );

        final typeIri = IriTerm('https://schema.org/Recipe');
        final result = generator.generateGroupIndexTemplateIri(config, typeIri);

        // Verify it's a valid IRI
        expect(result.value, isNotEmpty);
        expect(result.value, startsWith('tag:locorda.org,2025:l:'));

        // Extract and verify the ID format
        final identifier = resourceLocator.fromIri(result,
            expectedTypeIri: IriTerm(
                'https://w3id.org/solid-crdt-sync/vocab/idx#GroupIndexTemplate'));
        expect(identifier.id,
            matches(RegExp(r'^index-grouped-[a-f0-9]{8}/index$')));
      });

      test('generates same IRI for identical configurations', () {
        final config1 = GroupIndexData(
          localName: 'test-1',
          groupingProperties: [
            GroupingPropertyData(
              IriTerm('https://schema.org/dateCreated'),
              transforms: [
                RegexTransformData(
                  r'^([0-9]{4})-([0-9]{2})-([0-9]{2})$',
                  r'${1}-${2}',
                ),
              ],
            ),
          ],
        );

        final config2 = GroupIndexData(
          localName: 'test-2', // Different local name
          groupingProperties: [
            GroupingPropertyData(
              IriTerm('https://schema.org/dateCreated'),
              transforms: [
                RegexTransformData(
                  r'^([0-9]{4})-([0-9]{2})-([0-9]{2})$',
                  r'${1}-${2}',
                ),
              ],
            ),
          ],
        );

        final typeIri = IriTerm('https://schema.org/Note');
        final result1 =
            generator.generateGroupIndexTemplateIri(config1, typeIri);
        final result2 =
            generator.generateGroupIndexTemplateIri(config2, typeIri);

        // Should generate the same IRI despite different local names
        expect(result1, equals(result2));
      });

      test('generates different IRI for different transform', () {
        final config1 = GroupIndexData(
          localName: 'test',
          groupingProperties: [
            GroupingPropertyData(
              IriTerm('https://schema.org/dateCreated'),
              transforms: [
                RegexTransformData(
                  r'^([0-9]{4})-([0-9]{2})-([0-9]{2})$',
                  r'${1}-${2}',
                ),
              ],
            ),
          ],
        );

        final config2 = GroupIndexData(
          localName: 'test',
          groupingProperties: [
            GroupingPropertyData(
              IriTerm('https://schema.org/dateCreated'),
              transforms: [
                RegexTransformData(
                  r'^([0-9]{4})-[0-9]{2}-[0-9]{2}$',
                  r'${1}',
                ),
              ],
            ),
          ],
        );

        final typeIri = IriTerm('https://schema.org/Note');
        final result1 =
            generator.generateGroupIndexTemplateIri(config1, typeIri);
        final result2 =
            generator.generateGroupIndexTemplateIri(config2, typeIri);

        // Should generate different IRIs
        expect(result1, isNot(equals(result2)));
      });
    });

    group('generateGroupIndexIri', () {
      test('generates correct GroupIndex IRI from template and group key', () {
        final config = GroupIndexData(
          localName: 'test-shopping',
          groupingProperties: [
            GroupingPropertyData(
              IriTerm('https://example.org/vocab/meal#requiredForDate'),
              transforms: [
                RegexTransformData(
                  r'^([0-9]{4})-([0-9]{2})-([0-9]{2})$',
                  r'${1}-${2}',
                ),
              ],
            ),
          ],
        );

        final typeIri =
            IriTerm('https://example.org/vocab/meal#ShoppingListEntry');
        final templateIri =
            generator.generateGroupIndexTemplateIri(config, typeIri);

        final groupKey = '2024-08';
        final result = generator.generateGroupIndexIri(templateIri, groupKey);

        // Verify it's a valid IRI
        expect(result.value, isNotEmpty);
        expect(result.value, startsWith('tag:locorda.org,2025:l:'));

        // Extract and verify the ID format
        final identifier = resourceLocator.fromIri(
          result,
          expectedTypeIri:
              IriTerm('https://w3id.org/solid-crdt-sync/vocab/idx#GroupIndex'),
        );
        // Should be: index-grouped-{hash}/groups/2024-08/index
        expect(
            identifier.id,
            matches(
                RegExp(r'^index-grouped-[a-f0-9]{8}/groups/2024-08/index$')));
      });

      test('generates correct hierarchical GroupIndex IRI', () {
        final config = GroupIndexData(
          localName: 'test-hierarchical',
          groupingProperties: [
            GroupingPropertyData(
              IriTerm('https://schema.org/dateCreated'),
              hierarchyLevel: 1,
              transforms: [
                RegexTransformData(
                  r'^([0-9]{4})-[0-9]{2}-[0-9]{2}$',
                  r'${1}',
                ),
              ],
            ),
            GroupingPropertyData(
              IriTerm('https://schema.org/dateCreated'),
              hierarchyLevel: 2,
              transforms: [
                RegexTransformData(
                  r'^[0-9]{4}-([0-9]{2})-[0-9]{2}$',
                  r'${1}',
                ),
              ],
            ),
          ],
        );

        final typeIri = IriTerm('https://schema.org/Note');
        final templateIri =
            generator.generateGroupIndexTemplateIri(config, typeIri);

        final groupKey = '2024/08';
        final result = generator.generateGroupIndexIri(templateIri, groupKey);

        // Extract and verify the ID format
        final identifier = resourceLocator.fromIri(
          result,
          expectedTypeIri:
              IriTerm('https://w3id.org/solid-crdt-sync/vocab/idx#GroupIndex'),
        );
        // Should be: index-grouped-{hash}/groups/2024/08/index
        expect(
            identifier.id,
            matches(
                RegExp(r'^index-grouped-[a-f0-9]{8}/groups/2024/08/index$')));
      });
    });
  });
}
