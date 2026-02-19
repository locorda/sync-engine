/// Validation for RegexTransform patterns and replacements according to REGEX-TRANSFORMS.md specification.
library;

import '../config/validation.dart';
import 'index_config_base.dart';

/// Validates RegexTransform objects according to the cross-platform compatible regex subset.
class RegexTransformValidator {
  // Pattern-based validation patterns
  static final RegExp _alternationPattern = RegExp(r'\|');
  static final RegExp _namedCharClassPattern = RegExp(r'\[:[a-z]+:\]');
  static final RegExp _anyBracePattern = RegExp(r'\$\{([^}]*)\}');
  static final RegExp _invalidDollarPattern = RegExp(r'\$(?!\{|\$|$)');
  static final RegExp _emptyBracesPattern = RegExp(r'\$\{\}');
  static final Set<String> _specialChars = {
    '.',
    '^',
    '\$',
    '[',
    ']',
    '(',
    ')',
    '{',
    '}',
    '*',
    '+',
    '?',
    '\\'
  };
  static final RegExp _alphanumPattern = RegExp(r'[a-zA-Z0-9]');

  /// Validates a single RegexTransform according to the specification
  static ValidationResult validate(RegexTransformData transform) {
    final result = ValidationResult();

    final captureGroupCount = _validatePattern(transform.pattern, result);
    _validateReplacement(transform.replacement, result, captureGroupCount);

    return result;
  }

  /// Validates a list of RegexTransforms
  static ValidationResult validateList(List<RegexTransformData> transforms) {
    final results = transforms.map(validate).toList();
    return ValidationResult.merge(results);
  }

  static int _validatePattern(String pattern, ValidationResult result) {
    if (pattern.isEmpty) {
      result.addError('RegexTransform pattern cannot be empty');
      return 0;
    }

    // Check for forbidden alternation using pattern matching
    if (_alternationPattern.hasMatch(pattern)) {
      result.addError(
        'RegexTransform pattern contains alternation (|) which is not supported in the cross-platform compatible subset. Use multiple transform rules instead.',
        details: pattern,
      );
    }

    // Check for forbidden named character classes using pattern matching
    final namedClassMatches = _namedCharClassPattern.allMatches(pattern);
    for (final match in namedClassMatches) {
      result.addError(
        'RegexTransform pattern contains named character class ${match.group(0)} which is not supported. Use explicit ranges like [a-zA-Z] or [0-9] instead.',
        details: pattern,
      );
    }

    // Check for proper escaping and structural issues first, and count capture groups
    final captureGroupCount = _validatePatternStructure(pattern, result);

    // Then validate that the pattern can be compiled as a regex if structure is OK
    if (result.errors.isEmpty) {
      try {
        RegExp(pattern);
      } catch (e) {
        result.addError(
          'RegexTransform pattern is not a valid regular expression: $e',
          details: pattern,
        );
      }
    }

    return captureGroupCount;
  }

  static void _validateReplacement(
      String replacement, ValidationResult result, int captureGroupCount) {
    if (replacement.isEmpty) {
      result.addError('RegexTransform replacement cannot be empty');
      return;
    }

    // Check for invalid dollar usage using pattern matching
    if (_invalidDollarPattern.hasMatch(replacement)) {
      result.addError(
        'RegexTransform replacement contains invalid \$ usage. Use \${n} for backreferences or \$\$ for literal \$ character.',
        details: replacement,
      );
    }

    // Check for empty braces using pattern matching
    if (_emptyBracesPattern.hasMatch(replacement)) {
      result.addError(
        'RegexTransform replacement contains empty braces \${} which is invalid.',
        details: replacement,
      );
    }

    // Validate all backreferences are valid numbers and exist in the pattern
    final anyBraceMatches = _anyBracePattern.allMatches(replacement);
    for (final match in anyBraceMatches) {
      final groupStr = match.group(1)!;
      // Check if it's empty braces (handled separately) or if it's not numeric
      if (groupStr.isNotEmpty && !RegExp(r'^\d+$').hasMatch(groupStr)) {
        result.addError(
          'RegexTransform replacement contains invalid backreference \${$groupStr}',
          details: replacement,
        );
      } else if (groupStr.isNotEmpty) {
        // Check if the group number exists in the pattern
        final groupNum = int.parse(groupStr);
        if (groupNum > captureGroupCount) {
          result.addError(
            'RegexTransform replacement references capture group \${$groupStr} but pattern only has $captureGroupCount capture groups',
            details: replacement,
          );
        }
      }
    }
  }

  static int _validatePatternStructure(
      String pattern, ValidationResult result) {
    // Validate escape sequences and bracket matching, and count capture groups
    var bracketDepth = 0;
    var parenDepth = 0;
    var braceDepth = 0;
    var inCharClass = false;
    var captureGroupCount = 0;

    for (int i = 0; i < pattern.length; i++) {
      final char = pattern[i];

      switch (char) {
        case '\\':
          // Handle escape sequences
          if (i + 1 >= pattern.length) {
            result.addError(
              'RegexTransform pattern ends with incomplete escape sequence',
              details: pattern,
            );
            return 0;
          }

          final nextChar = pattern[i + 1];
          // Only warn about truly non-portable sequences, not standard alphanumeric escapes
          if (!_specialChars.contains(nextChar) &&
              !_alphanumPattern.hasMatch(nextChar) &&
              !RegExp(r'[nrtfvab]').hasMatch(nextChar)) {
            result.addWarning(
              'RegexTransform pattern contains escape sequence \\$nextChar which may not be portable across all platforms',
              details: pattern,
            );
          }
          i++; // Skip the escaped character

        case '[':
          if (!inCharClass) {
            inCharClass = true;
            bracketDepth++;
          }

        case ']':
          if (inCharClass) {
            inCharClass = false;
            bracketDepth--;
          }

        case '(':
          if (!inCharClass) {
            parenDepth++;
            // Check if this is a capture group (not a non-capturing group)
            if (i + 2 < pattern.length &&
                pattern[i + 1] == '?' &&
                pattern[i + 2] == ':') {
              // This is a non-capturing group (?:...), don't count it
            } else {
              // This is a capturing group
              captureGroupCount++;
            }
          }

        case ')':
          if (!inCharClass) {
            parenDepth--;
            if (parenDepth < 0) {
              result.addError(
                'RegexTransform pattern contains unmatched closing parenthesis',
                details: pattern,
              );
              return 0;
            }
          }

        case '{':
          if (!inCharClass) braceDepth++;

        case '}':
          if (!inCharClass) {
            braceDepth--;
            if (braceDepth < 0) {
              result.addError(
                'RegexTransform pattern contains unmatched closing brace',
                details: pattern,
              );
              return 0;
            }
          }
      }
    }

    // Check for unmatched brackets
    if (bracketDepth > 0) {
      result.addError(
        'RegexTransform pattern contains unmatched opening bracket [',
        details: pattern,
      );
    }
    if (parenDepth > 0) {
      result.addError(
        'RegexTransform pattern contains unmatched opening parenthesis (',
        details: pattern,
      );
    }
    if (braceDepth > 0) {
      result.addError(
        'RegexTransform pattern contains unmatched opening brace {',
        details: pattern,
      );
    }

    return captureGroupCount;
  }
}
