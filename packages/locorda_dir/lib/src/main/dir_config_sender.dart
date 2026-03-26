/// Main-thread sender for local directory configuration.
///
/// Sends [DirConfig] from main thread to worker isolate on initialization.
library;

import 'package:locorda_worker/worker_main.dart';
import 'package:logging/logging.dart';

import '../shared/dir_config.dart';
import '../shared/dir_config_messages.dart';

final _log = Logger('DirConfigSender');

/// Main-thread plugin that sends local directory config to worker.
///
/// Sends [DirConfig] to the worker on initialization to ensure
/// both sides use the same configuration.
class DirConfigSender implements MainHandler {
  final DirConfig _config;
  final MainHandlerChannel _workerHandle;

  DirConfigSender({
    required DirConfig config,
    required MainHandlerChannel workerHandle,
  })  : _config = config,
        _workerHandle = workerHandle;

  @override
  Future<void> initialize() async {
    _log.fine('Sending DirConfig to worker: '
        'useShardDatasets=${_config.useShardDatasets}');
    _workerHandle.send(DirConfigMessage(config: _config).toJson());
  }

  @override
  Future<void> dispose() async {
    // No cleanup needed
  }
}
