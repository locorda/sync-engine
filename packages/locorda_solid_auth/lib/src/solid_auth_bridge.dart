/// Implementation of SolidAuthProvider using solid-auth library.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:locorda_core/locorda_core.dart';

import 'package:logging/logging.dart';
import 'package:solid_oidc_auth/solid_oidc_auth.dart';
import 'package:locorda_solid_core/locorda_solid_core.dart';

final _log = Logger('SolidAuthBridge');

class AuthValueListenableImpl implements AuthValueListenable {
  final ValueListenable<bool> _notifier;

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

/// Concrete implementation of SolidAuthProvider using solid-auth library.
///
/// This class bridges the abstract authentication interface from the core
/// library with the solid-auth implementation.
class SolidAuthBridge implements SolidAuthProvider {
  final SolidOidcAuth _solidAuth;
  final AuthValueListenableImpl _isAuthenticatedNotifier;

  SolidAuthBridge(this._solidAuth)
      : _isAuthenticatedNotifier =
            AuthValueListenableImpl(_solidAuth.isAuthenticatedNotifier);

  @override
  String? get userDisplayName => _solidAuth.currentWebId;

  @override
  Future<void> logout() {
    return _solidAuth.logout();
  }

  @override
  Future<bool> isAuthenticated() async => _solidAuth.isAuthenticated;

  @override
  AuthValueListenable get isAuthenticatedNotifier => _isAuthenticatedNotifier;

  @override
  String? get currentWebId => _solidAuth.currentWebId;

  @override
  Future<({String accessToken, String dPoP})> getDpopToken(
      String url, String method) async {
    final dpop = await _solidAuth.genDpopToken(url, method);
    return (accessToken: dpop.accessToken, dPoP: dpop.dpopToken);
  }

  @override
  Future<void> refreshToken({String? reason}) async {
    // This should never be called on main thread - all Pod HTTP requests
    // happen in worker thread, so 401 errors are detected there.
    // If this is called, it indicates a bug in the architecture.
    _log.severe(
      'refreshToken() called on SolidAuthBridge (main thread) - this should not happen. Reason: $reason',
    );
  }

  /// Clean up resources.
  void dispose() {
    // Solid Auth instance was provided externally; do not dispose it here.
  }
}
