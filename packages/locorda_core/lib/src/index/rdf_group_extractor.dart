/// Extracts group identifiers from RDF terms using RegexTransform rules.
library;

import 'package:locorda_rdf_core/core.dart';
import 'index_config_base.dart';

/// Extracts group identifiers from RDF terms based on RegexTransform configuration.
///
/// This class applies regex transforms to RDF literal and IRI values according to
/// the REGEX-TRANSFORMS.md specification. It efficiently caches compiled regex
/// patterns to avoid recompilation on repeated use.
class RdfGroupExtractor {
  final List<RegexTransformData> _transforms;
  final List<RegExp> _compiledPatterns;

  /// Creates an extractor with the given transform rules.
  /// Compiles all regex patterns once during construction for efficiency.
  RdfGroupExtractor(List<RegexTransformData> transforms)
      : _transforms = List.unmodifiable(transforms),
        _compiledPatterns = transforms.map((t) => RegExp(t.pattern)).toList();

  /// Extracts a group key from an RDF term using the configured transforms.
  ///
  /// Returns the transformed value according to the first matching regex transform,
  /// or the original string value if no patterns match, or null if the term type
  /// is not supported.
  ///
  /// Processing rules per REGEX-TRANSFORMS.md:
  /// - LiteralTerm: Uses the literal's lexical value (ignoring datatype and language tag)
  /// - IriTerm: Uses the IRI string representation
  /// - BlankNodeTerm: Returns null (not supported per specification)
  String? extractGroupKey(RdfObject term) {
    final stringValue = _getStringValue(term);
    if (stringValue == null) {
      return null;
    }

    // Apply transforms in order - first match wins
    for (int i = 0; i < _compiledPatterns.length; i++) {
      final pattern = _compiledPatterns[i];
      final transform = _transforms[i];

      final match = pattern.firstMatch(stringValue);
      if (match != null) {
        return _applyReplacement(transform.replacement, match);
      }
    }

    // No patterns matched - use original value unchanged
    return stringValue;
  }

  /// Extracts string representation from RDF term according to specification.
  ///
  /// Returns null for BlankNodeTerm as per REGEX-TRANSFORMS.md specification.
  /// Blank nodes are explicitly not supported since they have no stable
  /// string representation suitable for grouping across distributed systems.
  String? _getStringValue(RdfObject term) => switch (term) {
        // Extract string content, ignoring datatypes and language tags
        LiteralTerm() => term.value,
        // Use IRI string representation
        IriTerm() => term.value,
        // Blank nodes not supported per specification - no stable string representation
        BlankNodeTerm() => null,
      };

  /// Applies replacement template with backreferences to matched groups.
  String _applyReplacement(String replacement, RegExpMatch match) {
    return replacement.replaceAllMapped(RegExp(r'\$\{(\d+)\}'), (replaceMatch) {
      final groupNumStr = replaceMatch.group(1)!;
      final groupNum = int.parse(groupNumStr);

      if (groupNum == 0) {
        // ${0} refers to entire matched string
        return match.group(0) ?? '';
      } else {
        // ${n} refers to capture group n
        return match.group(groupNum) ?? '';
      }
    }).replaceAll('\$\$', '\$'); // Handle literal $ as $$
  }
}
