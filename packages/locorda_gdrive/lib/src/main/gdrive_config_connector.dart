/// Main-thread bridge for Google Drive configuration in worker architecture.
///
/// Synchronizes GDriveConfig from main thread to worker isolate.
library;

import 'package:locorda_worker/worker_main.dart';

import '../shared/gdrive_config.dart';
import 'gdrive_config_sender.dart';

/// Worker plugin that bridges Google Drive configuration from main thread to worker.
///
/// This connector sends [GDriveConfig] from main thread to worker on initialization,
/// ensuring both sides use the same storage mode and folder configuration.
///
/// ## Usage (Main Thread)
///
/// Register as plugin during sync system setup (handled automatically by [GDriveMainIntegration]):
///
/// ```dart
/// final config = GDriveConfig();
///
/// final sync = await Locorda.create(
///   remotes: [
///     GDriveMainIntegration(config: config),
///   ],
///   // ... other config
/// );
/// ```
///
/// ## Usage (Worker Thread)
///
/// Receive config in worker entry point (handled automatically by [GDriveWorkerHandler]):
///
/// ```dart
/// Future<WorkerParams> setupWorkerEngine() async => WorkerParams(
///   remotes: [
///     GDriveWorkerHandler(), // Config received automatically
///   ],
/// );
/// ```
class GDriveConfigConnector {
  /// Creates a plugin factory for this connector.
  ///
  /// Pass the main thread's [config] instance. The returned factory will be
  /// called by the worker framework with the [MainHandlerContext].
  static MainHandlerFactory sender(GDriveConfig config, String id) {
    return (MainHandlerContext context) {
      return GDriveConfigSender(
        config: config,
        workerHandle:
            context.createChannel('locorda_gdrive/${id}/gdrive_config'),
      );
    };
  }
}
