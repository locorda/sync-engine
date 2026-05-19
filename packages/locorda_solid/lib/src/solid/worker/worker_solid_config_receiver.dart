/// Worker-thread receiver for Solid configuration.
///
/// Receives SolidConfig from main thread via worker channel.
library;

import 'dart:async';

import 'package:locorda_solid_core/locorda_solid_core.dart';
import 'package:locorda_worker/worker.dart';
import 'package:logging/logging.dart';

import '../shared/solid_config_messages.dart';

final _log = Logger('WorkerSolidConfigReceiver');

/// Worker-side receiver for [SolidConfig].
class WorkerSolidConfigReceiver {
  final WorkerHandlerChannel _channel;
  final Completer<SolidConfig> _configCompleter = Completer();
  late final StreamSubscription<Object?> _subscription;

  WorkerSolidConfigReceiver(this._channel) {
    _subscription = _channel.messages
        .where((msg) => msg is Map<String, dynamic>)
        .cast<Map<String, dynamic>>()
        .listen(_handleMessage);
  }

  void _handleMessage(Map<String, dynamic> message) {
    final type = message['type'] as String?;
    if (type == 'SolidConfigMessage') {
      final configMsg = SolidConfigMessage.fromJson(message);
      _log.fine('Received SolidConfig from main thread');
      if (!_configCompleter.isCompleted) {
        _configCompleter.complete(configMsg.config);
      }
    }
  }

  /// Returns the config once received from main thread.
  Future<SolidConfig> getConfig() => _configCompleter.future;

  void dispose() {
    _subscription.cancel();
  }
}
