/// Main-thread sender for local directory authentication state.
///
/// Synchronizes authentication state from main thread to worker isolate.
library;

import 'package:locorda_worker/worker_main.dart';
import 'package:logging/logging.dart';

import '../auth/dir_auth.dart';
import '../shared/dir_auth_messages.dart';

final _log = Logger('DirAuthSender');

/// Main-thread plugin that sends local directory auth updates to worker.
///
/// Listens to [DirAuth] authentication state changes and sends
/// enable/disable state to the worker via [WorkerChannel].
class DirAuthSender implements MainHandler {
  final DirAuth _dirAuth;
  final MainHandlerChannel _workerHandle;

  DirAuthSender({
    required DirAuth dirAuth,
    required MainHandlerChannel workerHandle,
  })  : _dirAuth = dirAuth,
        _workerHandle = workerHandle;

  @override
  Future<void> initialize() async {
    // Listen to auth state changes
    _dirAuth.isAuthenticatedNotifier.addListener(_onAuthChanged);

    // Send initial auth state
    await _sendAuthUpdate();

    // Listen for requests from worker
    _workerHandle.messages
        .where((msg) => msg is Map<String, dynamic>)
        .cast<Map<String, dynamic>>()
        .listen(_handleWorkerMessage);
  }

  void _onAuthChanged() {
    _log.fine('Auth state changed, sending update to worker');
    _sendAuthUpdate();
  }

  Future<void> _sendAuthUpdate() async {
    try {
      final isEnabled = await _dirAuth.isAuthenticated();

      _workerHandle.send(UpdateAuthMessage(
        enabled: isEnabled,
        syncDirectoryPath: _dirAuth.syncDirectoryPath,
      ).toJson());

      _log.fine('Sent auth update to worker: enabled=$isEnabled');
    } catch (e, stackTrace) {
      _log.severe('Error sending auth update to worker', e, stackTrace);
    }
  }

  void _handleWorkerMessage(Map<String, dynamic> message) {
    final type = message['type'] as String?;
    switch (type) {
      case 'RequestAuthStateMessage':
        _log.fine('Worker requested auth state, sending update');
        _sendAuthUpdate();
    }
  }

  @override
  Future<void> dispose() async {
    _dirAuth.isAuthenticatedNotifier.removeListener(_onAuthChanged);
  }
}
