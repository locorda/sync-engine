import 'package:locorda_core/src/config/sync_engine_config.dart';
import 'package:locorda_core/src/mapping/iri_translator.dart';
import 'package:locorda_core/src/mapping/resource_locator.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:test/test.dart';

void main() {
  group('DocumentIriTemplate', () {
    test('validates single {id} variable requirement', () {
      expect(() => DocumentIriTemplate.fromJson('https://example.com/{id}'),
          returnsNormally);

      expect(
          () => DocumentIriTemplate.fromJson('https://example.com/{foo}'),
          throwsA(isA<ArgumentError>().having((e) => e.message, 'message',
              contains('variable must be named "id"'))));

      expect(
          () => DocumentIriTemplate.fromJson('https://example.com/{id}/{name}'),
          throwsA(isA<ArgumentError>().having(
              (e) => e.message, 'message', contains('exactly one variable'))));

      expect(
          () => DocumentIriTemplate.fromJson('https://example.com/static'),
          throwsA(isA<ArgumentError>().having(
              (e) => e.message, 'message', contains('exactly one variable'))));
    });

    test('extracts prefix and suffix correctly', () {
      final template1 =
          DocumentIriTemplate.fromJson('https://example.com/items/{id}');
      expect(template1.prefix, equals('https://example.com/items/'));
      expect(template1.suffix, equals(''));

      final template2 =
          DocumentIriTemplate.fromJson('https://example.com/{id}/details');
      expect(template2.prefix, equals('https://example.com/'));
      expect(template2.suffix, equals('/details'));

      final template3 = DocumentIriTemplate.fromJson(
          'https://example.com/prefix-{id}-suffix');
      expect(template3.prefix, equals('https://example.com/prefix-'));
      expect(template3.suffix, equals('-suffix'));
    });

    test('toIri creates correct IRI with URL encoding', () {
      final template =
          DocumentIriTemplate.fromJson('https://example.com/categories/{id}');

      expect(template.toIri('work'),
          equals('https://example.com/categories/work'));
      expect(template.toIri('my work'),
          equals('https://example.com/categories/my%20work'));
      expect(template.toIri('unicode-café'),
          equals('https://example.com/categories/unicode-caf%C3%A9'));
      expect(template.toIri('unsafe:category'),
          equals('https://example.com/categories/unsafe%3Acategory'));
    });

    test('extractId extracts and URL decodes ID correctly', () {
      final template =
          DocumentIriTemplate.fromJson('https://example.com/categories/{id}');

      expect(template.extractId('https://example.com/categories/work'),
          equals('work'));
      expect(template.extractId('https://example.com/categories/my%20work'),
          equals('my work'));
      expect(
          template
              .extractId('https://example.com/categories/unicode-caf%C3%A9'),
          equals('unicode-café'));
      expect(
          template
              .extractId('https://example.com/categories/unsafe%3Acategory'),
          equals('unsafe:category'));

      // Non-matching IRIs should return null
      expect(template.extractId('https://other.com/categories/work'), isNull);
      expect(template.extractId('https://example.com/items/work'), isNull);
    });

    test('extractId handles suffix matching', () {
      final template = DocumentIriTemplate.fromJson(
          'https://example.com/items/{id}/details');

      expect(template.extractId('https://example.com/items/123/details'),
          equals('123'));
      expect(template.extractId('https://example.com/items/123'), isNull);
      expect(template.extractId('https://example.com/items/123/other'), isNull);
    });

    test('round-trip encoding/decoding', () {
      final template =
          DocumentIriTemplate.fromJson('https://example.com/items/{id}');

      for (final input in [
        'simple',
        'contains/slash',
        'unicode-café',
        'unsafe:category',
        '.',
        '.hidden'
      ]) {
        final iri = template.toIri(input);
        final extracted = template.extractId(iri);
        expect(extracted, equals(input),
            reason: 'Round-trip failed for: $input');
      }
    });
  });

  group('IriTranslator', () {
    late IriTranslator translator;
    late ResourceLocator resourceLocator;

    setUp(() {
      resourceLocator = LocalResourceLocator(iriTermFactory: IriTerm.validated);

      final categoryConfig = ResourceConfigData(
        typeIri:
            IriTerm('https://example.org/vocab/personal-notes#NotesCategory'),
        crdtMapping: Uri.parse('https://example.org/test/mappings/category-v1'),
        indices: [],
        documentIriTemplate: 'https://example.com/categories/{id}',
      );

      final noteConfig = ResourceConfigData(
        typeIri: IriTerm('https://example.org/vocab/personal-notes#Note'),
        crdtMapping: Uri.parse('https://example.org/test/mappings/note-v1'),
        indices: [],
        documentIriTemplate: 'https://example.com/notes/{id}',
      );

      translator = IriTranslator.forConfig(
        resourceLocator: resourceLocator,
        resourceConfigs: [categoryConfig, noteConfig],
      );
    });

    test('externalToInternal converts external IRI to internal', () {
      final external = IriTerm('https://example.com/categories/work#it');
      final internal = translator.externalToInternal(external);

      // Should be a LocalResourceLocator IRI
      expect(LocalResourceLocator.isLocalIri(internal), isTrue);

      // Should be able to extract back to 'work' id
      final typeIri =
          IriTerm('https://example.org/vocab/personal-notes#NotesCategory');
      final identifier =
          resourceLocator.fromIri(internal, expectedTypeIri: typeIri);
      expect(identifier.id, equals('work'));
      expect(identifier.fragment, equals('it'));
    });

    test('internalToExternal converts internal IRI to external', () {
      final typeIri =
          IriTerm('https://example.org/vocab/personal-notes#NotesCategory');
      final identifier = ResourceIdentifier(typeIri, 'work', 'it');
      final internal = resourceLocator.toIri(identifier);

      final external = translator.internalToExternal(internal);

      expect(external.value, equals('https://example.com/categories/work#it'));
    });

    test('round-trip translation preserves identity', () {
      final original = IriTerm('https://example.com/categories/my%20work#it');

      final internal = translator.externalToInternal(original);
      final backToExternal = translator.internalToExternal(internal);

      expect(backToExternal.value, equals(original.value));
    });

    test('non-matching IRI is returned unchanged', () {
      final unmanagedIri = IriTerm('https://other.com/unmanaged/resource#it');

      final result = translator.externalToInternal(unmanagedIri);
      expect(result, equals(unmanagedIri));
    });

    test('translateGraphToInternal translates all matching IRIs', () {
      final externalGraph = RdfGraph.fromTriples([
        Triple(
          IriTerm('https://example.com/categories/work#it'),
          IriTerm('http://www.w3.org/1999/02/22-rdf-syntax-ns#type'),
          IriTerm('https://example.org/vocab/personal-notes#NotesCategory'),
        ),
        Triple(
          IriTerm('https://example.com/categories/work#it'),
          IriTerm('http://schema.org/name'),
          LiteralTerm('Work'),
        ),
        Triple(
          IriTerm('https://example.com/categories/work#it'),
          IriTerm('https://example.org/vocab/personal-notes#relatedNote'),
          IriTerm('https://example.com/notes/note1#it'),
        ),
      ]);

      final internalGraph = translator.translateGraphToInternal(externalGraph);

      // All subjects and IRI objects should be internal now
      for (final triple in internalGraph.triples) {
        if (triple.subject is IriTerm) {
          final subject = triple.subject as IriTerm;
          if (subject.value.startsWith('https://example.com/categories/') ||
              subject.value.startsWith('https://example.com/notes/')) {
            expect(LocalResourceLocator.isLocalIri(subject), isTrue);
          }
        }
        if (triple.object is IriTerm) {
          final object = triple.object as IriTerm;
          if (object.value.startsWith('https://example.com/categories/') ||
              object.value.startsWith('https://example.com/notes/')) {
            expect(LocalResourceLocator.isLocalIri(object), isTrue);
          }
        }
      }
    });

    test('translateGraphToExternal translates all matching IRIs', () {
      // First create internal graph
      final externalGraph = RdfGraph.fromTriples([
        Triple(
          IriTerm('https://example.com/categories/work#it'),
          IriTerm('http://www.w3.org/1999/02/22-rdf-syntax-ns#type'),
          IriTerm('https://example.org/vocab/personal-notes#NotesCategory'),
        ),
      ]);

      final internalGraph = translator.translateGraphToInternal(externalGraph);
      final backToExternal = translator.translateGraphToExternal(internalGraph);

      // Should have one triple with external IRI
      expect(backToExternal.triples.length, equals(1));
      final triple = backToExternal.triples.first;
      expect((triple.subject as IriTerm).value,
          equals('https://example.com/categories/work#it'));
    });

    test('handles URL-encoded IDs in external IRIs', () {
      final external = IriTerm('https://example.com/categories/my%20work#it');
      final internal = translator.externalToInternal(external);

      // Extract the ID - should be decoded to 'my work'
      final typeIri =
          IriTerm('https://example.org/vocab/personal-notes#NotesCategory');
      final identifier =
          resourceLocator.fromIri(internal, expectedTypeIri: typeIri);
      expect(identifier.id, equals('my work'));

      // Translate back should preserve encoding
      final backToExternal = translator.internalToExternal(internal);
      expect(backToExternal.value,
          equals('https://example.com/categories/my%20work#it'));
    });

    test('no translation when no templates configured', () {
      final emptyTranslator = IriTranslator.forConfig(
        resourceLocator: resourceLocator,
        resourceConfigs: [
          ResourceConfigData(
            typeIri: IriTerm('https://example.org/Type'),
            crdtMapping: Uri.parse('https://example.org/mapping'),
            indices: [],
            // No documentIriTemplate
          ),
        ],
      );

      final iri = IriTerm('https://example.com/categories/work#it');
      final result = emptyTranslator.externalToInternal(iri);
      expect(result, equals(iri));

      final graph = RdfGraph.fromTriples([
        Triple(iri, IriTerm('http://schema.org/name'), LiteralTerm('Test'))
      ]);
      final resultGraph = emptyTranslator.translateGraphToInternal(graph);
      expect(resultGraph, equals(graph));
    });
  });
}
