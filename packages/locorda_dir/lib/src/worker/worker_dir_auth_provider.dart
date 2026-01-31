/// Worker-side local directory authentication provider.
///
/// Receives authentication state from main thread and provides auth for file operations.
library;

import 'package:flutter/foundation.dart';
import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_worker/worker.dart';
import 'package:logging/logging.dart';

import '../auth/dir_auth_provider.dart';
import '../shared/dir_auth_messages.dart';

final _log = Logger('WorkerDirAuthProvider');

/// Notifier for worker authentication state changes.
class _WorkerAuthNotifier implements AuthValueListenable {
  final List<void Function()> _listeners = [];
  bool _isAuthenticated = false;

  @override
  bool get isAuthenticated => _isAuthenticated;

  set isAuthenticated(bool value) {
    if (_isAuthenticated != value) {
      _isAuthenticated = value;
      _notifyListeners();
    }
  }

  @override
  void addListener(void Function() listener) {
    _listeners.add(listener);
  }

  @override
  void removeListener(void Function() listener) {
    _listeners.remove(listener);
  }

  void _notifyListeners() {
    for (final listener in _listeners.toList()) {
      listener();
    }
  }
}

/// Local directory authentication provider for worker isolate/thread.
///
/// Receives enable/disable state from main thread via [WorkerChannel].
/// This architecture ensures:
///
/// - **State sync**: Auth state sent from main thread, used in worker
/// - **Backend control**: [isAuthenticatedNotifier] triggers backend initialization
///
/// ## Lifecycle
///
/// 1. Created via [DirAuthConnectorWorker.receiver] in worker entry point
/// 2. Listens to [WorkerChannel] for [UpdateAuthMessage]
/// 3. Updates internal enabled state
/// 4. Notifies listeners via [isAuthenticatedNotifier]
/// 5. [DirBackend] reacts by initializing/clearing remote storage
class WorkerDirAuthProvider implements DirAuthProvider {
  final WorkerHandlerChannel _channel;
  final _WorkerAuthNotifier _notifier = _WorkerAuthNotifier();
  final ValueNotifier<bool> _isAuthenticatedNotifier = ValueNotifier(false);

  bool _enabled = false;
  String _syncDirectoryPath = '';

  WorkerDirAuthProvider(this._channel) {
    // Listen for auth updates on channel
    _channel.messages.listen((message) {
      if (message is Map<String, dynamic>) {
        final type = message['type'] as String?;
        switch (type) {
          case 'UpdateAuthMessage':
            _handleAuthUpdate(UpdateAuthMessage.fromJson(message));
        }
      }
    });

    // Request initial auth state from main thread
    _channel.send(RequestAuthStateMessage().toJson());
  }

  void _handleAuthUpdate(UpdateAuthMessage message) {
    _log.fine('Received auth update: enabled=${message.enabled}');

    _enabled = message.enabled;
    _syncDirectoryPath = message.syncDirectoryPath;
    _notifier.isAuthenticated = _enabled;
    _isAuthenticatedNotifier.value = _enabled;

    _log.info(
        'Worker auth state updated: enabled=$_enabled, path=$_syncDirectoryPath');
  }

  /// Directory path where sync files are stored.
  String get syncDirectoryPath => _syncDirectoryPath;

  @override
  Future<bool> isAuthenticated() async => _enabled;

  @override
  AuthValueListenable get isAuthenticatedNotifier => _notifier;

  @override
  String? get userDisplayName => _enabled ? 'Local Directory' : null;

  @override
  Future<void> logout() async {
    // Logout not supported in worker - main thread controls auth
    throw UnimplementedError('Logout must be called from main thread');
  }
}
