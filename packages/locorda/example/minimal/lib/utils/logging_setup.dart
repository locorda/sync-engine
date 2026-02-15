import 'package:logging/logging.dart';

void setupLogging({
  Level level = Level.INFO,
  String threadName = 'WORKER',
}) {
  Logger.root.level = level;
  Logger.root.onRecord.listen((record) {
    // Main log line
    // ignore: avoid_print
    print(
        '${record.time} ${record.level} [$threadName ${record.loggerName.padRight(20)}] ${record.message}');

    // Additional context if available
    if (record.error != null) {
      // ignore: avoid_print
      print('  ↳ Error: ${record.error}');
    }
    if (record.stackTrace != null) {
      // ignore: avoid_print
      print(
          '  ↳ Stack trace:\n${record.stackTrace.toString().split('\n').map((line) => '    $line').join('\n')}');
    }
  });
}
