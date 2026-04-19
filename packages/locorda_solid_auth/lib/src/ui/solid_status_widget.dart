import 'package:flutter/material.dart';
import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_solid_auth/src/solid_auth_bridge.dart';
import 'package:locorda_ui/locorda_ui.dart';
import 'package:solid_oidc_auth/solid_oidc_auth.dart';

import 'solid_status_defaults.dart';

/// Callback signature for showing the status menu.
///
/// Receives the current [state] and callbacks to trigger sync or disconnect actions.
typedef StatusMenuCallback = void Function(
  BuildContext context, {
  required SolidStatusState state,
  required VoidCallback onTriggerSync,
  required VoidCallback onTriggerDisconnect,
});

/// Immutable state representing current Solid authentication and sync status.
///
/// Used by [SolidStatusWidget] builders to render appropriate UI.
class SolidStatusState {
  final bool isAuthenticated;
  final bool isSyncing;
  final bool hasError;
  final String? errorMessage;
  final String? webId;
  final SyncTrigger? lastTrigger;

  const SolidStatusState({
    required this.isAuthenticated,
    this.isSyncing = false,
    this.hasError = false,
    this.errorMessage,
    this.webId,
    this.lastTrigger,
  });
}

/// A combined authentication and sync status widget for the app bar.
///
/// This widget shows the current Solid authentication status and reactive
/// sync state from [SyncManager] in a compact format suitable for app bars.
/// It handles the complete user journey from "not connected" → "connecting"
/// → "syncing" → "up to date".
///
/// ## Requirements
///
/// - [solidAuth]: SolidAuth instance for authentication state
/// - [syncManager]: SyncManager for reactive sync status (required)
///
/// ## Customization
///
/// The widget can be customized via:
///
/// - [iconBuilder]: Custom status icon rendering based on state
/// - [onShowLogin]: Custom login flow presentation
///
/// Both have sensible defaults - only override what you need.
class SolidStatusWidget extends LocordaStatusWidget {
  SolidStatusWidget({
    super.key,
    required SolidOidcAuth solidAuth,
    required super.syncManager,
    Future<bool> Function(BuildContext)? onShowLogin,
    super.iconBuilder,
    super.onShowStatusMenu,
  }) : super(
            onShowLogin: onShowLogin ??
                SolidStatusDefaults.modalLogin(solidAuth: solidAuth),
            auth: SolidAuthBridge(solidAuth));
}
