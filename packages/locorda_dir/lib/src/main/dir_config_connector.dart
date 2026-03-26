/// Main-thread bridge for local directory configuration in worker architecture.
///
/// Synchronizes [DirConfig] from main thread to worker isolate.
library;

import 'package:locorda_worker/worker_main.dart';

import '../shared/dir_config.dart';
import 'dir_config_sender.dart';

/// Worker plugin that bridges local directory configuration from main thread to worker.
///
/// Sends [DirConfig] from main thread to worker on initialization,
/// ensuring both sides use the same storage mode and format configuration.
class DirConfigConnector {
  /// Creates a plugin factory for this connector.
  ///
  /// Pass the main thread's [config] instance. The returned factory will be
  /// called by the worker framework with the [MainHandlerContext].
  static MainHandlerFactory sender(DirConfig config, String id) {
    return (MainHandlerContext context) {
      return DirConfigSender(
        config: config,
        workerHandle: context.createChannel('locorda_dir/$id/dir_config'),
      );
    };
  }
}
