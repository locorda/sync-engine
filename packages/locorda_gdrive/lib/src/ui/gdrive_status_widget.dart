/// Google Drive status widget - delegates to LocordaStatusWidget.
library;

import 'package:flutter/material.dart';
import 'package:locorda_gdrive/src/gdrive_auth.dart';
import 'package:locorda_gdrive/src/ui/gdrive_status_defaults.dart';
import 'package:locorda_ui/locorda_ui.dart';

/// Status widget for Google Drive sync state.
///
/// Shows connection status, sync progress, and provides access to:
/// - Login flow (when not authenticated)
/// - Status menu with sync actions (when authenticated)
///
/// Delegates to [LocordaStatusWidget] for consistent UI across backends.
/// Uses Google Drive-specific login and menu implementations.
///
/// ## Example
///
/// ```dart
/// AppBar(
///   actions: [
///     GDriveStatusWidget(
///       gdriveAuth: gdriveAuth,
///       syncManager: syncSystem.syncManager,
///     ),
///   ],
/// )
/// ```
class GDriveStatusWidget extends LocordaStatusWidget {
  GDriveStatusWidget({
    super.key,
    required GDriveAuth gdriveAuth,
    required super.syncManager,
    Future<bool> Function(BuildContext)? onShowLogin,
    super.iconBuilder,
    super.onShowStatusMenu,
  }) : super(
            onShowLogin: onShowLogin ??
                GDriveStatusDefaults.modalLogin(gdriveAuth: gdriveAuth),
            auth: gdriveAuth);
}
