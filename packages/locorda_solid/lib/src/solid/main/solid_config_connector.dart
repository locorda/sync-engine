/// Main-thread bridge for Solid configuration in worker architecture.
///
/// Synchronizes SolidConfig from main thread to worker isolate.
library;

import 'package:locorda_solid_core/locorda_solid_core.dart';
import 'package:locorda_worker/worker_main.dart';

import 'solid_config_sender.dart';

/// Worker plugin that bridges Solid configuration from main thread to worker.
class SolidConfigConnector {
  /// Creates a plugin factory for this connector.
  ///
  /// Pass the main thread's [config] instance. The returned factory will be
  /// called by the worker framework with the [MainHandlerContext].
  static MainHandlerFactory sender(SolidConfig config, String id) {
    return (MainHandlerContext context) {
      return SolidConfigSender(
        config: config,
        workerHandle: context.createChannel('locorda_solid/$id/solid_config'),
      );
    };
  }
}
