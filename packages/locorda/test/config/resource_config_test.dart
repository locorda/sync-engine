import 'package:locorda/locorda.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:test/test.dart';

import '../test_models.dart';

void main() {
  group('ResourceConfig', () {
    test('should create basic ResourceConfig', () {
      final config = ResourceConfig(
        type: TestDocument,
        crdtMapping: Uri.parse('https://example.com/document.ttl'),
      );

      expect(config.type, equals(TestDocument));
      expect(config.crdtMapping.toString(),
          equals('https://example.com/document.ttl'));
      expect(config.indices, isNotEmpty);
      expect(config.indices.length, equals(1));
      expect(config.indices.first, isA<FullIndexConfig>());
    });

    test('should create ResourceConfig with indices', () {
      final indices = [
        FullIndexConfig(localName: 'documents'),
        GroupIndexConfig(
          TestDocumentGroupKey,
          localName: 'documents-by-category',
          item: IndexItemConfig(TestDocument, {}),
          groupingProperties: [
            GroupingPropertyData(
              const IriTerm('https://schema.org/category'),
              // No transforms - use raw value as group key
            ),
          ],
        ),
      ];

      final config = ResourceConfig(
        type: TestDocument,
        crdtMapping: Uri.parse('https://example.com/document.ttl'),
        indices: indices,
      );

      expect(config.indices, hasLength(2));
      expect(config.indices[0], isA<FullIndexConfig>());
      expect(config.indices[1], isA<GroupIndexConfig>());
    });

    test('should create ResourceConfig without default path', () {
      final config = ResourceConfig(
        type: TestDocument,
        crdtMapping: Uri.parse('https://example.com/document.ttl'),
      );

      expect(config.type, equals(TestDocument));
      expect(config.indices, hasLength(1));
    });
  });

  group('SyncConfig', () {
    test('should create basic SyncConfig', () {
      final resources = [
        ResourceConfig(
          type: TestDocument,
          crdtMapping: Uri.parse('https://example.com/document.ttl'),
        ),
        ResourceConfig(
          type: TestCategory,
          crdtMapping: Uri.parse('https://example.com/category.ttl'),
        ),
      ];

      final config = LocordaConfig(resources: resources);

      expect(config.resources, hasLength(2));
      expect(config.resources, equals(resources));
    });

    test('should get all indices across all resources', () {
      final docIndex = FullIndexConfig(localName: 'documents');
      final categoryIndex = FullIndexConfig(localName: 'categories');

      final config = LocordaConfig(
        resources: [
          ResourceConfig(
            type: TestDocument,
            crdtMapping: Uri.parse('https://example.com/document.ttl'),
            indices: [docIndex],
          ),
          ResourceConfig(
            type: TestCategory,
            crdtMapping: Uri.parse('https://example.com/category.ttl'),
            indices: [categoryIndex],
          ),
        ],
      );

      final allIndices = config.getAllIndices();
      expect(allIndices, hasLength(2));
      expect(allIndices, contains(docIndex));
      expect(allIndices, contains(categoryIndex));
    });

    test('should get empty list when no indices exist', () {
      final config = LocordaConfig(
        resources: [
          ResourceConfig(
            type: TestDocument,
            crdtMapping: Uri.parse('https://example.com/document.ttl'),
          ),
        ],
      );

      final allIndices = config.getAllIndices();
      expect(allIndices, hasLength(1)); // Default FullIndex exists
    });

    test('should get resource config by type', () {
      final docConfig = ResourceConfig(
        type: TestDocument,
        crdtMapping: Uri.parse('https://example.com/document.ttl'),
      );
      final categoryConfig = ResourceConfig(
        type: TestCategory,
        crdtMapping: Uri.parse('https://example.com/category.ttl'),
      );

      final config = LocordaConfig(resources: [docConfig, categoryConfig]);

      expect(config.getResourceConfig(TestDocument), equals(docConfig));
      expect(config.getResourceConfig(TestCategory), equals(categoryConfig));
      expect(config.getResourceConfig(TestNote), isNull);
    });

    test('should return null for non-existent resource type', () {
      final config = LocordaConfig(
        resources: [
          ResourceConfig(
            type: TestDocument,
            crdtMapping: Uri.parse('https://example.com/document.ttl'),
          ),
        ],
      );

      expect(config.getResourceConfig(TestCategory), isNull);
    });
  });
}
