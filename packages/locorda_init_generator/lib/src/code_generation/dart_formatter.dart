import 'dart:io' show Platform;

import 'package:dart_style/dart_style.dart';
import 'package:logging/logging.dart';
import 'package:pub_semver/pub_semver.dart';

final _log = Logger('DartFormatter');

/// Extracts the language version from the current Dart SDK version.
/// Returns the major.minor version (e.g., "3.6" from "3.6.0").
Version _getCurrentLanguageVersion() {
  // Platform.version format: "3.10.0 (stable) (Thu Nov 6 05:24:55 2025 -0800) on \"macos_arm64\""
  final versionString = Platform.version.split(' ').first;
  final version = Version.parse(versionString);
  // Use major.minor only for language version, ignore patch
  return Version(version.major, version.minor, 0);
}

/// Interface for formatting Dart code.
abstract class CodeFormatter {
  /// Formats the given Dart code.
  ///
  /// Returns the formatted code on success, or the original unformatted code
  /// if formatting fails.
  String formatCode(String code);
}

/// Implementation of CodeFormatter using dart_style.
class DartCodeFormatter implements CodeFormatter {
  final DartFormatter _formatter;

  DartCodeFormatter({DartFormatter? formatter})
      : _formatter = formatter ??
            DartFormatter(
              languageVersion: _getCurrentLanguageVersion(),
            );

  @override
  String formatCode(String code) {
    try {
      return _formatter.format(code);
    } catch (e, stackTrace) {
      _log.warning(
        'Failed to format generated Dart code: $e',
        e,
        stackTrace,
      );
      // Return unformatted code as fallback to avoid build failures
      return code;
    }
  }
}

/// No-op formatter for testing or when formatting is disabled.
class NoOpCodeFormatter implements CodeFormatter {
  @override
  String formatCode(String code) => code;
}
