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

  GDriveAuth._({
    required String? clientId,
    required this.scopes,
  }) {
    _authListenable = AuthValueListenableImpl(_isAuthenticatedNotifier);

    _googleSignIn = GoogleSignIn(
      scopes: scopes,
      serverClientId: clientId,
    );

    // Listen to sign-in state changes
    _googleSignIn.onCurrentUserChanged.listen((account) {
      _currentUser = account;
      _isAuthenticatedNotifier.value = account != null;
      if (account != null) {
        _log.info('User signed in: ${account.email}');
      } else {
        _log.info('User signed out');
      }
    });
  }

  /// Creates and initializes Google Drive authentication.
  ///
  /// Attempts silent sign-in for returning users automatically.
  ///
  /// Parameters:
  /// - [clientId]: Optional OAuth2 client ID. If not provided, will be read from
  ///   platform-specific configuration files (Info.plist on iOS, google-services.json
  ///   on Android, meta tag on Web).
  /// - [scopes]: OAuth2 scopes to request. Defaults to Drive file access + user email.
  static Future<GDriveAuth> create({
    String? clientId,
    List<String>? scopes,
  }) async {
    final auth = GDriveAuth._(
      clientId: clientId,
      scopes: scopes ??
          [
            'https://www.googleapis.com/auth/drive.file',
            'https://www.googleapis.com/auth/userinfo.email',
          ],
    );

    _log.info('Initializing Google Drive authentication');
    try {
      // Try silent sign-in for returning users
      final account = await auth._googleSignIn.signInSilently();
      if (account != null) {
        _log.info('Silent sign-in successful: ${account.email}');
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

      // Trigger interactive sign-in
      final account = await _googleSignIn.signIn();

      if (account != null) {
        _log.info('Authentication successful for user: ${account.email}');
        return true;
      }

      _log.warning('User cancelled sign-in');
      return false;
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
  String? get userEmail => _currentUser?.email;

  @override
  Future<String> getAccessToken() async {
    if (_currentUser == null) {
      throw StateError('Not authenticated - call authenticate() first');
    }

    // Get authentication headers (automatically handles token refresh)
    final auth = await _currentUser!.authentication;
    final accessToken = auth.accessToken;

    if (accessToken == null) {
      throw StateError('Failed to get access token');
    }

    return accessToken;
  }

  @override
  Future<void> refreshToken({String? reason}) async {
    if (_currentUser == null) {
      throw StateError('Not authenticated - cannot refresh token');
    }

    _log.info('Refreshing access token${reason != null ? ': $reason' : ''}');

    try {
      // Clear cached authentication to force refresh
      await _currentUser!.clearAuthCache();

      // Get fresh authentication (triggers token refresh)
      final auth = await _currentUser!.authentication;

      if (auth.accessToken == null) {
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
    _log.info('Logging out user: ${_currentUser?.email}');
    await _googleSignIn.signOut();
  }

  /// Clean up resources.
  void dispose() {
    _isAuthenticatedNotifier.dispose();
  }
}
