import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:googleapis/oauth2/v2.dart';
import 'package:googleapis_auth/auth_io.dart';
import 'package:http/http.dart' as http;
import 'package:locorda_core/locorda_core.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../gdrive_auth.dart';

final _log = Logger('DesktopGDriveAuth');

/// Custom Google Drive authentication implementation for Desktop platforms
/// (Windows and Linux) using `googleapis_auth` and `shared_preferences`.
class DesktopGDriveAuth implements GDriveAuth {
  final String? _clientId;
  final String? _clientKey;
  
  @override
  final List<String> scopes;

  AccessCredentials? _credentials;
  final ValueNotifier<bool> _isAuthenticatedNotifier = ValueNotifier(false);
  late final AuthValueListenableImpl _authListenable;
  final http.Client _httpClient = http.Client();

  String? _userDisplayName;
  String? _userId;

  static const _kAccessTokenKey = 'locorda_gdrive_access_token';
  static const _kRefreshTokenKey = 'locorda_gdrive_refresh_token';
  static const _kExpiryKey = 'locorda_gdrive_expiry';
  static const _kScopesKey = 'locorda_gdrive_scopes';
  static const _kUserIdKey = 'locorda_gdrive_user_id';
  static const _kUserDisplayNameKey = 'locorda_gdrive_user_display_name';

  DesktopGDriveAuth._({
    required String? clientId,
    required String? clientKey,
    required this.scopes,
  })  : _clientId = clientId,
        _clientKey = clientKey {
    _authListenable = AuthValueListenableImpl(_isAuthenticatedNotifier);
  }

  /// Creates and initializes the Desktop GDrive Auth instance.
  /// Attempts to restore previously persisted credentials.
  static Future<DesktopGDriveAuth> create({
    required String? clientId,
    required String? clientKey,
    required List<String> scopes,
  }) async {
    final auth = DesktopGDriveAuth._(
      clientId: clientId,
      clientKey: clientKey,
      scopes: scopes,
    );
    await auth._loadCredentials();
    return auth;
  }

  Future<void> _loadCredentials() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final accessToken = prefs.getString(_kAccessTokenKey);
      final refreshToken = prefs.getString(_kRefreshTokenKey);
      final expiryStr = prefs.getString(_kExpiryKey);
      final scopesList = prefs.getStringList(_kScopesKey);
      _userId = prefs.getString(_kUserIdKey);
      _userDisplayName = prefs.getString(_kUserDisplayNameKey);

