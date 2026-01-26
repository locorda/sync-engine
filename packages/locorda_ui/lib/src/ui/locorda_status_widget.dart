import 'dart:async';

import 'package:flutter/material.dart';
import 'package:locorda_core/locorda_core.dart';
import 'package:logging/logging.dart';

import '../../l10n/locorda_ui_localizations.dart';
import 'locorda_status_defaults.dart';

final _log = Logger('LocordaStatusWidget');

/// Callback signature for showing the status menu.
///
/// Receives the current [state] and callbacks to trigger sync or disconnect actions.
typedef StatusMenuCallback = void Function(
  BuildContext context, {
  required LocordaStatusState state,
  required VoidCallback onTriggerSync,
  required VoidCallback onTriggerDisconnect,
});

/// Immutable state representing current authentication and sync status.
///
/// Used by [LocordaStatusWidget] builders to render appropriate UI.
class LocordaStatusState {
  final bool isAuthenticated;
  final bool isSyncing;
  final bool hasError;
  final String? errorMessage;
  final String? webId;
  final SyncTrigger? lastTrigger;

  const LocordaStatusState({
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
/// This widget shows the current authentication status and reactive
/// sync state from [SyncManager] in a compact format suitable for app bars.
/// It handles the complete user journey from "not connected" → "connecting"
/// → "syncing" → "up to date".
///
/// ## Requirements
///
/// - [auth]: Auth instance for authentication state
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
class LocordaStatusWidget extends StatefulWidget {
  /// The Auth instance to monitor for authentication state.
  final Auth auth;

  /// Sync manager for reactive sync status updates and sync operations.
  final SyncManager syncManager;

  /// Custom icon builder. Receives current [LocordaStatusState] and returns widget.
  ///
  /// Default: Material Design icons (cloud_off, cloud_done, spinner, etc.)
  final Widget Function(BuildContext context, LocordaStatusState state)
      iconBuilder;

  /// Custom login flow. Called when user taps icon while not authenticated.
  final Future<bool> Function(BuildContext context) onShowLogin;

  /// Custom status menu. Called when authenticated user taps the icon.
  ///
  /// Receives current state and callbacks for sync/disconnect actions.
  /// Default: Shows modal bottom sheet with standard menu items
  final StatusMenuCallback onShowStatusMenu;

  LocordaStatusWidget({
    super.key,
    required this.auth,
    required this.syncManager,
    required Future<bool> Function(BuildContext) onShowLogin,
    Widget Function(BuildContext, LocordaStatusState)? iconBuilder,
    StatusMenuCallback? onShowStatusMenu,
  })  : iconBuilder = iconBuilder ?? LocordaStatusDefaults.materialIcon,
        onShowLogin = onShowLogin,
        onShowStatusMenu = onShowStatusMenu ??
            LocordaStatusDefaults.bottomSheetStatusMenu(auth: auth);

  @override
  State<LocordaStatusWidget> createState() => _LocordaStatusWidgetState();
}

class _LocordaStatusWidgetState extends State<LocordaStatusWidget> {
  bool _isAuthenticated = false;
  SyncState? _syncState;

  @override
  void initState() {
    super.initState();
    _checkAuthStatus();

    // Listen to authentication changes
    widget.auth.isAuthenticatedNotifier.addListener(_onAuthChanged);
  }

  @override
  void dispose() {
    widget.auth.isAuthenticatedNotifier.removeListener(_onAuthChanged);
    super.dispose();
  }

  void _onAuthChanged() {
    try {
      _log.info('Authentication state changed');
      _checkAuthStatus();
    } catch (e, stackTrace) {
      _log.severe(
          'Error in authentication state change handler', e, stackTrace);
    }
  }

  Future<void> _checkAuthStatus() async {
    try {
      final isAuth = await widget.auth.isAuthenticated();
      _log.fine('Authentication status checked: $isAuth');
      if (mounted) {
        setState(() {
          _isAuthenticated = isAuth;
        });
      }
    } catch (e, stackTrace) {
      _log.severe('Error checking authentication status', e, stackTrace);
      // Avoid setState if there's an error to prevent potential recursion
    }
  }

  Future<void> _showLoginScreen() async {
    // Use custom login flow
    final success = await widget.onShowLogin(context);

    if (success) {
      // Refresh auth status after successful login
      await _checkAuthStatus();

      // Trigger automatic sync after login
      _log.info('Login successful, triggering automatic sync');
      unawaited(widget.syncManager.sync(trigger: SyncTrigger.login));
    }
  }

  Future<void> _disconnect() async {
    try {
      await widget.auth.logout();
      await _checkAuthStatus();
    } catch (e, stackTrace) {
      _log.severe('Error during logout', e, stackTrace);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              LocordaUILocalizations.of(context)!.errorConnecting(e.toString()),
            ),
          ),
        );
      }
    }
  }

  /// Show status menu with authentication and sync options.
  void _showStatusMenu() {
    if (!_isAuthenticated) return;
    // Build state for icon builder
    final state = _buildLocordaStatusState();
    widget.onShowStatusMenu(
      context,
      state: state,
      onTriggerSync: _triggerSync,
      onTriggerDisconnect: _disconnect,
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<SyncState>(
      stream: widget.syncManager.statusStream,
      initialData: widget.syncManager.currentState,
      builder: (context, snapshot) {
        _syncState = snapshot.data ?? const SyncState.idle();
        return _buildIcon(context);
      },
    );
  }

  Widget _buildIcon(BuildContext context) {
    final l10n = LocordaUILocalizations.of(context)!;

    // Build state for icon builder
    final state = _buildLocordaStatusState();

    // Use custom icon builder
    final icon = widget.iconBuilder(context, state);

    // Determine tooltip and action
    String tooltip;
    VoidCallback? onPressed;

    if (!_isAuthenticated) {
      // Not connected - open login screen
      tooltip = l10n.notConnected;
      onPressed = _showLoginScreen;
    } else if (state.hasError) {
      // Connected but has error - open menu (includes retry option)
      tooltip = state.errorMessage ?? l10n.syncError;
      onPressed = _showStatusMenu;
    } else if (state.isSyncing) {
      // Connected and syncing - open menu (options disabled during sync)
      tooltip = l10n.syncing;
      onPressed = _showStatusMenu;
    } else {
      // Connected and up to date - open menu
      tooltip = l10n.upToDate;
      onPressed = _showStatusMenu;
    }

    return IconButton(
      onPressed: onPressed,
      icon: icon,
      tooltip: tooltip,
    );
  }

  LocordaStatusState _buildLocordaStatusState() {
    // Get sync status from syncManager stream
    final bool isSyncing = _syncState?.status == SyncStatus.syncing;
    final bool hasError = _syncState?.status == SyncStatus.error;
    final String? errorMessage = _syncState?.errorMessage;
    final SyncTrigger? lastTrigger = _syncState?.lastTrigger;

    // Build state for icon builder
    return LocordaStatusState(
      isAuthenticated: _isAuthenticated,
      isSyncing: isSyncing,
      hasError: hasError,
      errorMessage: errorMessage,
      webId: widget.auth.userDisplayName,
      lastTrigger: lastTrigger,
    );
  }

  Future<void> _triggerSync() async {
    await widget.syncManager.sync(trigger: SyncTrigger.manual);
  }
}
