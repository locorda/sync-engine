/// Console logging setup for the Personal Notes example app.
///
/// Provides beautiful, colored console output for development and debugging.
library;

import 'package:logging/logging.dart';

/// Configure console logging with sensible defaults.
///
/// This provides:
/// - Colored, formatted output
/// - Timestamp with milliseconds
/// - Aligned log levels
/// - Error and stack trace formatting
/// - Configurable log level
///
/// Example:
/// ```dart
/// void main() {
///   setupConsoleLogging(); // Default INFO level
///   runApp(MyApp());
/// }
/// ```
///
/// Custom configuration:
/// ```dart
/// void main() {
///   setupConsoleLogging(
///     level: Level.FINE,
///     timestampFormat: TimestampFormat.short,
///   );
///   runApp(MyApp());
/// }
/// ```
void _setupConsoleLogging({
  Level level = Level.INFO,
  TimestampFormat timestampFormat = TimestampFormat.full,
  LogFormat format = LogFormat.colored,
  String? threadName,
}) {
  Logger.root.level = level;
  Logger.root.onRecord.listen(
    _createLogHandler(
      timestampFormat: timestampFormat,
      format: format,
      threadName: threadName,
    ),
  );
}

/// Timestamp display format for log messages.
enum TimestampFormat {
  /// No timestamp
  none,

  /// Short format: HH:mm:ss
  short,

  /// Full format: HH:mm:ss.SSS (default)
  full,
}

/// Log output format style.
enum LogFormat {
  /// Colored ANSI output (default, best for development)
  colored,

  /// Plain text without colors (best for file logging)
  plain,
}

/// Internal: Create a log record handler with the specified formatting.
void Function(LogRecord) _createLogHandler({
  required TimestampFormat timestampFormat,
  required LogFormat format,
  String? threadName,
}) {
  return (record) {
    final time = _formatTime(record.time, timestampFormat, format);
    final level = _formatLevel(record.level, format);
    final logger = _formatLoggerName(
        (threadName == null ? '' : '$threadName:') + record.loggerName, format);
    final message = record.message;

    // Main log line
    // ignore: avoid_print
    print('$time $level $logger $message');

    // Additional context if available
    if (record.error != null) {
      final errorPrefix =
          format == LogFormat.colored ? '\x1B[91m' : ''; // Bright red
      final colorReset = format == LogFormat.colored ? '\x1B[0m' : '';
      // ignore: avoid_print
      print('  ↳ ${errorPrefix}Error:$colorReset ${record.error}');
    }
    if (record.stackTrace != null) {
      // ignore: avoid_print
      print('  ↳ Stack trace:\n${_indentStackTrace(record.stackTrace)}');
    }
  };
}

/// Format timestamp based on format preference.
String _formatTime(DateTime time, TimestampFormat format, LogFormat logFormat) {
  if (format == TimestampFormat.none) return '';

  final h = time.hour.toString().padLeft(2, '0');
  final m = time.minute.toString().padLeft(2, '0');
  final s = time.second.toString().padLeft(2, '0');

  final timeStr = format == TimestampFormat.full
      ? '$h:$m:$s.${time.millisecond.toString().padLeft(3, '0')}'
      : '$h:$m:$s';

  return logFormat == LogFormat.colored
      ? '\x1B[90m$timeStr\x1B[0m' // Dim gray
      : timeStr;
}

/// Format log level with optional color coding and fixed width for alignment.
String _formatLevel(Level level, LogFormat format) {
  final name = level.name.padRight(7); // Fixed width for alignment

  if (format == LogFormat.plain) return name;

  // Color coded by severity
  if (level >= Level.SEVERE) {
    return '\x1B[91m$name\x1B[0m'; // Bright red
  } else if (level >= Level.WARNING) {
    return '\x1B[93m$name\x1B[0m'; // Bright yellow
  } else if (level >= Level.INFO) {
    return '\x1B[94m$name\x1B[0m'; // Bright blue
  } else if (level >= Level.CONFIG) {
    return '\x1B[96m$name\x1B[0m'; // Bright cyan
  } else {
    return '\x1B[90m$name\x1B[0m'; // Dim gray for FINE/FINER/FINEST
  }
}

/// Format logger name with optional color and truncation for long names.
String _formatLoggerName(String loggerName, LogFormat format) {
  // Truncate very long logger names but keep last parts
  if (loggerName.length > 30) {
    final parts = loggerName.split('.');
    if (parts.length > 2) {
      loggerName = '…${parts.skip(parts.length - 2).join('.')}';
    } else {
      loggerName = '…${loggerName.substring(loggerName.length - 27)}';
    }
  }

  final formatted = '[${loggerName.padRight(30)}]';

  return format == LogFormat.colored
      ? '\x1B[36m$formatted\x1B[0m' // Cyan
      : formatted;
}

/// Indent stack trace lines for better visual hierarchy.
String _indentStackTrace(StackTrace? stackTrace) {
  if (stackTrace == null) return '';
  return stackTrace
      .toString()
      .split('\n')
      .map((line) => '    $line')
      .join('\n');
}

void setupMainLogging() {
  _setupConsoleLogging(level: Level.ALL, threadName: 'MAIN');
}

void setupWorkerLogging() {
  _setupConsoleLogging(level: Level.ALL, threadName: 'WORKER');
}
