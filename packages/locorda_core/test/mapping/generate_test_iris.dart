// ignore_for_file: avoid_print
import 'package:locorda_core/src/mapping/identified_blank_node_builder.dart';
import 'package:locorda_rdf_core/core.dart';

import 'canonical_iri_generator_test.dart' show generateCanonicalIri;

void main() {
  // Test 1: Simple identified blank node
  final parent1 = IdentifiedBlankNodeParent.forIri(
    const IriTerm('https://example.com/recipe#it'),
  );
  final ibn1 = IdentifiedBlankNode(parent1, {
    const IriTerm('http://schema.org/name'): [LiteralTerm('Tomato')],
    const IriTerm('http://schema.org/unit'): [LiteralTerm('cup')],
  });
  print(
      'Test 1 (simple with 2 properties): ${generateCanonicalIri(ibn1).value}');

  // Test 2: Different value
  final parent2 = IdentifiedBlankNodeParent.forIri(
    const IriTerm('https://example.com/recipe#it'),
  );
  final ibn2 = IdentifiedBlankNode(parent2, {
    const IriTerm('http://schema.org/name'): [LiteralTerm('Basil')],
  });
  print('Test 2 (different value): ${generateCanonicalIri(ibn2).value}');

  // Test 3: Different parent
  final parent3 = IdentifiedBlankNodeParent.forIri(
    const IriTerm('https://example.com/recipe1#it'),
  );
  final ibn3 = IdentifiedBlankNode(parent3, {
    const IriTerm('http://schema.org/name'): [LiteralTerm('Tomato')],
  });
  print('Test 3 (different parent): ${generateCanonicalIri(ibn3).value}');

  // Test 4: Two-level nesting
  final rootParent = IdentifiedBlankNodeParent.forIri(
    const IriTerm('https://example.com/doc'),
  );
  final parentIbn = IdentifiedBlankNode(rootParent, {
    const IriTerm('http://schema.org/category'): [LiteralTerm('ingredient')],
  });
  final childParent =
      IdentifiedBlankNodeParent.forIdentifiedBlankNode(parentIbn);
  final childIbn = IdentifiedBlankNode(childParent, {
    const IriTerm('http://schema.org/name'): [LiteralTerm('Tomato')],
  });
  print('Test 4 (two-level nesting): ${generateCanonicalIri(childIbn).value}');

  // Test 5: Multiple values
  final parent5 = IdentifiedBlankNodeParent.forIri(
    const IriTerm('https://example.com/recipe#it'),
  );
  final ibn5 = IdentifiedBlankNode(parent5, {
    const IriTerm('http://schema.org/name'): [
      LiteralTerm('Tomato'),
      LiteralTerm('Red Tomato'),
    ],
  });
  print('Test 5 (multiple values): ${generateCanonicalIri(ibn5).value}');

  // Test 6: IRI object
  final parent6 = IdentifiedBlankNodeParent.forIri(
    const IriTerm('https://example.com/recipe#it'),
  );
  final ibn6 = IdentifiedBlankNode(parent6, {
    const IriTerm('http://schema.org/unit'): [
      const IriTerm('http://schema.org/Cup'),
    ],
  });
  print('Test 6 (IRI object): ${generateCanonicalIri(ibn6).value}');

  // Test 7: Language-tagged literal
  final parent7 = IdentifiedBlankNodeParent.forIri(
    const IriTerm('https://example.com/recipe#it'),
  );
  final ibn7 = IdentifiedBlankNode(parent7, {
    const IriTerm('http://schema.org/name'): [
      LiteralTerm('Tomate', language: 'de'),
    ],
  });
  print('Test 7 (language-tagged): ${generateCanonicalIri(ibn7).value}');

  // Test 8: Integer datatype
  final parent8 = IdentifiedBlankNodeParent.forIri(
    const IriTerm('https://example.com/recipe#it'),
  );
  final ibn8 = IdentifiedBlankNode(parent8, {
    const IriTerm('http://schema.org/amount'): [
      LiteralTerm('2',
          datatype: const IriTerm('http://www.w3.org/2001/XMLSchema#integer'))
    ],
  });
  print('Test 8 (integer datatype): ${generateCanonicalIri(ibn8).value}');

  // Test 9: Property map order (should produce same result)
  final parent9a = IdentifiedBlankNodeParent.forIri(
    const IriTerm('https://example.com/recipe#it'),
  );
  final ibn9a = IdentifiedBlankNode(parent9a, {
    const IriTerm('http://schema.org/name'): [LiteralTerm('Tomato')],
    const IriTerm('http://schema.org/amount'): [LiteralTerm('2')],
  });
  final parent9b = IdentifiedBlankNodeParent.forIri(
    const IriTerm('https://example.com/recipe#it'),
  );
  final ibn9b = IdentifiedBlankNode(parent9b, {
    const IriTerm('http://schema.org/amount'): [LiteralTerm('2')],
    const IriTerm('http://schema.org/name'): [LiteralTerm('Tomato')],
  });
  print('Test 9a (property order test): ${generateCanonicalIri(ibn9a).value}');
  print('Test 9b (property order test): ${generateCanonicalIri(ibn9b).value}');
  print(
      'Test 9 match: ${generateCanonicalIri(ibn9a).value == generateCanonicalIri(ibn9b).value}');
}
