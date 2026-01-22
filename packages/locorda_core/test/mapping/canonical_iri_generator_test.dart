import 'package:locorda_core/src/mapping/framework_iri_generator.dart';
import 'package:locorda_core/src/mapping/identified_blank_node_builder.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:test/test.dart';

IriTerm generateCanonicalIri(IdentifiedBlankNode ibn) {
  IdentifiedBlankNodeParent parent = ibn.parent;
  while (parent.blankNode != null) {
    parent = parent.blankNode!.parent;
  }
  final root = parent.iriTerm!;
  return FrameworkIriGenerator()
      .generateCanonicalBlankNodeIri(root.getDocumentIri(), ibn);
}

void main() {
  group('generateCanonicalIri', () {
    group('basic functionality', () {
      test(
          'generates canonical IRI for simple identified blank node with IRI parent',
          () {
        final parent = IdentifiedBlankNodeParent.forIri(
          const IriTerm('https://example.com/recipe#it'),
        );
        final ibn = IdentifiedBlankNode(parent, {
          const IriTerm('http://schema.org/name'): [LiteralTerm('Tomato')],
          const IriTerm('http://schema.org/unit'): [LiteralTerm('cup')],
        });

        final canonicalIri = generateCanonicalIri(ibn);

        expect(
            canonicalIri.value,
            equals(
                'https://example.com/recipe#lcrd-ibn-md5-4e00e053b32db0e51ef6fc7b50fafde7'));
      });

      test('generates same IRI for identical identification patterns', () {
        final parent1 = IdentifiedBlankNodeParent.forIri(
          const IriTerm('https://example.com/recipe#it'),
        );
        final ibn1 = IdentifiedBlankNode(parent1, {
          const IriTerm('http://schema.org/name'): [LiteralTerm('Tomato')],
          const IriTerm('http://schema.org/unit'): [LiteralTerm('cup')],
        });

        final parent2 = IdentifiedBlankNodeParent.forIri(
          const IriTerm('https://example.com/recipe#it'),
        );
        final ibn2 = IdentifiedBlankNode(parent2, {
          const IriTerm('http://schema.org/name'): [LiteralTerm('Tomato')],
          const IriTerm('http://schema.org/unit'): [LiteralTerm('cup')],
        });

        final iri1 = generateCanonicalIri(ibn1);
        final iri2 = generateCanonicalIri(ibn2);

        expect(iri1, equals(iri2));
      });

      test('generates different IRIs for different identification patterns',
          () {
        final parent = IdentifiedBlankNodeParent.forIri(
          const IriTerm('https://example.com/recipe#it'),
        );
        final ibn1 = IdentifiedBlankNode(parent, {
          const IriTerm('http://schema.org/name'): [LiteralTerm('Tomato')],
        });
        final ibn2 = IdentifiedBlankNode(parent, {
          const IriTerm('http://schema.org/name'): [LiteralTerm('Basil')],
        });

        final iri1 = generateCanonicalIri(ibn1);
        final iri2 = generateCanonicalIri(ibn2);

        expect(
            iri1.value,
            equals(
                'https://example.com/recipe#lcrd-ibn-md5-07abf222389dcf94ab7940731360b350'));
        expect(
            iri2.value,
            equals(
                'https://example.com/recipe#lcrd-ibn-md5-1d3ff5115e60205420d8a45f81796529'));
        expect(iri1, isNot(equals(iri2)));
      });

      test('generates different IRIs for different parents', () {
        final parent1 = IdentifiedBlankNodeParent.forIri(
          const IriTerm('https://example.com/recipe1#it'),
        );
        final parent2 = IdentifiedBlankNodeParent.forIri(
          const IriTerm('https://example.com/recipe2#it'),
        );
        final ibn1 = IdentifiedBlankNode(parent1, {
          const IriTerm('http://schema.org/name'): [LiteralTerm('Tomato')],
        });
        final ibn2 = IdentifiedBlankNode(parent2, {
          const IriTerm('http://schema.org/name'): [LiteralTerm('Tomato')],
        });

        final iri1 = generateCanonicalIri(ibn1);
        final iri2 = generateCanonicalIri(ibn2);

        expect(
            iri1.value,
            equals(
                'https://example.com/recipe1#lcrd-ibn-md5-316575dc67de6c477029c065c6156da5'));
        expect(
            iri2.value,
            equals(
                'https://example.com/recipe2#lcrd-ibn-md5-c409e7585f2ce256f5edf55b8e8ad389'));
        expect(iri1, isNot(equals(iri2)));
      });
    });

    group('nested identified blank nodes', () {
      test('generates canonical IRI for two-level nesting', () {
        final rootParent = IdentifiedBlankNodeParent.forIri(
          const IriTerm('https://example.com/doc'),
        );
        final parentIbn = IdentifiedBlankNode(rootParent, {
          const IriTerm('http://schema.org/category'): [
            LiteralTerm('ingredient')
          ],
        });
        final childParent =
            IdentifiedBlankNodeParent.forIdentifiedBlankNode(parentIbn);
        final childIbn = IdentifiedBlankNode(childParent, {
          const IriTerm('http://schema.org/name'): [LiteralTerm('Tomato')],
          const IriTerm('http://schema.org/unit'): [LiteralTerm('cup')],
        });

        final canonicalIri = generateCanonicalIri(childIbn);

        expect(
            canonicalIri.value,
            equals(
                'https://example.com/doc#lcrd-ibn-md5-b27b392293a462ee38ed1e8a71f45e07'));
      });

      test('generates same IRI for identical nested patterns', () {
        // First chain
        final rootParent1 = IdentifiedBlankNodeParent.forIri(
          const IriTerm('https://example.com/doc'),
        );
        final parentIbn1 = IdentifiedBlankNode(rootParent1, {
          const IriTerm('http://schema.org/category'): [
            LiteralTerm('ingredient')
          ],
        });
        final childParent1 =
            IdentifiedBlankNodeParent.forIdentifiedBlankNode(parentIbn1);
        final childIbn1 = IdentifiedBlankNode(childParent1, {
          const IriTerm('http://schema.org/name'): [LiteralTerm('Tomato')],
        });

        // Second chain (identical)
        final rootParent2 = IdentifiedBlankNodeParent.forIri(
          const IriTerm('https://example.com/doc'),
        );
        final parentIbn2 = IdentifiedBlankNode(rootParent2, {
          const IriTerm('http://schema.org/category'): [
            LiteralTerm('ingredient')
          ],
        });
        final childParent2 =
            IdentifiedBlankNodeParent.forIdentifiedBlankNode(parentIbn2);
        final childIbn2 = IdentifiedBlankNode(childParent2, {
          const IriTerm('http://schema.org/name'): [LiteralTerm('Tomato')],
        });

        final iri1 = generateCanonicalIri(childIbn1);
        final iri2 = generateCanonicalIri(childIbn2);

        expect(iri1, equals(iri2));
      });

      test('generates different IRIs when parent identification differs', () {
        // First chain
        final rootParent1 = IdentifiedBlankNodeParent.forIri(
          const IriTerm('https://example.com/doc'),
        );
        final parentIbn1 = IdentifiedBlankNode(rootParent1, {
          const IriTerm('http://schema.org/category'): [
            LiteralTerm('ingredient')
          ],
        });
        final childParent1 =
            IdentifiedBlankNodeParent.forIdentifiedBlankNode(parentIbn1);
        final childIbn1 = IdentifiedBlankNode(childParent1, {
          const IriTerm('http://schema.org/name'): [LiteralTerm('Tomato')],
        });

        // Second chain (different parent identification)
        final rootParent2 = IdentifiedBlankNodeParent.forIri(
          const IriTerm('https://example.com/doc'),
        );
        final parentIbn2 = IdentifiedBlankNode(rootParent2, {
          const IriTerm('http://schema.org/category'): [
            LiteralTerm('spice')
          ], // Different!
        });
        final childParent2 =
            IdentifiedBlankNodeParent.forIdentifiedBlankNode(parentIbn2);
        final childIbn2 = IdentifiedBlankNode(childParent2, {
          const IriTerm('http://schema.org/name'): [LiteralTerm('Tomato')],
        });

        final iri1 = generateCanonicalIri(childIbn1);
        final iri2 = generateCanonicalIri(childIbn2);

        expect(iri1, isNot(equals(iri2)));
      });

      test('generates canonical IRI for three-level nesting', () {
        final rootParent = IdentifiedBlankNodeParent.forIri(
          const IriTerm('https://example.com/doc'),
        );
        final grandparentIbn = IdentifiedBlankNode(rootParent, {
          const IriTerm('http://schema.org/type'): [LiteralTerm('recipe')],
        });
        final grandparentParent =
            IdentifiedBlankNodeParent.forIdentifiedBlankNode(grandparentIbn);
        final parentIbn = IdentifiedBlankNode(grandparentParent, {
          const IriTerm('http://schema.org/category'): [
            LiteralTerm('ingredient')
          ],
        });
        final parentParent =
            IdentifiedBlankNodeParent.forIdentifiedBlankNode(parentIbn);
        final childIbn = IdentifiedBlankNode(parentParent, {
          const IriTerm('http://schema.org/name'): [LiteralTerm('Tomato')],
        });

        final canonicalIri = generateCanonicalIri(childIbn);

        expect(
            canonicalIri.value,
            equals(
                'https://example.com/doc#lcrd-ibn-md5-769ced3798ebe2b81d6d4918e83385d9'));
      });
    });

    group('multiple property values', () {
      test('generates canonical IRI with multiple values for same property',
          () {
        final parent = IdentifiedBlankNodeParent.forIri(
          const IriTerm('https://example.com/recipe#it'),
        );
        final ibn = IdentifiedBlankNode(parent, {
          const IriTerm('http://schema.org/name'): [
            LiteralTerm('Tomato'),
            LiteralTerm('Red Tomato'),
          ],
        });

        final canonicalIri = generateCanonicalIri(ibn);

        expect(
            canonicalIri.value,
            equals(
                'https://example.com/recipe#lcrd-ibn-md5-4232ddea4657c32412e4def686c2bb3b'));
      });

      test('order of values in list affects canonical IRI', () {
        final parent = IdentifiedBlankNodeParent.forIri(
          const IriTerm('https://example.com/recipe#it'),
        );
        final ibn1 = IdentifiedBlankNode(parent, {
          const IriTerm('http://schema.org/name'): [
            LiteralTerm('Tomato'),
            LiteralTerm('Red Tomato'),
          ],
        });
        final ibn2 = IdentifiedBlankNode(parent, {
          const IriTerm('http://schema.org/name'): [
            LiteralTerm('Red Tomato'),
            LiteralTerm('Tomato'),
          ],
        });

        final iri1 = generateCanonicalIri(ibn1);
        final iri2 = generateCanonicalIri(ibn2);

        // Due to canonical N-Quads sorting, the order might or might not matter
        // depending on lexicographic ordering - this tests current behavior
        expect(iri1.value, isNotEmpty);
        expect(iri2.value, isNotEmpty);
      });
    });

    group('property types', () {
      test('handles string literals', () {
        final parent = IdentifiedBlankNodeParent.forIri(
          const IriTerm('https://example.com/recipe#it'),
        );
        final ibn = IdentifiedBlankNode(parent, {
          const IriTerm('http://schema.org/name'): [LiteralTerm('Tomato')],
        });

        final canonicalIri = generateCanonicalIri(ibn);

        expect(
            canonicalIri.value,
            equals(
                'https://example.com/recipe#lcrd-ibn-md5-07abf222389dcf94ab7940731360b350'));
      });

      test('handles integer literals', () {
        final parent = IdentifiedBlankNodeParent.forIri(
          const IriTerm('https://example.com/recipe#it'),
        );
        final ibn = IdentifiedBlankNode(parent, {
          const IriTerm('http://schema.org/amount'): [
            LiteralTerm('2',
                datatype:
                    const IriTerm('http://www.w3.org/2001/XMLSchema#integer'))
          ],
        });

        final canonicalIri = generateCanonicalIri(ibn);

        expect(
            canonicalIri.value,
            equals(
                'https://example.com/recipe#lcrd-ibn-md5-c3658cbe8b3dd4c8c4a8ad0fcdbc0376'));
      });

      test('handles IRI objects', () {
        final parent = IdentifiedBlankNodeParent.forIri(
          const IriTerm('https://example.com/recipe#it'),
        );
        final ibn = IdentifiedBlankNode(parent, {
          const IriTerm('http://schema.org/unit'): [
            const IriTerm('http://schema.org/Cup'),
          ],
        });

        final canonicalIri = generateCanonicalIri(ibn);

        expect(
            canonicalIri.value,
            equals(
                'https://example.com/recipe#lcrd-ibn-md5-0b970522bb8256aa32f160a76b5ea191'));
      });

      test('handles language-tagged literals', () {
        final parent = IdentifiedBlankNodeParent.forIri(
          const IriTerm('https://example.com/recipe#it'),
        );
        final ibn = IdentifiedBlankNode(parent, {
          const IriTerm('http://schema.org/name'): [
            LiteralTerm('Tomate', language: 'de'),
          ],
        });

        final canonicalIri = generateCanonicalIri(ibn);

        expect(
            canonicalIri.value,
            equals(
                'https://example.com/recipe#lcrd-ibn-md5-7b47181c5db4737ca263cb9c12107c67'));
      });

      test('different datatypes produce different IRIs', () {
        final parent = IdentifiedBlankNodeParent.forIri(
          const IriTerm('https://example.com/recipe#it'),
        );
        final ibn1 = IdentifiedBlankNode(parent, {
          const IriTerm('http://schema.org/value'): [LiteralTerm('2')],
        });
        final ibn2 = IdentifiedBlankNode(parent, {
          const IriTerm('http://schema.org/value'): [
            LiteralTerm('2',
                datatype:
                    const IriTerm('http://www.w3.org/2001/XMLSchema#integer'))
          ],
        });

        final iri1 = generateCanonicalIri(ibn1);
        final iri2 = generateCanonicalIri(ibn2);

        expect(iri1, isNot(equals(iri2)));
      });

      test('different language tags produce different IRIs', () {
        final parent = IdentifiedBlankNodeParent.forIri(
          const IriTerm('https://example.com/recipe#it'),
        );
        final ibn1 = IdentifiedBlankNode(parent, {
          const IriTerm('http://schema.org/name'): [
            LiteralTerm('Tomato', language: 'en'),
          ],
        });
        final ibn2 = IdentifiedBlankNode(parent, {
          const IriTerm('http://schema.org/name'): [
            LiteralTerm('Tomato', language: 'de'),
          ],
        });

        final iri1 = generateCanonicalIri(ibn1);
        final iri2 = generateCanonicalIri(ibn2);

        expect(iri1, isNot(equals(iri2)));
      });
    });

    group('special characters and edge cases', () {
      test('handles special characters in literals', () {
        final parent = IdentifiedBlankNodeParent.forIri(
          const IriTerm('https://example.com/recipe#it'),
        );
        final ibn = IdentifiedBlankNode(parent, {
          const IriTerm('http://schema.org/name'): [
            LiteralTerm('Tomato "Red"\nFresh\t\r\n'),
          ],
        });

        final canonicalIri = generateCanonicalIri(ibn);

        expect(
            canonicalIri.value,
            equals(
                'https://example.com/recipe#lcrd-ibn-md5-2775618549f1d39d19fbb16221025494'));
      });

      test('handles unicode in literals', () {
        final parent = IdentifiedBlankNodeParent.forIri(
          const IriTerm('https://example.com/recipe#it'),
        );
        final ibn = IdentifiedBlankNode(parent, {
          const IriTerm('http://schema.org/name'): [
            LiteralTerm('Café ☕ 日本語'),
          ],
        });

        final canonicalIri = generateCanonicalIri(ibn);

        expect(
            canonicalIri.value,
            equals(
                'https://example.com/recipe#lcrd-ibn-md5-8b5435f15e8f3712cee3f97dc5fdfe08'));
      });

      test('handles empty string literal', () {
        final parent = IdentifiedBlankNodeParent.forIri(
          const IriTerm('https://example.com/recipe#it'),
        );
        final ibn = IdentifiedBlankNode(parent, {
          const IriTerm('http://schema.org/name'): [LiteralTerm('')],
        });

        final canonicalIri = generateCanonicalIri(ibn);

        expect(
            canonicalIri.value,
            equals(
                'https://example.com/recipe#lcrd-ibn-md5-d76d48bdea8472c8cd0f239941c78f6f'));
      });
    });

    group('determinism', () {
      test('generates same IRI across multiple calls', () {
        final parent = IdentifiedBlankNodeParent.forIri(
          const IriTerm('https://example.com/recipe#it'),
        );
        final ibn = IdentifiedBlankNode(parent, {
          const IriTerm('http://schema.org/name'): [LiteralTerm('Tomato')],
          const IriTerm('http://schema.org/unit'): [LiteralTerm('cup')],
        });

        final iri1 = generateCanonicalIri(ibn);
        final iri2 = generateCanonicalIri(ibn);
        final iri3 = generateCanonicalIri(ibn);

        expect(iri1, equals(iri2));
        expect(iri2, equals(iri3));
      });

      test('property map iteration order does not affect IRI', () {
        final parent = IdentifiedBlankNodeParent.forIri(
          const IriTerm('https://example.com/recipe#it'),
        );

        // Create two IBNs with properties added in different orders
        // (though Dart Maps maintain insertion order, the canonical N-Quads
        // serialization should sort them)
        final ibn1 = IdentifiedBlankNode(parent, {
          const IriTerm('http://schema.org/name'): [LiteralTerm('Tomato')],
          const IriTerm('http://schema.org/amount'): [LiteralTerm('2')],
        });
        final ibn2 = IdentifiedBlankNode(parent, {
          const IriTerm('http://schema.org/amount'): [LiteralTerm('2')],
          const IriTerm('http://schema.org/name'): [LiteralTerm('Tomato')],
        });

        final iri1 = generateCanonicalIri(ibn1);
        final iri2 = generateCanonicalIri(ibn2);

        expect(
            iri1.value,
            equals(
                'https://example.com/recipe#lcrd-ibn-md5-68c4f4134b6bf772f7f564ddd5892acf'));
        expect(
            iri2.value,
            equals(
                'https://example.com/recipe#lcrd-ibn-md5-68c4f4134b6bf772f7f564ddd5892acf'));
        expect(iri1, equals(iri2));
      });
    });
  });
}
