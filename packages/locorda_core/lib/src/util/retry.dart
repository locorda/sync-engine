import 'package:locorda_core/locorda_core.dart';
import 'package:logging/logging.dart';

final Logger _log = Logger('RetryUtil');

Future<T> retryOnConflict<T>(Future<T> Function() operation,
    {int maxRetries = 3, String debugOperationName = '', Logger? log}) async {
  log ??= _log;

  for (var attempt = 0; attempt < maxRetries; attempt++) {
    try {
      return await operation();
    } on ConcurrentUpdateException catch (e, stackTrace) {
      log.warning(
          'Concurrent update detected while $debugOperationName: ${e.message}',
          e,
          stackTrace);
      if (attempt < maxRetries - 1) {
        log.warning(
            'Retrying $debugOperationName (attempt ${attempt + 1}/$maxRetries)...');
        await Future<void>.delayed(Duration(milliseconds: 10 * (attempt + 1)));
        continue;
      } else {
        log.severe(
            'Failed to $debugOperationName after $maxRetries attempts due to concurrent modifications.');
        throw StateError(
            'Could not $debugOperationName after $maxRetries attempts - concurrent modification conflict');
      }
    }
  }
  throw StateError('Unreachable'); // Should never reach here
}
