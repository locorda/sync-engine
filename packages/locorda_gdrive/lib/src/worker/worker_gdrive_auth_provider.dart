/// Worker-side Google Drive authentication provider.
///
/// Receives OAuth2 credentials from main thread and provides access tokens for HTTP requests.
library;

import 'dart:async';

import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_worker/worker.dart';
import 'package:logging/logging.dart';

import '../auth/gdrive_auth_provider.dart';
import '../shared/gdrive_auth_messages.dart';

final _log = Logger('WorkerGDriveAuthProvider');

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

/// Google Drive authentication provider for worker isolate/thread.
///
/// Receives OAuth2 credentials from main thread via [WorkerChannel] and provides
/// access tokens for HTTP requests. This architecture ensures:
///
/// - **Credential sync**: Credentials sent once, reused for multiple requests
/// - **Token refresh**: Worker can request token refresh from main thread
/// - **State management**: [isAuthenticatedNotifier] triggers backend initialization
///
/// ## Lifecycle
///
/// 1. Created via [GDriveAuthConnector.receiver] in worker entry point
/// 2. Listens to [WorkerChannel] for [UpdateAuthMessage]
/// 3. Updates internal credentials and user email
/// 4. Notifies listeners via [isAuthenticatedNotifier]
/// 5. [GDriveBackend] reacts by initializing remote storage
class WorkerGDriveAuthProvider implements GDriveAuthProvider {
  final WorkerChannel _channel;
  final _WorkerAuthNotifier _notifier = _WorkerAuthNotifier();

  String? _accessToken;
  String? _userEmail;
  DateTime? _expiresAt;

  /// Pending token refresh requests waiting for response from main thread.
  final Map<int, Completer<void>> _pendingRefreshRequests = {};
  int _nextRequestId = 0;

  WorkerGDriveAuthProvider(this._channel) {
    // Listen for auth updates on channel
    _channel.messages.listen((message) {
      if (message is Map<String, dynamic>) {
        final type = message['type'] as String?;
        switch (type) {
          case 'UpdateAuthMessage':
            _handleAuthUpdate(UpdateAuthMessage.fromJson(message));
          case 'TokenRefreshResponse':
            _handleTokenRefreshResponse(TokenRefreshResponse.fromJson(message));
        }
      }
    });

    // Request initial auth state from main thread
    _channel.send(RequestAuthStateMessage().toJson());
  }

  void _handleAuthUpdate(UpdateAuthMessage message) {
    _log.fine('Received auth update: userEmail=${message.userEmail}');

    _accessToken = message.accessToken;
    _userEmail = message.userEmail;
    _expiresAt = message.expiresAt;

    _notifier.isAuthenticated = _accessToken != null && _userEmail != null;

    // Complete pending refresh requests
    for (final completer in _pendingRefreshRequests.values) {
      if (!completer.isCompleted) {
        completer.complete();
      }
    }
    _pendingRefreshRequests.clear();
  }

  void _handleTokenRefreshResponse(TokenRefreshResponse message) {
    final completer = _pendingRefreshRequests.remove(message.requestId);
    if (completer == null || completer.isCompleted) return;

    if (message.error != null) {
      _log.severe('Token refresh failed: ${message.error}');
      completer
          .completeError(StateError('Token refresh failed: ${message.error}'));
      return;
    }

    _log.fine('Token refresh successful');
    _accessToken = message.accessToken;
    _expiresAt = message.expiresAt;
    completer.complete();
  }

  @override
  Future<bool> isAuthenticated() async => _notifier.isAuthenticated;

  @override
  AuthValueListenable get isAuthenticatedNotifier => _notifier;

  @override
  String? get userDisplayName => _userEmail;

  @override
  String? get userEmail => _userEmail;

  @override
  Future<String> getAccessToken() async {
    if (_accessToken == null) {
      throw StateError(
          'Not authenticated - no access token available in worker');
    }

    // Check if token needs refresh
    if (_expiresAt != null && DateTime.now().isAfter(_expiresAt!)) {
      _log.fine('Access token expired, requesting refresh...');
      await refreshToken(reason: 'Token expired');
    }

    return _accessToken!;
  }

  @override
  Future<void> refreshToken({String? reason}) async {
    _log.info('Requesting token refresh${reason != null ? ': $reason' : ''}');

    final requestId = _nextRequestId++;
    final completer = Completer<void>();
    _pendingRefreshRequests[requestId] = completer;

    _channel.send(TokenRefreshRequest(
      requestId: requestId,
      reason: reason,
    ).toJson());

    // Wait for response with timeout
    await completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        _pendingRefreshRequests.remove(requestId);
        throw TimeoutException(
            'Token refresh request timed out after 10 seconds');
      },
    );
  }

  @override
  Future<void> logout() {
    // Logout handled on main thread
    throw UnimplementedError('Logout should be called on main thread');
  }
}
