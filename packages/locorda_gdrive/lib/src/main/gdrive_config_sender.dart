/// Main-thread sender for Google Drive configuration.
///
/// Sends GDriveConfig from main thread to worker isolate on initialization.
library;

import 'package:locorda_worker/worker_main.dart';
import 'package:logging/logging.dart';

import '../shared/gdrive_config.dart';
import '../shared/gdrive_config_messages.dart';

final _log = Logger('GDriveConfigSender');

/// Main-thread plugin that sends Google Drive config to worker.
///
/// Sends [GDriveConfig] to the worker on initialization to ensure
/// both sides use the same configuration.
class GDriveConfigSender implements MainHandler {
  final GDriveConfig _config;
  final MainHandlerChannel _workerHandle;

  GDriveConfigSender({
    required GDriveConfig config,
    required MainHandlerChannel workerHandle,
  })  : _config = config,
        _workerHandle = workerHandle;

  @override
  Future<void> initialize() async {
    _log.fine('Sending GDriveConfig to worker: mode=${_config.folderMode}');
    _workerHandle.send(GDriveConfigMessage(config: _config).toJson());
  }

  @override
  Future<void> dispose() async {
    // No cleanup needed
  }
}
