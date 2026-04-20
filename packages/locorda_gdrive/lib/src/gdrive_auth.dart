/// Google Drive authentication bridge using google_sign_in.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:locorda_core/locorda_core.dart';
import 'package:logging/logging.dart';

import 'auth/gdrive_auth_provider.dart';

final _log = Logger('GDriveAuth');

@visibleForTesting
bool shouldBlockScopeAuthorization({
  required bool allowUserInteraction,
  required bool requiresUserInteraction,
}) {
  return !allowUserInteraction && requiresUserInteraction;
}

/// ValueListenable implementation for authentication state.
class AuthValueListenableImpl implements AuthValueListenable {
  final ValueNotifier<bool> _notifier;

  AuthValueListenableImpl(this._notifier);

  @override
  bool get isAuthenticated => _notifier.value;

  @override
  void addListener(void Function() listener) {
    _notifier.addListener(listener);
  }

  @override
  void removeListener(void Function() listener) {
    _notifier.removeListener(listener);
  }
}

/// Main thread implementation of Google Drive authentication.
///
/// Uses `google_sign_in` package for OAuth2 flow and token management.
/// Provides the Auth interface for use in the locorda framework.
class GDriveAuth implements GDriveAuthProvider {
  final List<String> scopes;
  late final GoogleSignIn _googleSignIn;

  GoogleSignInAccount? _currentUser;
  final ValueNotifier<bool> _isAuthenticatedNotifier = ValueNotifier(false);
  late final AuthValueListenableImpl _authListenable;
  StreamSubscription<GoogleSignInAuthenticationEvent>? _authEventsSubscription;

  GDriveAuth._({
    required String? clientId,
    required this.scopes,
  }) {
    _authListenable = AuthValueListenableImpl(_isAuthenticatedNotifier);
    _googleSignIn = GoogleSignIn.instance;

    // Listen to sign-in state changes
    _authEventsSubscription =
        _googleSignIn.authenticationEvents.listen((event) {
      if (event is GoogleSignInAuthenticationEventSignIn) {
        _currentUser = event.user;
        _isAuthenticatedNotifier.value = true;
        _log.info('User signed in: ${event.user.id}');
      } else if (event is GoogleSignInAuthenticationEventSignOut) {
        _currentUser = null;
        _isAuthenticatedNotifier.value = false;
        _log.info('User signed out');
      }
    });
  }

  void _markUserInteractionRequired(String message) {
    _log.warning(message);
    _isAuthenticatedNotifier.value = false;
  }

  Future<GoogleSignInClientAuthorization> _authorizeScopes({
    required bool allowUserInteraction,
  }) async {
    final authClient = _googleSignIn.authorizationClient;
    final existing = await authClient.authorizationForScopes(scopes);
    if (existing != null) {
      return existing;
    }

    if (shouldBlockScopeAuthorization(
      allowUserInteraction: allowUserInteraction,
      requiresUserInteraction:
          _googleSignIn.authorizationRequiresUserInteraction(),
    )) {
      _markUserInteractionRequired(
        'Authorization required. Show the Google sign-in button.',
      );
      throw GDriveUserInteractionRequired(
          'Authorization required. Show the Google sign-in button.');
    }

    return authClient.authorizeScopes(scopes);
  }

  /// Creates and initializes Google Drive authentication.
  ///
  /// Attempts silent sign-in for returning users automatically.
  ///
  /// Parameters:
  /// - [clientId]: Optional OAuth2 client ID. If not provided, will be read from
  ///   platform-specific configuration files (Info.plist on iOS, google-services.json
  ///   on Android, meta tag on Web).
  /// - [scopes]: OAuth2 scopes to request. Defaults to Drive file access + OpenID.
  static Future<GDriveAuth> create({
    String? clientId,
    required List<String> scopes,
  }) async {
    final auth = GDriveAuth._(
      clientId: clientId,
      scopes: scopes,
    );

    _log.info('Initializing Google Drive authentication');
    try {
      await auth._googleSignIn.initialize(
        clientId: clientId,
        serverClientId: clientId,
      );

      // Try silent sign-in for returning users
      final account =
          await auth._googleSignIn.attemptLightweightAuthentication();
      if (account != null) {
        _log.info('Silent sign-in successful: ${account.id}');
      }
    } catch (e, stackTrace) {
      _log.warning('Silent sign-in failed', e, stackTrace);
    }

    return auth;
  }

