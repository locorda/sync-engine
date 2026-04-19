/// Default implementations for [SolidStatusWidget] customization.
///
/// These functions provide the standard behavior for [SolidStatusWidget]
/// and can be reused or mixed with custom implementations.
library;

import 'package:flutter/material.dart';
import 'package:locorda_solid_auth/locorda_solid_auth.dart';
import 'package:solid_oidc_auth/solid_oidc_auth.dart';

/// Default implementations for [SolidStatusWidget] customization.
///
/// This class provides the standard implementations used by [SolidStatusWidget]
/// when no custom builders are provided. You can reference these when building
/// custom implementations.
///
/// ## Example: Custom icon
///
/// ```dart
/// SolidStatusWidget(
///   solidAuth: solidAuth,
///   syncManager: syncManager,
///   iconBuilder: (context, state) {
///     if (state.isSyncing) {
///       return Icon(Icons.sync, color: Colors.blue);
///     }
///     return SolidStatusDefaults.materialIcon(context, state);
///   },
/// )
/// ```
class SolidStatusDefaults {
  SolidStatusDefaults._(); // Private constructor - utility class

  /// Default login flow showing [SolidLoginScreen] as modal dialog.
  ///
  /// This is a factory function that returns a login callback configured
  /// with the provided parameters.
  static Future<bool> Function(BuildContext) modalLogin({
    required SolidOidcAuth solidAuth,
    SolidProviderService providerService = const DefaultSolidProviderService(),
    List<String> extraOidcScopes = const [],
  }) {
    return (BuildContext context) async {
      final user = await Navigator.of(context).push<UserAndWebId>(
        MaterialPageRoute(
          builder: (context) => SolidLoginScreen(
            solidAuth: solidAuth,
            providerService: providerService,
            extraOidcScopes: extraOidcScopes,
            onLoginSuccess: (userInfo) {
              Navigator.of(context).pop(userInfo);
            },
            onLoginError: (error) {
              // Error is already shown in the login screen
            },
          ),
        ),
      );
      return user != null;
    };
  }

  /// Full-screen login flow showing [SolidLoginScreen] as fullscreen dialog.
  ///
  /// Similar to [modalLogin] but uses fullscreenDialog presentation.
  /// Useful for onboarding flows where login is a primary action.
  static Future<bool> Function(BuildContext) fullscreenLogin({
    required SolidOidcAuth solidAuth,
    SolidProviderService providerService = const DefaultSolidProviderService(),
    List<String> extraOidcScopes = const [],
  }) {
    return (BuildContext context) async {
      final user = await Navigator.of(context).push<UserAndWebId>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (context) => SolidLoginScreen(
            solidAuth: solidAuth,
            providerService: providerService,
            extraOidcScopes: extraOidcScopes,
            onLoginSuccess: (userInfo) {
              Navigator.of(context).pop(userInfo);
            },
            onLoginError: (error) {
              // Error is already shown in the login screen
            },
          ),
        ),
      );
      return user != null;
    };
  }
}
