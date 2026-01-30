/// Main-thread sender for Google Drive authentication state.
///
/// Synchronizes authentication state from main thread to worker isolate.
library;

import 'package:locorda_gdrive/locorda_gdrive.dart';
import 'package:locorda_worker/worker_main.dart';
import 'package:logging/logging.dart';

import '../shared/gdrive_auth_messages.dart';

final _log = Logger('GDriveAuthSender');

/// Main-thread plugin that sends Google Drive auth updates to worker.
///
/// Listens to [GDriveAuth] authentication state changes and sends
/// credentials to the worker via [WorkerChannel].
class GDriveAuthSender implements MainHandler {
  final GDriveAuthProvider _authBridge;
  final MainHandlerChannel _workerHandle;

  GDriveAuthSender({
    required GDriveAuthProvider authBridge,
    required MainHandlerChannel workerHandle,
  })  : _authBridge = authBridge,
        _workerHandle = workerHandle;

  @override
  Future<void> initialize() async {
    // Listen to auth state changes
    _authBridge.isAuthenticatedNotifier.addListener(_onAuthChanged);

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
      final isAuth = await _authBridge.isAuthenticated();

      if (isAuth) {
        try {
          final accessToken = await _authBridge.getAccessToken();
          _workerHandle.send(UpdateAuthMessage(
            accessToken: accessToken,
            userId: _authBridge.userId,
            // TODO: Add token expiry time if available
          ).toJson());
        } catch (e) {
          // Scopes not authorized yet (e.g., after scope change) - send unauthenticated state
          _log.warning('Failed to get access token (scopes not authorized?), sending unauthenticated state: $e');
          _workerHandle.send(UpdateAuthMessage(
            accessToken: null,
            userId: null,
          ).toJson());
        }
      } else {
        _workerHandle.send(UpdateAuthMessage(
          accessToken: null,
          userId: null,
        ).toJson());
      }
    } catch (e, stackTrace) {
      _log.severe('Error sending auth update to worker', e, stackTrace);
      // Always send a message to prevent worker from hanging
      _workerHandle.send(UpdateAuthMessage(
        accessToken: null,
        userId: null,
      ).toJson());
    }
  }

  void _handleWorkerMessage(dynamic message) {
    if (message is! Map<String, dynamic>) return;

    final type = message['type'] as String?;
    switch (type) {
      case 'RequestAuthStateMessage':
        _log.fine('Worker requested auth state, sending update');
        _sendAuthUpdate();
      case 'TokenRefreshRequest':
        _handleTokenRefreshRequest(TokenRefreshRequest.fromJson(message));
    }
  }

  Future<void> _handleTokenRefreshRequest(TokenRefreshRequest request) async {
    _log.info('Worker requested token refresh: ${request.reason}');

    try {
      await _authBridge.refreshToken(reason: request.reason);
      final accessToken = await _authBridge.getAccessToken();

      _workerHandle.send(TokenRefreshResponse(
        requestId: request.requestId,
        accessToken: accessToken,
        // TODO: Add expiry time
      ).toJson());
    } catch (e, stackTrace) {
      _log.severe('Token refresh failed', e, stackTrace);
      _workerHandle.send(TokenRefreshResponse(
        requestId: request.requestId,
        error: e.toString(),
      ).toJson());
    }
  }

  @override
  Future<void> dispose() async {
    _authBridge.isAuthenticatedNotifier.removeListener(_onAuthChanged);
  }
}
