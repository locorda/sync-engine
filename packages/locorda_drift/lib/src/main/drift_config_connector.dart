/// Main-thread bridge for Drift web configuration in worker architecture.
library;

import 'package:locorda_worker/worker_main.dart';

import '../drift_options.dart';
import 'drift_config_sender.dart';

/// Worker plugin that bridges Drift web options from main thread to worker.
class DriftConfigConnector {
  /// Creates a plugin factory for this connector.
  ///
  /// Pass the main thread's [options] instance. The returned factory will be
  /// called by the worker framework with the [MainHandlerContext].
  static MainHandlerFactory sender(LocordaDriftWebOptions? options, String id) {
    return (MainHandlerContext context) {
      return DriftConfigSender(
        options: options,
        workerHandle: context.createChannel('locorda_drift/$id/drift_config'),
      );
    };
  }
}
