/// Stub for web worker entry point (used on non-web platforms).
library;

import 'package:locorda_worker/src/shared/worker_params.dart';
import 'package:logging/logging.dart';

final _log = Logger('web_worker_entry_point_stub');

/// Stub implementation that throws on non-web platforms.
void startWebWorkerLoop(WorkerSetup setupFn) {
  _log.info('In stub startWebWorkerLoop - throwing UnsupportedError');
  throw UnsupportedError('Web workers are only supported on web platform');
}
