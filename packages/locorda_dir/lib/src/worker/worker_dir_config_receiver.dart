/// Worker-thread receiver for local directory configuration.
///
/// Receives [DirConfig] from main thread via worker channel.
library;

import 'dart:async';

import 'package:locorda_worker/worker.dart';
import 'package:logging/logging.dart';

import '../shared/dir_config.dart';
import '../shared/dir_config_messages.dart';

final _log = Logger('WorkerDirConfigReceiver');

/// Worker-side receiver for [DirConfig].
///
/// Listens to config messages from main thread and provides
/// the config to [DirBackend] via [getConfig].
class WorkerDirConfigReceiver {
  final WorkerHandlerChannel _channel;
  final Completer<DirConfig> _configCompleter = Completer();
  late final StreamSubscription _subscription;

  WorkerDirConfigReceiver(this._channel) {
    // Start listening IMMEDIATELY in constructor to catch early messages
    _subscription = _channel.messages
        .where((msg) => msg is Map<String, dynamic>)
        .cast<Map<String, dynamic>>()
        .listen(_handleMessage);
  }

  void _handleMessage(Map<String, dynamic> message) {
    final type = message['type'] as String?;
    if (type == 'DirConfigMessage') {
      final configMsg = DirConfigMessage.fromJson(message);
      _log.fine('Received DirConfig: '
          'layout=${configMsg.config.layout}');
      if (!_configCompleter.isCompleted) {
        _configCompleter.complete(configMsg.config);
      }
    }
  }

  /// Returns the config once received from main thread.
  ///
  /// Waits for the initial config message if not yet received.
  Future<DirConfig> getConfig() => _configCompleter.future;

  void dispose() {
    _subscription.cancel();
  }
}
