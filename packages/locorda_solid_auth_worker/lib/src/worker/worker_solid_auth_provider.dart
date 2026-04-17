/// Worker-side Solid authentication provider.
///
/// Generates DPoP tokens locally in the worker using transmitted credentials.
/// This keeps DPoP key operations in the worker thread where HTTP requests happen.
library;

import 'dart:async';

import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_solid_core/locorda_solid_core.dart';
import 'package:locorda_worker/worker.dart';
import 'package:logging/logging.dart';
import 'package:solid_auth/worker.dart';

import '../shared/solid_auth_messages.dart';

final _log = Logger('SolidAuthReceiver');

String _credentialsFingerprint(DpopCredentials? credentials) {
  if (credentials == null) return 'none';
  final json = credentials.toJson();
  final sortedKeys = json.keys.toList()..sort();
  return 'keys=$sortedKeys hash=${json.toString().hashCode}';
}

/// Notifier for worker authentication state changes.
///
/// Implements [AuthValueListenable] to allow [SolidBackend] and other
/// components to subscribe to authentication state changes in the worker.
/// Updates are triggered when [UpdateAuthMessage] is received from main thread.
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

/// Solid authentication provider for worker isolate/thread.
///
/// Receives DPoP credentials from main thread via [WorkerChannel] and generates
/// DPoP tokens locally for each HTTP request. This architecture ensures:
///
/// - **Fresh tokens**: DPoP tokens generated immediately before each request
/// - **Security**: Private key operations stay in worker where HTTP happens
/// - **Performance**: No serialization overhead per request (credentials sent once)
/// - **State sync**: [isAuthenticatedNotifier] triggers backend initialization
///
/// ## Lifecycle
///
/// 1. Created via [SolidAuthConnector.receiver] in worker entry point
/// 2. Listens to [WorkerChannel] for [UpdateAuthMessage]
/// 3. Updates internal [_credentials] and [_webId]
/// 4. Notifies listeners via [isAuthenticatedNotifier]
/// 5. [SolidBackend] reacts by initializing remote storage
///
/// ## Usage
///
/// ```dart
/// void workerEntryPoint() {
///   startWorkerIsolate((context) async {
///     final authProvider = SolidAuthConnector.receiver(context);
///     final backend = SolidBackend(auth: authProvider);
///     // Backend now reacts to auth state changes automatically
///   });
/// }
/// ```
class SolidAuthReceiver implements SolidAuthProvider {
  final WorkerHandlerChannel _channel;
  final _WorkerAuthNotifier _notifier = _WorkerAuthNotifier();
  DpopCredentials? _credentials;
  String? _webId;

  /// Pending token refresh requests waiting for response from main thread.
  final Map<int, Completer<DpopCredentials>> _pendingRefreshRequests = {};
  int _nextRequestId = 0;

  /// Creates provider that listens to [channel] for authentication updates.
  ///
  /// Automatically subscribes to [UpdateAuthMessage] on the channel.
  /// Requests initial auth state from main thread using Request/Response pattern.
  SolidAuthReceiver(this._channel) {
    // Listen for auth updates on channel
    _channel.messages.listen((message) {
      if (message is Map<String, dynamic>) {
        final type = message['type'] as String?;
        switch (type) {
          case 'UpdateAuthMessage':
            _handleAuthUpdate(UpdateAuthMessage.fromJson(message));
          case 'TokenRefreshResponse':
            _handleTokenRefreshResponse(message);
        }
      }
    });

    // Request initial auth state from main thread
    _channel.send(RequestAuthStateMessage().toJson());
  }

  @override
  String? get userDisplayName => currentWebId;

  @override
  Future<void> logout() {
    // not needed in worker - main thread handles logout
    throw UnimplementedError();
  }

  /// Handles incoming auth updates from main thread.
  ///
  /// Updates stored credentials and notifies listeners.
  /// Also completes any pending token refresh requests.
  void _handleAuthUpdate(UpdateAuthMessage message) {
    final before = _credentialsFingerprint(_credentials);
    _credentials = message.credentials;
    _webId = message.webId;
    _notifier.isAuthenticated = _credentials != null;
    final after = _credentialsFingerprint(_credentials);
    _log.info('Received UpdateAuthMessage '
        '(webId=${message.webId}, isAuthenticated=${_credentials != null}, '
        'credentialsChanged=${before != after}, before=$before, after=$after)');

    // Complete pending refresh requests with new credentials
    if (_credentials != null) {
      _log.fine('Completing ${_pendingRefreshRequests.length} pending '
          'refresh request(s) from UpdateAuthMessage');
      for (final completer in _pendingRefreshRequests.values) {
        if (!completer.isCompleted) {
          completer.complete(_credentials);
        }
      }
      _pendingRefreshRequests.clear();
    }
  }

