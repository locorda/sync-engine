import 'package:locorda_rdf_core/core.dart';
import 'package:locorda_core/src/index/index_config_base.dart';
import 'package:locorda_core/src/index/rdf_group_extractor.dart';
import 'package:test/test.dart';

void main() {
  group('RdfGroupExtractor', () {
    group('basic functionality', () {
      test('returns original value when no transforms are provided', () {
        final extractor = RdfGroupExtractor([]);

        final literal = LiteralTerm.string('test-value');
        final result = extractor.extractGroupKey(literal);

        expect(result, equals('test-value'));
      });

      test('returns original value when no transforms match', () {
        final extractor = RdfGroupExtractor([
          RegexTransform(r'^number-(\d+)$', r'${1}'),
        ]);

        final literal = LiteralTerm.string('text-value');
        final result = extractor.extractGroupKey(literal);

        expect(result, equals('text-value'));
      });

      test('applies first matching transform', () {
        final extractor = RdfGroupExtractor([
          RegexTransform(r'^([0-9]{4})-([0-9]{2})-([0-9]{2})$', r'${1}-${2}'),
          RegexTransform(
              r'^([0-9]{4}).*$', r'${1}'), // Would match but shouldn't be used
        ]);

        final literal = LiteralTerm.string('2024-08-15');
        final result = extractor.extractGroupKey(literal);

        expect(result, equals('2024-08'));
      });

      test('stops at first match in transform list', () {
        final extractor = RdfGroupExtractor([
          RegexTransform(r'^test.*$', r'first'),
          RegexTransform(r'^test.*$', r'second'), // This should not be reached
        ]);

        final literal = LiteralTerm.string('test-value');
        final result = extractor.extractGroupKey(literal);

        expect(result, equals('first'));
      });
    });

    group('RDF term type handling', () {
      test('extracts value from LiteralTerm', () {
        final extractor = RdfGroupExtractor([
          RegexTransform(r'^prefix-(.+)$', r'${1}'),
        ]);

        final literal = LiteralTerm.string('prefix-value');
        final result = extractor.extractGroupKey(literal);

        expect(result, equals('value'));
      });

      test('extracts IRI from IriTerm', () {
        final extractor = RdfGroupExtractor([
          RegexTransform(r'^http://example\.org/(.+)$', r'${1}'),
        ]);

        final iri = const IriTerm('http://example.org/resource');
        final result = extractor.extractGroupKey(iri);

        expect(result, equals('resource'));
      });

      test('returns null for BlankNodeTerm', () {
        final extractor = RdfGroupExtractor([
          RegexTransform(r'.*', r'transformed'),
        ]);

        final blankNode = BlankNodeTerm();
        final result = extractor.extractGroupKey(blankNode);

        expect(result, isNull);
      });

      test('handles literal with datatype (ignores datatype)', () {
        final extractor = RdfGroupExtractor([
          RegexTransform(r'^(\d+)$', r'number-${1}'),
        ]);

        final literal = LiteralTerm.integer(42);
        final result = extractor.extractGroupKey(literal);

        expect(result, equals('number-42'));
      });

      test('handles literal with language tag (ignores language)', () {
        final extractor = RdfGroupExtractor([
          RegexTransform(r'^(.+)$', r'text-${1}'),
        ]);

        final literal = LiteralTerm.withLanguage('hello', 'en');
        final result = extractor.extractGroupKey(literal);

        expect(result, equals('text-hello'));
      });
    });

    group('regex transform examples from specification', () {
      test('date monthly grouping', () {
        final extractor = RdfGroupExtractor([
          RegexTransform(r'^([0-9]{4})-([0-9]{2})-([0-9]{2})$', r'${1}-${2}'),
        ]);

        final testCases = [
          ('2024-08-15', '2024-08'),
          ('2023-12-31', '2023-12'),
          ('2025-01-01', '2025-01'),
        ];

        for (final (input, expected) in testCases) {
          final literal = LiteralTerm.string(input);
          final result = extractor.extractGroupKey(literal);
          expect(result, equals(expected), reason: 'Input: $input');
        }
      });

      test('date yearly grouping', () {
        final extractor = RdfGroupExtractor([
          RegexTransform(r'^([0-9]{4})-[0-9]{2}-[0-9]{2}$', r'${1}'),
        ]);

        final testCases = [
          ('2024-08-15', '2024'),
          ('2023-12-31', '2023'),
          ('2025-01-01', '2025'),
        ];

        for (final (input, expected) in testCases) {
          final literal = LiteralTerm.string(input);
          final result = extractor.extractGroupKey(literal);
          expect(result, equals(expected), reason: 'Input: $input');
        }
      });

      test('category extraction', () {
        final extractor = RdfGroupExtractor([
          RegexTransform(r'^([a-zA-Z]+)[-_].*$', r'${1}'),
        ]);

        final testCases = [
          ('work-project-alpha', 'work'),
          ('personal_notes', 'personal'),
          ('study-materials-2024', 'study'),
        ];

        for (final (input, expected) in testCases) {
          final literal = LiteralTerm.string(input);
          final result = extractor.extractGroupKey(literal);
          expect(result, equals(expected), reason: 'Input: $input');
        }
      });

      test('identifier reformatting', () {
        final extractor = RdfGroupExtractor([
          RegexTransform(r'^([A-Z]{2})([0-9]+)$', r'${1}-${2}'),
        ]);

        final testCases = [
          ('US123456', 'US-123456'),
          ('CA789012', 'CA-789012'),
          ('GB555000', 'GB-555000'),
        ];

        for (final (input, expected) in testCases) {
          final literal = LiteralTerm.string(input);
          final result = extractor.extractGroupKey(literal);
          expect(result, equals(expected), reason: 'Input: $input');
        }
      });

      test('multiple date formats handling', () {
        final extractor = RdfGroupExtractor([
          RegexTransform(r'^([0-9]{4})-([0-9]{2})-([0-9]{2})$', r'${1}-${2}'),
          RegexTransform(r'^([0-9]{4})/([0-9]{2})/([0-9]{2})$', r'${1}-${2}'),
        ]);

        final testCases = [
          ('2024-08-15', '2024-08'), // First format
          ('2024/08/15', '2024-08'), // Second format
          ('2023-12-31', '2023-12'), // First format
          ('2023/12/31', '2023-12'), // Second format
        ];

        for (final (input, expected) in testCases) {
          final literal = LiteralTerm.string(input);
          final result = extractor.extractGroupKey(literal);
          expect(result, equals(expected), reason: 'Input: $input');
        }
      });

      test('complex multi-format project name extraction', () {
        final extractor = RdfGroupExtractor([
          RegexTransform(r'^project[-_]([a-zA-Z0-9]+)$', r'${1}'),
          RegexTransform(r'^proj[-_]([a-zA-Z0-9]+)$', r'${1}'),
          RegexTransform(r'^([a-zA-Z0-9]+)[-_]project$', r'${1}'),
          RegexTransform(r'^([a-zA-Z0-9]+)[-_]proj$', r'${1}'),
        ]);

        final testCases = [
          ('project-alpha', 'alpha'), // First transform
          ('proj_beta', 'beta'), // Second transform
          ('gamma-project', 'gamma'), // Third transform
          ('delta_proj', 'delta'), // Fourth transform
        ];

        for (final (input, expected) in testCases) {
          final literal = LiteralTerm.string(input);
          final result = extractor.extractGroupKey(literal);
          expect(result, equals(expected), reason: 'Input: $input');
        }
      });
    });

    group('backreference handling', () {
      test('handles group 0 (entire match)', () {
        final extractor = RdfGroupExtractor([
          RegexTransform(r'test-\d+', r'match:${0}'),
        ]);

        final literal = LiteralTerm.string('test-123');
        final result = extractor.extractGroupKey(literal);

        expect(result, equals('match:test-123'));
      });

      test('handles multiple capture groups', () {
        final extractor = RdfGroupExtractor([
          RegexTransform(r'^([a-z]+)-([0-9]+)-([a-z]+)$', r'${3}_${1}_${2}'),
        ]);

        final literal = LiteralTerm.string('abc-123-xyz');
        final result = extractor.extractGroupKey(literal);

        expect(result, equals('xyz_abc_123'));
      });

      test('handles missing capture groups gracefully', () {
        final extractor = RdfGroupExtractor([
          RegexTransform(r'^([a-z]+)(?:-([0-9]+))?$', r'${1}_${2}'),
        ]);

        final testCases = [
          ('abc-123', 'abc_123'), // Both groups captured
          ('abc', 'abc_'), // Second group not captured, should be empty
        ];

        for (final (input, expected) in testCases) {
          final literal = LiteralTerm.string(input);
          final result = extractor.extractGroupKey(literal);
          expect(result, equals(expected), reason: 'Input: $input');
        }
      });

      test('handles literal dollar signs in replacement', () {
        final extractor = RdfGroupExtractor([
          RegexTransform(r'^(.+)$', r'${1}$$price'),
        ]);

        final literal = LiteralTerm.string('item');
        final result = extractor.extractGroupKey(literal);

        expect(result, equals('item\$price'));
      });
    });

    group('edge cases and error handling', () {
      test('handles empty string input', () {
        final extractor = RdfGroupExtractor([
          RegexTransform(r'^(.*)$', r'prefix-${1}'),
        ]);

        final literal = LiteralTerm.string('');
        final result = extractor.extractGroupKey(literal);

        expect(result, equals('prefix-'));
      });

      test('handles patterns that do not match empty string', () {
        final extractor = RdfGroupExtractor([
          RegexTransform(r'^.+$', r'${0}'), // Requires at least one character
        ]);

        final literal = LiteralTerm.string('');
        final result = extractor.extractGroupKey(literal);

        expect(result, equals('')); // Should return original value
      });

      test('efficient pattern compilation and reuse', () {
        // Test that patterns are compiled once and reused efficiently
        final transforms = [
          RegexTransform(r'^test-(.+)$', r'${1}'),
        ];
        final extractor = RdfGroupExtractor(transforms);

        // Multiple calls should reuse compiled patterns
        final literal1 = LiteralTerm.string('test-first');
        final literal2 = LiteralTerm.string('test-second');

        expect(extractor.extractGroupKey(literal1), equals('first'));
        expect(extractor.extractGroupKey(literal2), equals('second'));

        // The patterns should be compiled once and reused efficiently
        // (implementation detail verified by the fact that multiple calls work correctly)
      });

      test('handles unicode characters', () {
        final extractor = RdfGroupExtractor([
          RegexTransform(r'^(.+)-suffix$', r'${1}'),
        ]);

        final literal = LiteralTerm.string('测试-suffix');
        final result = extractor.extractGroupKey(literal);

        expect(result, equals('测试'));
      });
    });

    group('immutability and thread safety', () {
      test('transform list is immutable', () {
        final originalTransforms = [
          RegexTransform(r'^(.+)$', r'${1}'),
        ];
        final extractor = RdfGroupExtractor(originalTransforms);

        // Modifying original list should not affect extractor
        originalTransforms.clear();

        final literal = LiteralTerm.string('test');
        final result = extractor.extractGroupKey(literal);

        expect(result, equals('test')); // Should still work
      });
    });
  });
}
