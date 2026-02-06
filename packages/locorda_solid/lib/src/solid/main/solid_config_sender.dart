/// Main-thread sender for Solid configuration.
///
/// Sends SolidConfig from main thread to worker isolate on initialization.
library;

import 'package:locorda_worker/worker_main.dart';
import 'package:logging/logging.dart';

import '../shared/solid_config_messages.dart';
import 'package:locorda_solid_core/locorda_solid_core.dart';

final _log = Logger('SolidConfigSender');

/// Main-thread plugin that sends Solid config to worker.
class SolidConfigSender implements MainHandler {
  final SolidConfig _config;
  final MainHandlerChannel _workerHandle;

  SolidConfigSender({
    required SolidConfig config,
    required MainHandlerChannel workerHandle,
  })  : _config = config,
        _workerHandle = workerHandle;

  @override
  Future<void> initialize() async {
    _log.fine('Sending SolidConfig to worker');
    _workerHandle.send(SolidConfigMessage(config: _config).toJson());
  }

  @override
  Future<void> dispose() async {
    // No cleanup needed
  }
}
