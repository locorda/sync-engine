/// Default implementations for [LocordaStatusWidget] customization.
///
/// These functions provide the standard behavior for [LocordaStatusWidget]
/// and can be reused or mixed with custom implementations.
library;

import 'package:flutter/material.dart';
import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_ui/locorda_ui.dart';

/// Default implementations for [LocordaStatusWidget] customization.
///
/// This class provides the standard implementations used by [LocordaStatusWidget]
/// when no custom builders are provided. You can reference these when building
/// custom implementations.
///
/// ## Example: Custom icon
///
/// ```dart
/// LocordaStatusWidget(
///   auth: auth,
///   syncManager: syncManager,
///   iconBuilder: (context, state) {
///     if (state.isSyncing) {
///       return Icon(Icons.sync, color: Colors.blue);
///     }
///     return LocordaStatusDefaults.materialIcon(context, state);
///   },
/// )
/// ```
class LocordaStatusDefaults {
  LocordaStatusDefaults._(); // Private constructor - utility class

  /// Default icon builder using Material Design icons.
  ///
  /// Shows:
  /// - `cloud_off` (grey) when not authenticated
  /// - `cloud_off` (red) when error
  /// - `CircularProgressIndicator` when syncing
  /// - `cloud_done` (green) when up to date
  static Widget materialIcon(BuildContext context, LocordaStatusState state) {
    final colorScheme = Theme.of(context).colorScheme;

    if (!state.isAuthenticated) {
      return Icon(Icons.cloud_off, color: colorScheme.onSurfaceVariant);
    } else if (state.hasError) {
      return Icon(Icons.cloud_off, color: colorScheme.error);
    } else if (state.isSyncing) {
      // Show explicit progress indicator for user-initiated syncs
      final isUserInitiated = state.lastTrigger == SyncTrigger.manual ||
          state.lastTrigger == SyncTrigger.pullToRefresh;

      if (isUserInitiated) {
        // Explicit progress for manual syncs - user expects feedback
        return SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation<Color>(colorScheme.primary),
          ),
        );
      } else {
        // Subtle feedback for automatic syncs - don't make user think app is slow
        return Icon(Icons.cloud_sync, color: colorScheme.primary);
      }
    } else {
      return Icon(Icons.cloud_done, color: Colors.green);
    }
  }

  /// Default status menu showing modal bottom sheet with standard items.
  ///
  /// Shows connection status, sync actions, and sign out option.
  static StatusMenuCallback bottomSheetStatusMenu({
    required Auth auth,
  }) {
    return (
      BuildContext context, {
      required LocordaStatusState state,
      required VoidCallback onTriggerSync,
      required VoidCallback onTriggerDisconnect,
    }) {
      final l10n = LocordaUILocalizations.of(context)!;

      // Build menu items
      final menuItems = <Widget>[
        // Status header
        ListTile(
          leading: Icon(
            state.isAuthenticated ? Icons.cloud_done : Icons.cloud_off,
            color: state.isAuthenticated ? Colors.green : Colors.grey,
          ),
          title:
              Text(state.isAuthenticated ? l10n.connected : l10n.notConnected),
          subtitle:
              auth.userDisplayName != null ? Text(auth.userDisplayName!) : null,
        ),
        const Divider(),

        // Error display if present
        if (state.hasError) ...[
          ListTile(
            leading: const Icon(Icons.error_outline, color: Colors.red),
            title: Text(l10n.syncError),
            subtitle: Text(
              state.errorMessage ?? l10n.syncError,
              style: const TextStyle(fontSize: 12),
            ),
          ),
          const Divider(),
        ],

        // Sync action (Retry or Sync Now depending on state)
        if (state.hasError)
          ListTile(
            leading: const Icon(Icons.refresh),
            title: Text(l10n.retrySync),
            enabled: !state.isSyncing,
            onTap: state.isSyncing
                ? null
                : () {
                    Navigator.pop(context);
                    onTriggerSync();
                  },
          )
        else
          ListTile(
            leading: const Icon(Icons.sync),
            title: Text(l10n.syncNow),
            enabled: !state.isSyncing,
            onTap: state.isSyncing
                ? null
                : () {
                    Navigator.pop(context);
                    onTriggerSync();
                  },
          ),

        const Divider(),

        // Sign out
        ListTile(
          leading: const Icon(Icons.logout),
          title: Text(l10n.signOut),
          onTap: () {
            Navigator.pop(context);
            onTriggerDisconnect();
          },
        ),
      ];

      showModalBottomSheet<void>(
        context: context,
        builder: (context) => Container(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: menuItems,
          ),
        ),
      );
    };
  }
}
