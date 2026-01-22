import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:logging/logging.dart';
import 'package:locorda_rdf_core/core.dart';

/// Severity of an RDF structural expectation violation.
enum ExpectationSeverity {
  /// Minor: Can work around it with defaults (e.g., optional optimization hint).
  /// Logs info in both modes, never throws.
  minor,

  /// Major: Functionality significantly degraded (e.g., missing config parameter).
  /// Throws in strict mode, logs warning in lenient mode.
  major,

  /// Critical: Data is unusable without this (e.g., missing required key property).
  /// Always throws in strict mode, logs error in lenient mode.
  critical,
}

/// Manages RDF structural expectation validation behavior.
///
/// Controls how violations of RDF structural expectations are handled:
/// - Throw exceptions (strict) vs log warnings (lenient)
/// - Configurable threshold per severity level
/// - Testable and mockable
///
/// Example usage:
/// ```dart
/// // Default: strict for all levels
/// RdfExpectations.default.expectationFailed('Missing property', severity: ExpectationSeverity.major);
///
/// // Lenient mode: only throw on critical errors
/// final lenient = RdfExpectations(strictnessLevel: ExpectationSeverity.critical);
///
/// // Fully lenient: never throw, only log
/// final fullyLenient = RdfExpectations.lenient();
///
/// // For tests: temporarily override
/// RdfExpectations.runWith(
///   RdfExpectations.lenient(),
///   () => parseUntrustedData(),
/// );
/// ```
class RdfExpectations {
  static final Logger _log = Logger('RdfStructureExpectations');

  /// Minimum severity that triggers exceptions.
  /// - `null`: Never throw (fully lenient - always log only)
  /// - `ExpectationSeverity.minor`: Throw on all violations (fully strict)
  /// - `ExpectationSeverity.major`: Throw on major/critical (lenient for minor)
  /// - `ExpectationSeverity.critical`: Throw only on critical (lenient for minor/major)
  final ExpectationSeverity? strictnessLevel;

  const RdfExpectations({this.strictnessLevel = ExpectationSeverity.minor});

  /// Fully strict: throws on all violations (default for production)
  const RdfExpectations.strict() : strictnessLevel = ExpectationSeverity.minor;

  /// Fully lenient: never throws, only logs (useful for parsing untrusted data)
  const RdfExpectations.lenient() : strictnessLevel = null;

  /// Throw only on critical errors (useful for parsing semi-trusted data)
  const RdfExpectations.criticalOnly()
      : strictnessLevel = ExpectationSeverity.critical;

  /// Default instance used by global [expectationFailed] function
  static RdfExpectations _default = const RdfExpectations.strict();

  /// Get current default instance
  static RdfExpectations get defaultInstance => _default;

  /// Set default instance (useful for global configuration)
  static set defaultInstance(RdfExpectations instance) => _default = instance;

  /// Reports a violation of RDF structural expectations.
  ///
  /// Behavior depends on [severity] and [strictnessLevel]:
  /// - If severity >= strictnessLevel: throws [StateError]
  /// - Otherwise: logs at appropriate level (severe/warning/info)
  ///
  /// Used to document assumptions about RDF structure while allowing
  /// graceful degradation when working with real-world data.
  void expectationFailed(
    String message, {
    RdfSubject? subject,
    RdfPredicate? predicate,
    RdfGraph? graph,
    ExpectationSeverity severity = ExpectationSeverity.major,
  }) {
    final details = [
      if (subject != null)
        'Subject: ${switch (subject) {
          IriTerm iri => iri.debug,
          _ => subject.toString(),
        }}',
      if (predicate != null) 'Predicate: $predicate',
    ].join(', ');
    final prefix = switch (severity) {
      ExpectationSeverity.critical => '[CRITICAL]',
      ExpectationSeverity.major => '[MAJOR]',
      ExpectationSeverity.minor => '[MINOR]',
    };
    final fullMessage =
        '$prefix $message${details.isEmpty ? '' : ' ($details)'}';

    // Throw if severity meets or exceeds strictness threshold
    if (strictnessLevel != null && severity.index >= strictnessLevel!.index) {
      throw StateError(fullMessage);
    }

    // Always log (even if we also threw)
    switch (severity) {
      case ExpectationSeverity.critical:
        _log.severe(fullMessage);
      case ExpectationSeverity.major:
        _log.warning(fullMessage);
      case ExpectationSeverity.minor:
        _log.info(fullMessage);
    }
  }

  /// Temporarily run code with a different RdfExpectations instance.
  ///
  /// Useful for tests or parsing untrusted data:
  /// ```dart
  /// test('parses incomplete data gracefully', () {
  ///   RdfExpectations.runWith(
  ///     RdfExpectations.lenient(),
  ///     () {
  ///       final result = parseIncompleteRdf(...);
  ///       expect(result, isNotNull);
  ///     },
  ///   );
  /// });
  /// ```
  static T runWith<T>(RdfExpectations instance, T Function() body) {
    final previous = _default;
    try {
      _default = instance;
      return body();
    } finally {
      _default = previous;
    }
  }
}

/// Global convenience function using [RdfExpectations.defaultInstance].
///
/// For more control, create a custom [RdfExpectations] instance.
void expectationFailed(
  String message, {
  RdfSubject? subject,
  RdfPredicate? predicate,
  RdfGraph? graph,
  ExpectationSeverity severity = ExpectationSeverity.major,
}) {
  RdfExpectations.defaultInstance.expectationFailed(
    message,
    subject: subject,
    predicate: predicate,
    graph: graph,
    severity: severity,
  );
}
