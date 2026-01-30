/// Worker-thread receiver for Google Drive configuration.
///
/// Receives GDriveConfig from main thread via worker channel.
library;

import 'dart:async';

import 'package:locorda_worker/worker.dart';
import 'package:logging/logging.dart';

import '../gdrive_type_index_manager.dart';
import '../shared/gdrive_config_messages.dart';

final _log = Logger('WorkerGDriveConfigReceiver');

/// Worker-side receiver for [GDriveConfig].
///
/// Listens to config messages from main thread and provides
/// the config to [GDriveBackend] via [getConfig].
class WorkerGDriveConfigReceiver {
  final WorkerHandlerChannel _channel;
  final Completer<GDriveConfig> _configCompleter = Completer();

  WorkerGDriveConfigReceiver(this._channel) {
    _channel.messages
        .where((msg) => msg is Map<String, dynamic>)
        .cast<Map<String, dynamic>>()
        .listen(_handleMessage);
  }

  void _handleMessage(Map<String, dynamic> message) {
    final type = message['type'] as String?;
    if (type == 'GDriveConfigMessage') {
      final configMsg = GDriveConfigMessage.fromJson(message);
      _log.fine('Received GDriveConfig: mode=${configMsg.config.folderMode}');
      if (!_configCompleter.isCompleted) {
        _configCompleter.complete(configMsg.config);
      }
    }
  }

  /// Returns the config once received from main thread.
  ///
  /// Waits for the initial config message if not yet received.
  Future<GDriveConfig> getConfig() => _configCompleter.future;
}
