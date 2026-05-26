/// Google Drive authentication bridge with multi-platform support.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:locorda_core/locorda_core.dart';

import 'auth/gdrive_auth_io.dart'
    if (dart.library.html) 'auth/gdrive_auth_web.dart';
import 'auth/gdrive_auth_provider.dart';

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

/// Google Drive authentication interface.
///
/// Under the hood, delegates to a native (Android/iOS/macOS) Google Sign-In flow,
/// a Web GIS button flow, or a Desktop (Windows/Linux) OAuth 2.0 loopback flow.
abstract class GDriveAuth implements GDriveAuthProvider {
  /// Scopes required for Drive sync.
  List<String> get scopes;

  /// Performs interactive OAuth2 authentication flow.
  ///
  /// Opens Google Sign-In UI for user to grant permissions.
  /// Returns true if authentication succeeded.
  Future<bool> authenticate();

  /// Authorizes Google Drive scopes interactively.
  Future<bool> authorizeInteractively();

  /// Dispose allocated resources.
  void dispose();

  /// Creates and initializes Google Drive authentication.
  ///
  /// Parameters:
  /// - [clientId]: Optional OAuth2 client ID.
  /// - [clientKey]: Optional OAuth2 client key (required for Windows & Linux).
  /// - [scopes]: OAuth2 scopes to request.
  static Future<GDriveAuth> create({
    String? clientId,
    String? clientKey,
    required List<String> scopes,
  }) async {
    return createGDriveAuth(
      clientId: clientId,
      clientKey: clientKey,
      scopes: scopes,
    );
  }
}
