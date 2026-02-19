import 'package:locorda_core/src/index/index_config_base.dart';
import 'package:locorda_core/src/index/regex_transform_validation.dart';
import 'package:test/test.dart';

void main() {
  group('RegexTransformValidator', () {
    group('pattern validation', () {
      test('accepts valid patterns from specification', () {
        // Test patterns with appropriate replacements that match capture groups
        final validTransforms = [
          (
            r'^([0-9]{4})-([0-9]{2})-([0-9]{2})$',
            r'${1}'
          ), // Date pattern with 1 capture group
          (
            r'^([a-zA-Z]+)[-_].*$',
            r'${1}'
          ), // Category extraction with 1 capture group
          (
            r'^([A-Z]{2})([0-9]+)$',
            r'${1}-${2}'
          ), // Identifier format with 2 capture groups
          (r'(group)', r'${1}'), // Capture group
          (
            r'[a-z]+',
            r'match'
          ), // Simple character class with literal replacement
          (
            r'[^abc]',
            r'found'
          ), // Negated character class with literal replacement
          (r'[0-9a-fA-F]+', r'hex'), // Combined ranges with literal replacement
          (r'.*', r'all'), // Any character with literal replacement
          (
            r'test+',
            r'tests'
          ), // One or more quantifier with literal replacement
          (
            r'test*',
            r'maybe'
          ), // Zero or more quantifier with literal replacement
          (
            r'test?',
            r'optional'
          ), // Zero or one quantifier with literal replacement
          (r'test{3}', r'exactly'), // Exact quantifier with literal replacement
          (r'test{2,5}', r'range'), // Range quantifier with literal replacement
          (
            r'test{2,}',
            r'many'
          ), // Open-ended quantifier with literal replacement
          (r'\.', r'dot'), // Escaped special character with literal replacement
        ];

        for (final (pattern, replacement) in validTransforms) {
          final transform = RegexTransformData(pattern, replacement);
          final result = RegexTransformValidator.validate(transform);
          expect(result.isValid, isTrue,
              reason: 'Transform should be valid: $pattern -> $replacement');
        }
      });

      test('rejects patterns with alternation', () {
        final invalidPatterns = [
          r'cat|dog',
          r'(cat|dog)',
          r'^(pattern1|pattern2)$',
        ];

        for (final pattern in invalidPatterns) {
          final transform = RegexTransformData(pattern, r'${1}');
          final result = RegexTransformValidator.validate(transform);
          expect(result.isValid, isFalse,
              reason: 'Pattern with alternation should be invalid: $pattern');
          expect(result.errors.any((e) => e.message.contains('alternation')),
              isTrue);
        }
      });

      test('rejects patterns with named character classes', () {
        final invalidPatterns = [
          r'[:alpha:]',
          r'[[:digit:]]+',
          r'[[:upper:][:lower:]]',
          r'[:alnum:]',
          r'[:punct:]',
          r'[:space:]',
          r'[:xdigit:]',
          r'[:blank:]',
          r'[:cntrl:]',
          r'[:graph:]',
          r'[:print:]',
        ];

        for (final pattern in invalidPatterns) {
          final transform = RegexTransformData(pattern, r'${1}');
          final result = RegexTransformValidator.validate(transform);
          expect(result.isValid, isFalse,
              reason:
                  'Pattern with named character class should be invalid: $pattern');
          expect(
              result.errors
                  .any((e) => e.message.contains('named character class')),
              isTrue);
        }
      });

      test('rejects invalid regex syntax', () {
        final invalidPatterns = [
          r'[',
          r'*',
          r'(',
          r'(?invalid)',
          r'{3,2}', // Invalid quantifier range
        ];

        for (final pattern in invalidPatterns) {
          final transform = RegexTransformData(pattern, r'${1}');
          final result = RegexTransformValidator.validate(transform);
          expect(result.isValid, isFalse,
              reason: 'Invalid regex syntax should be rejected: $pattern');
          // Some errors are caught by structural validation, others by regex compilation
          expect(result.errors.isNotEmpty, isTrue,
              reason: 'Should have errors for invalid pattern: $pattern');
        }
      });

      test('rejects empty patterns', () {
        final transform = RegexTransformData('', r'${1}');
        final result = RegexTransformValidator.validate(transform);
        expect(result.isValid, isFalse);
        expect(result.errors.any((e) => e.message.contains('cannot be empty')),
            isTrue);
      });

      test('warns about potentially non-portable escape sequences', () {
        final patterns = [
          r'\#', // Non-standard escape (not alphanumeric or special)
          r'\@', // Non-standard escape
        ];

        for (final pattern in patterns) {
          final transform = RegexTransformData(pattern, r'${1}');
          final result = RegexTransformValidator.validate(transform);
          expect(
              result.warnings
                  .any((w) => w.message.contains('may not be portable')),
              isTrue,
              reason: 'Pattern $pattern should generate portability warning');
        }
      });

      test('detects incomplete escape sequences', () {
        final transform = RegexTransformData(r'test\', r'${1}');
        final result = RegexTransformValidator.validate(transform);
        expect(result.isValid, isFalse);
        expect(
            result.errors
                .any((e) => e.message.contains('incomplete escape sequence')),
            isTrue);
      });
    });

    group('replacement validation', () {
      test('accepts valid replacement patterns', () {
        // Test replacements with patterns that have appropriate capture groups
        final validTransforms = [
          (r'(.+)', r'${1}'), // Pattern with 1 group, replacement uses group 1
          (r'(.+)', r'${0}'), // Group 0 is always valid (full match)
          (
            r'(.+)(.+)',
            r'${1}-${2}'
          ), // Pattern with 2 groups, replacement uses both
          (r'(.+)', r'prefix-${1}'), // Prefix with group reference
          (r'(.+)', r'${1}-suffix'), // Suffix with group reference
          (r'(.+)', r'$$'), // Literal dollar (no group reference needed)
          (r'(.+)(.+)', r'${1}$$${2}'), // Mixed with literal dollars
          (
            r'(.+)(.+)(.+)(.+)(.+)(.+)(.+)(.+)(.+)(.+)',
            r'${10}'
          ), // Double-digit groups
          (r'(.+)', r'${1}1'), // Group followed by literal digit
        ];

        for (final (pattern, replacement) in validTransforms) {
          final transform = RegexTransformData(pattern, replacement);
          final result = RegexTransformValidator.validate(transform);
          expect(result.isValid, isTrue,
              reason:
                  'Replacement should be valid: $replacement with pattern $pattern');
        }
      });

      test('rejects invalid dollar usage', () {
        final invalidReplacements = [
          r'$1', // Missing braces
          r'$hello', // Invalid syntax
          r'${1}$2', // Mixed syntax
        ];

        for (final replacement in invalidReplacements) {
          final transform = RegexTransformData(r'(.+)', replacement);
          final result = RegexTransformValidator.validate(transform);
          expect(result.isValid, isFalse,
              reason: 'Invalid dollar usage should be rejected: $replacement');
          expect(
              result.errors.any((e) => e.message.contains('invalid \$ usage')),
              isTrue);
        }
      });

      test('rejects empty braces', () {
        final transform = RegexTransformData(r'(.+)', r'${}');
        final result = RegexTransformValidator.validate(transform);
        expect(result.isValid, isFalse);
        expect(result.errors.any((e) => e.message.contains('empty braces')),
            isTrue);
      });

      test('rejects invalid backreferences', () {
        final invalidReplacements = [
          r'${abc}', // Non-numeric
          r'${1a}', // Mixed alphanumeric
        ];

        for (final replacement in invalidReplacements) {
          final transform = RegexTransformData(r'(.+)', replacement);
          final result = RegexTransformValidator.validate(transform);
          expect(result.isValid, isFalse,
              reason: 'Invalid backreference should be rejected: $replacement');
          expect(
              result.errors
                  .any((e) => e.message.contains('invalid backreference')),
              isTrue);
        }
      });

      test('rejects empty replacements', () {
        final transform = RegexTransformData(r'(.+)', '');
        final result = RegexTransformValidator.validate(transform);
        expect(result.isValid, isFalse);
        expect(result.errors.any((e) => e.message.contains('cannot be empty')),
            isTrue);
      });
    });

    group('list validation', () {
      test('validates multiple transforms', () {
        final transforms = [
          RegexTransformData(
              r'^([0-9]{4})-([0-9]{2})-([0-9]{2})$', r'${1}-${2}'),
          RegexTransformData(
              r'^([0-9]{4})/([0-9]{2})/([0-9]{2})$', r'${1}-${2}'),
        ];

        final result = RegexTransformValidator.validateList(transforms);
        expect(result.isValid, isTrue);
      });

      test('reports errors from all transforms', () {
        final transforms = [
          RegexTransformData(r'cat|dog', r'${1}'), // Invalid: alternation
          RegexTransformData(r'(.+)', r'$1'), // Invalid: replacement syntax
        ];

        final result = RegexTransformValidator.validateList(transforms);
        expect(result.isValid, isFalse);
        expect(
            result.errors.length,
            equals(
                3)); // 1 alternation error + 1 capture group error + 1 replacement syntax error
        expect(result.errors.any((e) => e.message.contains('alternation')),
            isTrue);
        expect(result.errors.any((e) => e.message.contains('invalid \$ usage')),
            isTrue);
      });

      test('handles empty list', () {
        final result = RegexTransformValidator.validateList([]);
        expect(result.isValid, isTrue);
        expect(result.errors.isEmpty, isTrue);
        expect(result.warnings.isEmpty, isTrue);
      });
    });

    group('real-world examples from specification', () {
      test('validates date transformation examples', () {
        final transforms = [
          // Monthly grouping
          RegexTransformData(
              r'^([0-9]{4})-([0-9]{2})-([0-9]{2})$', r'${1}-${2}'),
          // Yearly grouping
          RegexTransformData(r'^([0-9]{4})-[0-9]{2}-[0-9]{2}$', r'${1}'),
          // Multiple date formats
          RegexTransformData(
              r'^([0-9]{4})/([0-9]{2})/([0-9]{2})$', r'${1}-${2}'),
        ];

        for (final transform in transforms) {
          final result = RegexTransformValidator.validate(transform);
          expect(result.isValid, isTrue,
              reason: 'Date transform should be valid: ${transform.pattern}');
        }
      });

      test('validates string normalization examples', () {
        final transforms = [
          // Category extraction
          RegexTransformData(r'^([a-zA-Z]+)[-_].*$', r'${1}'),
          // Identifier reformatting
          RegexTransformData(r'^([A-Z]{2})([0-9]+)$', r'${1}-${2}'),
          // Project name extraction variants
          RegexTransformData(r'^project[-_]([a-zA-Z0-9]+)$', r'${1}'),
          RegexTransformData(r'^proj[-_]([a-zA-Z0-9]+)$', r'${1}'),
          RegexTransformData(r'^([a-zA-Z0-9]+)[-_]project$', r'${1}'),
          RegexTransformData(r'^([a-zA-Z0-9]+)[-_]proj$', r'${1}'),
        ];

        for (final transform in transforms) {
          final result = RegexTransformValidator.validate(transform);
          expect(result.isValid, isTrue,
              reason:
                  'String normalization transform should be valid: ${transform.pattern}');
        }
      });
    });
  });
}
