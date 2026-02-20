/// Worker-thread receiver for Drift web configuration.
library;

import 'dart:async';

import 'package:locorda_worker/worker.dart';
import 'package:logging/logging.dart';

import '../drift_options.dart';
import '../shared/drift_config_messages.dart';

final _log = Logger('WorkerDriftConfigReceiver');

/// Worker-side receiver for Drift web options.
class WorkerDriftConfigReceiver {
  final WorkerHandlerChannel _channel;
  final Completer<LocordaDriftWebOptions?> _configCompleter = Completer();
  late final StreamSubscription _subscription;

  WorkerDriftConfigReceiver(this._channel) {
    _subscription = _channel.messages
        .where((msg) => msg is Map<String, dynamic>)
        .cast<Map<String, dynamic>>()
        .listen(_handleMessage);
  }

  void _handleMessage(Map<String, dynamic> message) {
    final type = message['type'] as String?;
    if (type == 'DriftWebOptionsMessage') {
      final configMsg = DriftWebOptionsMessage.fromJson(message);
      _log.info('Received Drift web options from main thread '
          '(hasOptions: ${configMsg.options != null})');
      if (!_configCompleter.isCompleted) {
        _configCompleter.complete(configMsg.options);
      }
    } else {
      _log.fine('Received unrecognized message type: $type');
    }
  }

  Future<LocordaDriftWebOptions?> getConfig({
    Duration timeout = const Duration(seconds: 2),
  }) async {
    _log.info('Waiting for Drift web options from main thread '
        '(timeout: ${timeout.inSeconds}s)...');
    try {
      final config = await _configCompleter.future.timeout(timeout);
      _log.info('Drift web options received successfully');
      return config;
    } on TimeoutException {
      _log.warning('Timed out waiting for Drift web options from main thread. '
          'Continuing without web options (native-only mode).');
      return null;
    }
  }

  void dispose() {
    _subscription.cancel();
  }
}
