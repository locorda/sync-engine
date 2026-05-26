import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:locorda_core/locorda_core.dart';
import 'package:logging/logging.dart';

import '../gdrive_auth.dart';
import 'gdrive_auth_provider.dart';

final _log = Logger('GoogleSignInGDriveAuth');

/// Shared implementation of Google Drive authentication using `google_sign_in`.
/// Used on Web, Android, iOS, and macOS.
class GoogleSignInGDriveAuth implements GDriveAuth {
  @override
  final List<String> scopes;
  late final GoogleSignIn _googleSignIn;

  GoogleSignInAccount? _currentUser;
  final ValueNotifier<bool> _isAuthenticatedNotifier = ValueNotifier(false);
  late final AuthValueListenableImpl _authListenable;
  StreamSubscription<GoogleSignInAuthenticationEvent>? _authEventsSubscription;

  GoogleSignInGDriveAuth._({
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

  /// Creates and initializes the Google Sign-In instance.
  static Future<GoogleSignInGDriveAuth> create({
    String? clientId,
    required List<String> scopes,
  }) async {
    final auth = GoogleSignInGDriveAuth._(
      clientId: clientId,
      scopes: scopes,
    );

    _log.info('Initializing Google Sign-In');
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

  @override
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

  @override
  Future<bool> authorizeInteractively() async {
    if (_currentUser == null) {
      throw StateError('Not authenticated - must sign in first');
    }
    try {
      _log.info('Authorizing Drive scopes interactively');
      await _authorizeScopes(allowUserInteraction: true);
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

  @override
  void dispose() {
    _authEventsSubscription?.cancel();
    _isAuthenticatedNotifier.dispose();
  }
}
