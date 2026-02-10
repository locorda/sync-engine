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
      _log.fine('Received Drift web options from main thread');
      if (!_configCompleter.isCompleted) {
        _configCompleter.complete(configMsg.options);
      }
    }
  }

  Future<LocordaDriftWebOptions?> getConfig({
    Duration timeout = const Duration(seconds: 2),
  }) async {
    try {
      return await _configCompleter.future.timeout(timeout);
    } on TimeoutException {
      _log.warning('Timed out waiting for Drift web options from main thread.');
      return null;
    }
  }

  void dispose() {
    _subscription.cancel();
  }
}