      if (accessToken != null && expiryStr != null && scopesList != null) {
        final expiry = DateTime.parse(expiryStr).toUtc();
        _credentials = AccessCredentials(
          AccessToken('Bearer', accessToken, expiry),
          refreshToken,
          scopesList,
        );
        _isAuthenticatedNotifier.value = true;
        _log.info('Successfully loaded persisted GDrive credentials for user: $_userId');
      }
    } catch (e, stackTrace) {
      _log.warning('Failed to load persisted GDrive credentials', e, stackTrace);
    }
  }

  Future<void> _saveCredentials(AccessCredentials credentials) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kAccessTokenKey, credentials.accessToken.data);
      if (credentials.refreshToken != null) {
        await prefs.setString(_kRefreshTokenKey, credentials.refreshToken!);
      } else if (credentials == _credentials && _credentials?.refreshToken != null) {
        // Carry forward the old refresh token if the new credentials did not contain one
        await prefs.setString(_kRefreshTokenKey, _credentials!.refreshToken!);
      }
      await prefs.setString(_kExpiryKey, credentials.accessToken.expiry.toIso8601String());
      await prefs.setStringList(_kScopesKey, credentials.scopes);
      if (_userId != null) {
        await prefs.setString(_kUserIdKey, _userId!);
      }
      if (_userDisplayName != null) {
        await prefs.setString(_kUserDisplayNameKey, _userDisplayName!);
      }
      _log.fine('Saved persisted GDrive credentials');
    } catch (e, stackTrace) {
      _log.warning('Failed to save GDrive credentials', e, stackTrace);
    }
  }

  Future<void> _clearCredentials() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kAccessTokenKey);
      await prefs.remove(_kRefreshTokenKey);
      await prefs.remove(_kExpiryKey);
      await prefs.remove(_kScopesKey);
      await prefs.remove(_kUserIdKey);
      await prefs.remove(_kUserDisplayNameKey);
      _credentials = null;
      _userId = null;
      _userDisplayName = null;
      _isAuthenticatedNotifier.value = false;
      _log.info('Cleared persisted GDrive credentials');
    } catch (e, stackTrace) {
      _log.warning('Failed to clear GDrive credentials', e, stackTrace);
    }
  }

  @override
  Future<bool> authenticate() async {
    if (_clientId == null || _clientKey == null) {
      _log.severe('Cannot authenticate: clientId or clientKey is null. '
          'Please provide OAuth2 credentials for desktop (Windows/Linux).');
      return false;
    }

    try {
      _log.info('Starting desktop Google Sign-In flow');

      // Request additional standard profile/userinfo scopes to fetch user info
      final requiredScopes = {
        ...scopes,
        'https://www.googleapis.com/auth/userinfo.profile',
      }.toList();

      final credentials = await obtainAccessCredentialsViaUserConsent(
        ClientId(_clientId, _clientKey),
        requiredScopes,
        _httpClient,
        (url) async {
          final uri = Uri.parse(url);
          _log.info('Opening default browser for OAuth2 consent: $url');
          if (await canLaunchUrl(uri)) {
            await launchUrl(uri);
          } else {
            _log.warning('Could not launch user consent URL: $url');
            throw Exception('Could not launch default web browser for OAuth2 consent.');
          }
        },
      );

      _credentials = credentials;

      // Force Flutter to reschedule rendering after the browser window stole
      // focus during the OAuth consent flow. On Linux/GTK the rendering
      // surface can end up in an inconsistent state (resulting in black
      // frames) after an external window interaction; this nudge is a no-op
      // when rendering is already active.
      WidgetsBinding.instance.ensureVisualUpdate();

      // Fetch user info (ID and display name)
      try {
        final client = authenticatedClient(_httpClient, credentials);
        final oauth2 = Oauth2Api(client);
        final userInfo = await oauth2.userinfo.get();
        _userId = userInfo.id;
        _userDisplayName = userInfo.name;
        _log.info('User authenticated successfully: $_userId ($_userDisplayName)');
      } catch (e, stackTrace) {
        _log.warning('Failed to fetch user info, using defaults', e, stackTrace);
        _userId = 'unknown_user';
        _userDisplayName = 'Google User';
      }

      await _saveCredentials(credentials);
      _isAuthenticatedNotifier.value = true;
      return true;
    } catch (e, stackTrace) {
      _log.severe('Desktop authentication failed', e, stackTrace);
      return false;
    }
  }

  @override
  Future<bool> authorizeInteractively() async {
    // For desktop flow, authorization and authentication are identical
    return authenticate();
  }

  @override
  Future<bool> isAuthenticated() async => _credentials != null;

  @override
  AuthValueListenable get isAuthenticatedNotifier => _authListenable;

  @override
  String? get userDisplayName => _userDisplayName;

  @override
  String? get userId => _userId;

  @override
  Future<String> getAccessToken() async {
    final credentials = _credentials;
    if (credentials == null) {
      throw StateError('Not authenticated - call authenticate() first');
    }

    final now = DateTime.now().toUtc();
    final expiry = credentials.accessToken.expiry.toUtc();
    if (expiry.isBefore(now.add(const Duration(minutes: 1)))) {
      _log.info('Access token expired or expiring soon, refreshing...');
      await refreshToken(reason: 'Token expired');
    }

    return _credentials!.accessToken.data;
  }

  @override
  Future<void> refreshToken({String? reason}) async {
    final credentials = _credentials;
    if (credentials == null) {
      throw StateError('Not authenticated - cannot refresh token');
    }
    if (_clientId == null || _clientKey == null) {
      throw StateError('Cannot refresh token: clientId or clientKey is null.');
    }

    _log.info('Refreshing desktop access token${reason != null ? ': $reason' : ''}');

    try {
      final newCredentials = await refreshCredentials(
        ClientId(_clientId, _clientKey),
        credentials,
        _httpClient,
      );

      _credentials = newCredentials;
      await _saveCredentials(newCredentials);
      _isAuthenticatedNotifier.value = true;
      _log.fine('Desktop access token refreshed successfully');
    } catch (e, stackTrace) {
      _log.severe('Desktop token refresh failed', e, stackTrace);
      rethrow;
    }
  }

  @override
  Future<void> logout() async {
    await _clearCredentials();
  }

  @override
  void dispose() {
    _httpClient.close();
    _isAuthenticatedNotifier.dispose();
  }
}