  /// Handles token refresh response from main thread.
  void _handleTokenRefreshResponse(Map<String, dynamic> message) {
    final requestId = message['requestId'] as int?;
    if (requestId == null) return;

    _log.info('Received TokenRefreshResponse (requestId=$requestId, '
        'hasCredentials=${message['credentials'] != null}, '
        'pending=${_pendingRefreshRequests.length})');

    final completer = _pendingRefreshRequests.remove(requestId);
    if (completer == null || completer.isCompleted) return;

    // Extract credentials from response
    final credentialsJson = message['credentials'] as Map<String, dynamic>?;
    if (credentialsJson != null) {
      final before = _credentialsFingerprint(_credentials);
      final credentials = DpopCredentials.fromJson(credentialsJson);
      _credentials = credentials;
      _notifier.isAuthenticated = true;
      final after = _credentialsFingerprint(_credentials);
      _log.info('Applied TokenRefreshResponse credentials '
          '(requestId=$requestId, credentialsChanged=${before != after}, '
          'before=$before, after=$after)');
      completer.complete(credentials);
    } else {
      _log.warning('TokenRefreshResponse has no credentials (requestId=$requestId)');
      completer.completeError(
        StateError('Token refresh failed: No credentials in response'),
      );
    }
  }

  /// Generates DPoP token for authenticated HTTP request.
  ///
  /// Creates a fresh DPoP proof token bound to the [url] and [method].
  /// Throws [StateError] if not authenticated (no credentials available).
  @override
  Future<({String accessToken, String dPoP})> getDpopToken(
      String url, String method) async {
    if (_credentials == null) {
      throw StateError('No authentication credentials available in worker');
    }

    final dpop = _credentials!.generateDpopToken(url: url, method: method);
    return (
      accessToken: dpop.accessToken,
      dPoP: dpop.dpopToken,
    );
  }

  /// Requests fresh credentials from main thread.
  ///
  /// Called by [SolidBackend] when HTTP request receives 401 Unauthorized.
  /// This indicates the access token has expired and needs refresh.
  ///
  /// Sends [RequestTokenRefreshMessage] and waits for response.
  /// Throws [TimeoutException] if no response within 10 seconds.
  Future<void> refreshToken({String? reason}) async {
    await _requestTokenRefresh(reason: reason);
  }

  /// Requests fresh token from main thread (internal).
  ///
  /// Sends [RequestTokenRefreshMessage] and waits for response.
  /// Throws [TimeoutException] if no response within 10 seconds.
  /// Updates internal credentials when response received.
  Future<void> _requestTokenRefresh({String? reason}) async {
    final requestId = _nextRequestId++;
    final completer = Completer<DpopCredentials>();
    _pendingRefreshRequests[requestId] = completer;
    final before = _credentialsFingerprint(_credentials);

    _log.info('Requesting token refresh '
        '(requestId=$requestId, reason=$reason, '
        'pending=${_pendingRefreshRequests.length}, credentials=$before)');

    // Send refresh request to main thread
    _channel.send({
      'type': 'RequestTokenRefresh',
      'requestId': requestId,
      if (reason != null) 'reason': reason,
    });

    // Wait for response with timeout
    try {
      await completer.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          _pendingRefreshRequests.remove(requestId);
          throw TimeoutException(
            'Token refresh request timed out after 10 seconds',
          );
        },
      );
      _log.info('Token refresh completed '
          '(requestId=$requestId, credentials=${_credentialsFingerprint(_credentials)})');
    } on Object catch (error, stackTrace) {
      _log.severe('Token refresh failed (requestId=$requestId): $error',
          error, stackTrace);
      rethrow;
    }
  }

  /// Current authenticated user's WebID.
  ///
  /// Returns `null` if not authenticated. Updated when [UpdateAuthMessage]
  /// is received from main thread.
  @override
  String? get currentWebId => _webId;

  /// Whether currently authenticated.
  ///
  /// Returns `true` if credentials are available, `false` otherwise.
  @override
  Future<bool> isAuthenticated() async => _credentials != null;

  /// Listenable for authentication state changes.
  ///
  /// [SolidBackend] subscribes to this to know when to initialize/clear remotes.
  /// Notifies listeners when [UpdateAuthMessage] updates credentials.
  @override
  AuthValueListenable get isAuthenticatedNotifier => _notifier;
}
