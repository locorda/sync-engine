/// Main-thread sender for Drift web configuration.
library;

import 'package:locorda_worker/worker_main.dart';
import 'package:logging/logging.dart';

import '../drift_options.dart';
import '../shared/drift_config_messages.dart';

final _log = Logger('DriftConfigSender');

/// Main-thread plugin that sends Drift web options to the worker.
class DriftConfigSender implements MainHandler {
  final LocordaDriftWebOptions? _options;
  final MainHandlerChannel _workerHandle;

  DriftConfigSender({
    required LocordaDriftWebOptions? options,
    required MainHandlerChannel workerHandle,
  })  : _options = options,
        _workerHandle = workerHandle;

  @override
  Future<void> initialize() async {
    _log.fine('Sending Drift web options to worker');
    _workerHandle.send(DriftWebOptionsMessage(options: _options).toJson());
  }

  @override
  Future<void> dispose() async {
    // No cleanup needed
  }
}
