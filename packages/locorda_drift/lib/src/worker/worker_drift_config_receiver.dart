/// Worker-thread receiver for Drift storage settings.
library;

import 'dart:async';

import 'package:locorda_worker/worker.dart';
import 'package:logging/logging.dart';

import '../shared/drift_config_messages.dart';

final _log = Logger('WorkerDriftConfigReceiver');

/// Worker-side receiver for Drift storage settings.
class WorkerDriftConfigReceiver {
  final WorkerHandlerChannel _channel;
  final Completer<DriftSettingsMessage> _configCompleter = Completer();
  late final StreamSubscription<Object?> _subscription;

  WorkerDriftConfigReceiver(this._channel) {
    _subscription = _channel.messages
        .where((msg) => msg is Map<String, dynamic>)
        .cast<Map<String, dynamic>>()
        .listen(_handleMessage);
  }

  void _handleMessage(Map<String, dynamic> message) {
    final type = message['type'] as String?;
    if (type == 'DriftSettingsMessage') {
      final settings = DriftSettingsMessage.fromJson(message);
      _log.info('Received Drift settings from main thread '
          '(hasWebOptions: ${settings.webOptions != null}, '
          'deduplicateOnLoad: ${settings.deduplicateOnLoad})');
      if (!_configCompleter.isCompleted) {
        _configCompleter.complete(settings);
      }
    } else {
      _log.fine('Received unrecognized message type: $type');
    }
  }

  Future<DriftSettingsMessage> getConfig({
    Duration timeout = const Duration(seconds: 2),
  }) async {
    _log.info('Waiting for Drift settings from main thread '
        '(timeout: ${timeout.inSeconds}s)...');
    try {
      final settings = await _configCompleter.future.timeout(timeout);
      _log.info('Drift settings received successfully');
      return settings;
    } on TimeoutException {
      _log.warning('Timed out waiting for Drift settings from main thread. '
          'Continuing with defaults (native-only, no deduplication).');
      return DriftSettingsMessage(webOptions: null, deduplicateOnLoad: false);
    }
  }

  void dispose() {
    _subscription.cancel();
  }
}
