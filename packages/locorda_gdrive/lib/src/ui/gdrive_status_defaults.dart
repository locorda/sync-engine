/// Default implementations for Google Drive UI components.
library;

import 'package:flutter/material.dart';
import 'package:locorda_gdrive/l10n/gdrive_localizations.dart';
import 'package:locorda_gdrive/src/gdrive_auth.dart';
import 'package:locorda_gdrive/src/ui/gdrive_login_screen.dart';

/// Default UI implementations for Google Drive integration.
///
/// Provides standard login flows and status menus following
/// Material Design patterns.
class GDriveStatusDefaults {
  GDriveStatusDefaults._(); // Private constructor - utility class

  /// Default login flow showing [GDriveLoginScreen] as modal dialog.
  ///
  /// This is a factory function that returns a login callback configured
  /// for the specific auth instance.
  ///
  /// Returns a callback that:
  /// 1. Shows [GDriveLoginScreen] as a full-screen dialog
  /// 2. Waits for user to complete OAuth2 flow
  /// 3. Returns `true` if login succeeded, `false` if cancelled
  ///
  /// ## Usage
  ///
  /// ```dart
  /// GDriveStatusWidget(
  ///   gdriveAuth: gdriveAuth,
  ///   syncManager: syncManager,
  ///   onShowLogin: GDriveStatusDefaults.modalLogin(gdriveAuth: gdriveAuth),
  /// )
  /// ```
  static Future<bool> Function(BuildContext) modalLogin({
    required GDriveAuth gdriveAuth,
  }) {
    return (BuildContext context) async {
      final l10n = GDriveLocalizations.of(context)!;

      final user = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (context) => GDriveLoginScreen(gdriveAuth: gdriveAuth),
          fullscreenDialog: true,
        ),
      );

      if (user == true && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.signInWithGoogle)),
        );
      }

      return user != null;
    };
  }
}
