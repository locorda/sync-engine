/// Main-thread sender for Drift storage settings.
library;

import 'package:locorda_worker/worker_main.dart';
import 'package:logging/logging.dart';

import '../drift_options.dart';
import '../shared/drift_config_messages.dart';

final _log = Logger('DriftConfigSender');

/// Main-thread plugin that sends Drift storage settings to the worker.
class DriftConfigSender implements MainHandler {
  final LocordaDriftOptions _options;
  final MainHandlerChannel _workerHandle;

  DriftConfigSender({
    required LocordaDriftOptions options,
    required MainHandlerChannel workerHandle,
  })  : _options = options,
        _workerHandle = workerHandle;

  @override
  Future<void> initialize() async {
    _log.info('Sending Drift settings to worker '
        '(hasWebOptions: ${_options.web != null}, '
        'deduplicateOnLoad: ${_options.deduplicateOnLoad})');
    _workerHandle.send(DriftSettingsMessage(
      webOptions: _options.web,
      deduplicateOnLoad: _options.deduplicateOnLoad,
    ).toJson());
    _log.fine('Drift settings sent');
  }

  @override
  Future<void> dispose() async {
    // No cleanup needed
  }
}
