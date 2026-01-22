import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_core/src/generated/_index.dart';
import 'package:locorda_core/src/index/index_property_resolver.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:test/test.dart';

void main() {
  group('IndexPropertyResolver', () {
    late InMemoryStorage storage;
    late IndexPropertyResolver resolver;

    setUp(() {
      storage = InMemoryStorage();
      resolver = IndexPropertyResolver(
          storage: storage,
          cacheSize: 3,
          resourceLocator:
              LocalResourceLocator(iriTermFactory: IriTerm.validated));
    });

    Future<Set<IriTerm>> resolveIndexedProperties(
        IriTerm shardDocumentIri) async {
      final (indexOrTemplateIri, properties) =
          await resolver.resolveIndexedProperties(shardDocumentIri);
      return properties;
    }

    /// Helper to create a document with minimal metadata
    DocumentMetadata _createMetadata() {
      final now = DateTime.now().millisecondsSinceEpoch;
      return DocumentMetadata(
        ourPhysicalClock: now,
        updatedAt: now,
      );
    }

    /// Helper to save a document to storage
    Future<void> _saveDocument(
      IriTerm docIri,
      IriTerm typeIri,
      RdfGraph graph,
    ) async {
      final resourceIri = typeIri == IdxShard.classIri
          ? docIri.withFragment('shard')
          : docIri.withFragment('it');
      await storage.saveDocument(
        docIri,
        typeIri,
        graph.withTriples([Triple(docIri, Foaf.primaryTopic, resourceIri)]),
        _createMetadata(),
        [],
      );
    }

    group('Basic Resolution', () {
      test('should resolve properties from FullIndex', () async {
        final shardDocIri = IriTerm('http://example.org/shard/doc');
        final indexDocIri = IriTerm('http://example.org/index');

        // Setup: Shard document
        final shardDoc = '''
@base <http://example.org/shard/doc#> .
@prefix idx: <https://w3id.org/solid-crdt-sync/vocab/idx#> .

<#shard> a idx:Shard;
    idx:isShardOf <http://example.org/index#it> .
''';

        await _saveDocument(
            shardDocIri, IdxShard.classIri, turtle.decode(shardDoc));

        // Setup: FullIndex document with indexed properties

        final indexDoc = '''
@base <http://example.org/index#> .
@prefix idx: <https://w3id.org/solid-crdt-sync/vocab/idx#> .
@prefix sc: <http://schema.org/> .

<#it> a idx:FullIndex;
    idx:indexedProperty [ idx:trackedProperty sc:name ], [ idx:trackedProperty sc:keywords ] .
''';

        await _saveDocument(
            indexDocIri, IdxFullIndex.classIri, turtle.decode(indexDoc));

        // Execute
        final properties = await resolveIndexedProperties(shardDocIri);

        // Verify
        expect(properties, hasLength(2));
        expect(properties, contains(IriTerm('http://schema.org/name')));
        expect(properties, contains(IriTerm('http://schema.org/keywords')));
      });

      test('should resolve properties from GroupIndex via template', () async {
        final shardDocIri = IriTerm('http://example.org/shard/doc');
        final groupIndexDocIri = IriTerm('http://example.org/group/index');
        final templateDocIri = IriTerm('http://example.org/template');

        // Setup: Shard document
        final shardDoc = '''
@base <http://example.org/shard/doc#> .
@prefix idx: <https://w3id.org/solid-crdt-sync/vocab/idx#> .

<#shard> a idx:Shard;
    idx:isShardOf <http://example.org/group/index#it> .
''';

        await _saveDocument(
            shardDocIri, IdxShard.classIri, turtle.decode(shardDoc));

        // Setup: GroupIndex document with basedOn
        final groupIndexDoc = '''
@base <http://example.org/group/index#> .
@prefix idx: <https://w3id.org/solid-crdt-sync/vocab/idx#> .

<#it> a idx:GroupIndex;
    idx:basedOn <http://example.org/template#it> .
''';

        await _saveDocument(groupIndexDocIri, IdxGroupIndex.classIri,
            turtle.decode(groupIndexDoc));

        // Setup: Template document with indexed properties
        final templateDoc = '''
@base <http://example.org/template#> .
@prefix idx: <https://w3id.org/solid-crdt-sync/vocab/idx#> .
@prefix sc: <http://schema.org/> .

<#it> a idx:GroupIndexTemplate;
    idx:indexedProperty [ idx:trackedProperty sc:dateCreated ] .
''';

        await _saveDocument(templateDocIri, IdxGroupIndexTemplate.classIri,
            turtle.decode(templateDoc));

        // Execute
        final properties = await resolveIndexedProperties(shardDocIri);

        // Verify
        expect(properties, hasLength(1));
        expect(properties, contains(IriTerm('http://schema.org/dateCreated')));
      });

      test('should return empty set when shard document not found', () async {
        final shardDocIri = IriTerm('http://example.org/nonexistent/shard');

        final properties = await resolveIndexedProperties(shardDocIri);

        expect(properties, isEmpty);
      });

      test('should return empty set when shard has no isShardOf', () async {
        final shardDocIri = IriTerm('http://example.org/shard/doc');

        // Setup: Shard document without idx:isShardOf
        final shardDoc = '''
@base <http://example.org/shard/doc#> .
@prefix idx: <https://w3id.org/solid-crdt-sync/vocab/idx#> .

<#shard> a idx:Shard .
''';

        await _saveDocument(
            shardDocIri, IdxShard.classIri, turtle.decode(shardDoc));

        final properties = await resolveIndexedProperties(shardDocIri);

        expect(properties, isEmpty);
      });

      test('should return empty set when index document not found', () async {
        final shardDocIri = IriTerm('http://example.org/shard/doc');

        // Setup: Shard document pointing to non-existent index
        final shardDoc = '''
@base <http://example.org/shard/doc#> .
@prefix idx: <https://w3id.org/solid-crdt-sync/vocab/idx#> .

<#shard> a idx:Shard;
    idx:isShardOf <http://example.org/nonexistent/index#it> .
''';

        await _saveDocument(
            shardDocIri, IdxShard.classIri, turtle.decode(shardDoc));

        final properties = await resolveIndexedProperties(shardDocIri);

        expect(properties, isEmpty);
      });

      test('should handle index with no indexed properties', () async {
        final shardDocIri = IriTerm('http://example.org/shard/doc');
        final indexDocIri = IriTerm('http://example.org/index');

        // Setup: Shard document
        final shardDoc = '''
@base <http://example.org/shard/doc#> .
@prefix idx: <https://w3id.org/solid-crdt-sync/vocab/idx#> .

<#shard> a idx:Shard;
    idx:isShardOf <http://example.org/index#it> .
''';

        await _saveDocument(
            shardDocIri, IdxShard.classIri, turtle.decode(shardDoc));

        // Setup: Index document without indexed properties
        final indexDoc = '''
@base <http://example.org/index#> .
@prefix idx: <https://w3id.org/solid-crdt-sync/vocab/idx#> .

<#it> a idx:FullIndex .
''';

        await _saveDocument(
            indexDocIri, IdxFullIndex.classIri, turtle.decode(indexDoc));

        final properties = await resolveIndexedProperties(shardDocIri);

        expect(properties, isEmpty);
      });
    });

    group('Caching Behavior', () {
      test('should cache resolved properties', () async {
        final shardDocIri = IriTerm('http://example.org/shard/doc');
        final indexDocIri = IriTerm('http://example.org/index');

        // Setup: Shard document
        final shardDoc = '''
@base <http://example.org/shard/doc#> .
@prefix idx: <https://w3id.org/solid-crdt-sync/vocab/idx#> .

<#shard> a idx:Shard;
    idx:isShardOf <http://example.org/index#it> .
''';

        await _saveDocument(
            shardDocIri, IdxShard.classIri, turtle.decode(shardDoc));

        // Setup: Index document
        final indexDoc = '''
@base <http://example.org/index#> .
@prefix idx: <https://w3id.org/solid-crdt-sync/vocab/idx#> .
@prefix sc: <http://schema.org/> .

<#it> a idx:FullIndex;
    idx:indexedProperty [ idx:trackedProperty sc:name ] .
''';

        await _saveDocument(
            indexDocIri, IdxFullIndex.classIri, turtle.decode(indexDoc));

        // First call
        final properties1 = await resolveIndexedProperties(shardDocIri);
        expect(properties1, contains(IriTerm('http://schema.org/name')));

        // Second call - should hit cache and return same results
        final properties2 = await resolveIndexedProperties(shardDocIri);
        expect(properties2, contains(IriTerm('http://schema.org/name')));

        // Verify same results (cache is working if identical)
        expect(properties1, equals(properties2));
      });

      test('should respect cache size limit', () async {
        // Create resolver with cache size of 2
        final smallResolver =
            IndexPropertyResolver(storage: storage, cacheSize: 2);

        // Setup 3 different shards with indexes
        final shards = <IriTerm>[];
        for (var i = 0; i < 3; i++) {
          final shardDocIri = IriTerm('http://example.org/shard$i/doc');
          final indexDocIri = IriTerm('http://example.org/index$i');

          final shardDoc = '''
@base <http://example.org/shard$i/doc#> .
@prefix idx: <https://w3id.org/solid-crdt-sync/vocab/idx#> .

<#shard> a idx:Shard;
    idx:isShardOf <http://example.org/index$i#it> .
''';

          await _saveDocument(
              shardDocIri, IdxShard.classIri, turtle.decode(shardDoc));

          final indexDoc = '''
@base <http://example.org/index$i#> .
@prefix idx: <https://w3id.org/solid-crdt-sync/vocab/idx#> .

<#it> a idx:FullIndex .
''';

          await _saveDocument(
              indexDocIri, IdxFullIndex.classIri, turtle.decode(indexDoc));
          shards.add(shardDocIri);
        }

        // Resolve all 3 shards
        await smallResolver.resolveIndexedProperties(shards[0]);
        await smallResolver.resolveIndexedProperties(shards[1]);
        await smallResolver.resolveIndexedProperties(shards[2]);

        // Access shard 2 again - should hit cache
        final (_, props2Again) =
            await smallResolver.resolveIndexedProperties(shards[2]);
        expect(props2Again, isEmpty);

        // Access shard 0 again - should need to reload (was evicted from LRU cache)
        final (_, props0Again) =
            await smallResolver.resolveIndexedProperties(shards[0]);
        expect(props0Again, isEmpty);
      });

      test('should clear cache on demand', () async {
        final shardDocIri = IriTerm('http://example.org/shard/doc');
        final indexDocIri = IriTerm('http://example.org/index');

        // Setup: Shard document
        final shardDoc = '''
@base <http://example.org/shard/doc#> .
@prefix idx: <https://w3id.org/solid-crdt-sync/vocab/idx#> .

<#shard> a idx:Shard;
    idx:isShardOf <http://example.org/index#it> .
''';

        await _saveDocument(
            shardDocIri, IdxShard.classIri, turtle.decode(shardDoc));

        // Setup: Index document
        final indexDoc = '''
@base <http://example.org/index#> .
@prefix idx: <https://w3id.org/solid-crdt-sync/vocab/idx#> .

<#it> a idx:FullIndex .
''';

        await _saveDocument(
            indexDocIri, IdxFullIndex.classIri, turtle.decode(indexDoc));

        // First call
        await resolveIndexedProperties(shardDocIri);

        // Clear cache
        resolver.clearCache();

        // Second call after clear - should reload from storage
        final properties2 = await resolveIndexedProperties(shardDocIri);
        expect(properties2, isEmpty);
      });
    });

    group('GroupIndex Edge Cases', () {
      test('should handle GroupIndex without basedOn', () async {
        final shardDocIri = IriTerm('http://example.org/shard/doc');
        final groupIndexDocIri = IriTerm('http://example.org/group/index');

        // Setup: Shard document
        final shardDoc = '''
@base <http://example.org/shard/doc#> .
@prefix idx: <https://w3id.org/solid-crdt-sync/vocab/idx#> .

<#shard> a idx:Shard;
    idx:isShardOf <http://example.org/group/index#it> .
''';

        await _saveDocument(
            shardDocIri, IdxShard.classIri, turtle.decode(shardDoc));

        // Setup: GroupIndex without basedOn (malformed)
        final groupIndexDoc = '''
@base <http://example.org/group/index#> .
@prefix idx: <https://w3id.org/solid-crdt-sync/vocab/idx#> .

<#it> a idx:GroupIndex .
''';

        await _saveDocument(groupIndexDocIri, IdxGroupIndex.classIri,
            turtle.decode(groupIndexDoc));

        final properties = await resolveIndexedProperties(shardDocIri);

        // Should return empty set (no template to follow)
        expect(properties, isEmpty);
      });

      test('should handle missing template document', () async {
        final shardDocIri = IriTerm('http://example.org/shard/doc');
        final groupIndexDocIri = IriTerm('http://example.org/group/index');

        // Setup: Shard document
        final shardDoc = '''
@base <http://example.org/shard/doc#> .
@prefix idx: <https://w3id.org/solid-crdt-sync/vocab/idx#> .

<#shard> a idx:Shard;
    idx:isShardOf <http://example.org/group/index#it> .
''';

        await _saveDocument(
            shardDocIri, IdxShard.classIri, turtle.decode(shardDoc));

        // Setup: GroupIndex pointing to non-existent template
        final groupIndexDoc = '''
@base <http://example.org/group/index#> .
@prefix idx: <https://w3id.org/solid-crdt-sync/vocab/idx#> .

<#it> a idx:GroupIndex;
    idx:basedOn <http://example.org/template#it> .
''';

        await _saveDocument(groupIndexDocIri, IdxGroupIndex.classIri,
            turtle.decode(groupIndexDoc));

        // Template document not saved

        final properties = await resolveIndexedProperties(shardDocIri);

        // Should fall back to using GroupIndex (which has no properties)
        expect(properties, isEmpty);
      });
    });

    group('Complex Property Scenarios', () {
      test('should handle multiple indexed properties', () async {
        final shardDocIri = IriTerm('http://example.org/shard/doc');
        final indexDocIri = IriTerm('http://example.org/index');

        // Setup: Shard document
        final shardDoc = '''
@base <http://example.org/shard/doc#> .
@prefix idx: <https://w3id.org/solid-crdt-sync/vocab/idx#> .

<#shard> a idx:Shard;
    idx:isShardOf <http://example.org/index#it> .
''';

        await _saveDocument(
            shardDocIri, IdxShard.classIri, turtle.decode(shardDoc));

        // Setup: Index with multiple indexed properties
        final indexDoc = '''
@base <http://example.org/index#> .
@prefix idx: <https://w3id.org/solid-crdt-sync/vocab/idx#> .
@prefix sc: <http://schema.org/> .

<#it> a idx:FullIndex;
    idx:indexedProperty [ idx:trackedProperty sc:name ],
                        [ idx:trackedProperty sc:description ],
                        [ idx:trackedProperty sc:keywords ],
                        [ idx:trackedProperty sc:dateCreated ],
                        [ idx:trackedProperty sc:dateModified ] .
''';

        await _saveDocument(
            indexDocIri, IdxFullIndex.classIri, turtle.decode(indexDoc));

        final resolvedProperties = await resolveIndexedProperties(shardDocIri);

        expect(resolvedProperties, hasLength(5));
        expect(resolvedProperties, contains(IriTerm('http://schema.org/name')));
        expect(resolvedProperties,
            contains(IriTerm('http://schema.org/description')));
        expect(resolvedProperties,
            contains(IriTerm('http://schema.org/keywords')));
        expect(resolvedProperties,
            contains(IriTerm('http://schema.org/dateCreated')));
        expect(resolvedProperties,
            contains(IriTerm('http://schema.org/dateModified')));
      });

      test('should handle indexed property without trackedProperty', () async {
        final shardDocIri = IriTerm('http://example.org/shard/doc');
        final indexDocIri = IriTerm('http://example.org/index');

        // Setup: Shard document
        final shardDoc = '''
@base <http://example.org/shard/doc#> .
@prefix idx: <https://w3id.org/solid-crdt-sync/vocab/idx#> .

<#shard> a idx:Shard;
    idx:isShardOf <http://example.org/index#it> .
''';

        await _saveDocument(
            shardDocIri, IdxShard.classIri, turtle.decode(shardDoc));

        // Setup: Index with malformed indexed property (missing trackedProperty)
        final indexDoc = '''
@base <http://example.org/index#> .
@prefix idx: <https://w3id.org/solid-crdt-sync/vocab/idx#> .

<#it> a idx:FullIndex;
    idx:indexedProperty [ ] .
''';

        await _saveDocument(
            indexDocIri, IdxFullIndex.classIri, turtle.decode(indexDoc));

        final properties = await resolveIndexedProperties(shardDocIri);

        // Should skip malformed indexed property
        expect(properties, isEmpty);
      });

      test('should handle duplicate properties', () async {
        final shardDocIri = IriTerm('http://example.org/shard/doc');
        final indexDocIri = IriTerm('http://example.org/index');

        // Setup: Shard document
        final shardDoc = '''
@base <http://example.org/shard/doc#> .
@prefix idx: <https://w3id.org/solid-crdt-sync/vocab/idx#> .

<#shard> a idx:Shard;
    idx:isShardOf <http://example.org/index#it> .
''';

        await _saveDocument(
            shardDocIri, IdxShard.classIri, turtle.decode(shardDoc));

        // Setup: Index with same property listed twice (different blank nodes)
        final indexDoc = '''
@base <http://example.org/index#> .
@prefix idx: <https://w3id.org/solid-crdt-sync/vocab/idx#> .
@prefix sc: <http://schema.org/> .

<#it> a idx:FullIndex;
    idx:indexedProperty [ idx:trackedProperty sc:name ],
                        [ idx:trackedProperty sc:name ] .
''';

        await _saveDocument(
            indexDocIri, IdxFullIndex.classIri, turtle.decode(indexDoc));

        final resolvedProperties = await resolveIndexedProperties(shardDocIri);

        // Should deduplicate (Set semantics)
        expect(resolvedProperties, hasLength(1));
        expect(resolvedProperties, contains(IriTerm('http://schema.org/name')));
      });
    });
  });
}