  /// Performs interactive OAuth2 authentication flow.
  ///
  /// Opens Google Sign-In UI for user to grant permissions.
  /// Returns true if authentication succeeded.
  Future<bool> authenticate() async {
    try {
      _log.info('Starting Google Sign-In authentication flow');

      if (!_googleSignIn.supportsAuthenticate()) {
        throw GDriveUserInteractionRequired(
            'Web sign-in must be triggered via the GIS button');
      }

      // Trigger interactive sign-in
      final account = await _googleSignIn.authenticate(scopeHint: scopes);
      _log.info('Authentication successful for user: ${account.id}');
      return true;
    } on PlatformException catch (e) {
      _log.severe(
          'Google Sign-In platform exception: ${e.code} - ${e.message}', e);
      return false;
    } catch (e, stackTrace) {
      _log.severe('Authentication failed', e, stackTrace);
      return false;
    }
  }

  @override
  Future<bool> isAuthenticated() async => _currentUser != null;

  @override
  AuthValueListenable get isAuthenticatedNotifier => _authListenable;

  @override
  String? get userDisplayName => _currentUser?.displayName;

  @override
  String? get userId => _currentUser?.id;

  /// Authorizes Google Drive scopes interactively.
  ///
  /// Must be called directly from a user gesture (button tap) on web, since
  /// the underlying GIS SDK requires user interaction to open the consent popup.
  /// After successful authorization, notifies [isAuthenticatedNotifier] to
  /// trigger [GDriveAuthSender] to push a fresh token to the worker.
  ///
  /// On native platforms, [authenticate] handles the full auth+authorization
  /// flow, so this method is not needed.
  Future<bool> authorizeInteractively() async {
    if (_currentUser == null) {
      throw StateError('Not authenticated - must sign in first');
    }
    try {
      _log.info('Authorizing Drive scopes interactively');
      await _authorizeScopes(allowUserInteraction: true);
      // Scopes are now cached. Ensure isAuthenticatedNotifier is true so
      // GDriveAuthSender pushes a fresh token to the worker.
      _isAuthenticatedNotifier.value = true;
      _log.info('Drive scopes authorized successfully');
      return true;
    } catch (e, stackTrace) {
      _log.severe('Interactive scope authorization failed', e, stackTrace);
      return false;
    }
  }

  @override
  Future<String> getAccessToken() async {
    if (_currentUser == null) {
      throw StateError('Not authenticated - call authenticate() first');
    }
    // Never allow automatic popups: Drive scopes must be authorized explicitly
    // via authorizeInteractively() from a user gesture on web.
    final authorization = await _authorizeScopes(
      allowUserInteraction: false,
    );
    return authorization.accessToken;
  }

  @override
  Future<void> refreshToken({String? reason}) async {
    if (_currentUser == null) {
      throw StateError('Not authenticated - cannot refresh token');
    }

    _log.info('Refreshing access token${reason != null ? ': $reason' : ''}');

    try {
      final authClient = _googleSignIn.authorizationClient;
      final existing = await authClient.authorizationForScopes(scopes);
      if (existing != null) {
        await authClient.clearAuthorizationToken(
            accessToken: existing.accessToken);
      }

      final authorization = await _authorizeScopes(allowUserInteraction: false);
      if (authorization.accessToken.isEmpty) {
        throw StateError('Failed to refresh access token');
      }

      _log.fine('Access token refreshed successfully');
    } catch (e, stackTrace) {
      _log.severe('Token refresh failed', e, stackTrace);
      rethrow;
    }
  }

  @override
  Future<void> logout() async {
    _log.info('Logging out user: ${_currentUser?.id}');
    await _googleSignIn.signOut();
  }

  /// Clean up resources.
  void dispose() {
    _authEventsSubscription?.cancel();
    _isAuthenticatedNotifier.dispose();
  }
}
