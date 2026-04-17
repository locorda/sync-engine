/// Multi-backend status widget with unified UI.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_ui/src/remote_ui_adapter.dart';
import 'package:locorda_ui/src/ui_adapter_registry.dart';
import 'package:logging/logging.dart';

import '../../l10n/locorda_ui_localizations.dart';

final _log = Logger('MultiBackendStatusWidget');

/// Unified status widget for multiple storage backends.
///
/// Displays authentication and sync status in a single icon button suitable
/// for app bars. Automatically aggregates state from all registered plugins
/// and provides a menu for backend selection and management.
///
/// ## Key Features
///
/// - **Single active backend**: UI ensures only one backend is authenticated at a time
/// - **Visual feedback**: Icon reflects current state (not connected, syncing, error, up-to-date)
/// - **Backend selection**: Modal menu for connecting to available backends
/// - **Sync control**: Manual sync trigger and disconnect actions
///
/// ## Backend Priority
///
/// If multiple plugins are authenticated (shouldn't happen via this UI),
/// the first one in registry order becomes the active backend.
class MultiBackendStatusWidget extends StatefulWidget {
  /// Registry of available storage plugins.
  final UiAdapterRegistry registry;

  /// Sync manager for reactive sync status updates.
  final SyncManager syncManager;

  /// Optional custom icon builder.
  ///
  /// Receives current aggregated state and returns widget.
  /// Default: Material Design icons with color coding.
  final Widget Function(BuildContext, _AggregatedState)? iconBuilder;

  const MultiBackendStatusWidget({
    super.key,
    required this.registry,
    required this.syncManager,
    this.iconBuilder,
  });

  @override
  State<MultiBackendStatusWidget> createState() =>
      _MultiBackendStatusWidgetState();
}

class _MultiBackendStatusWidgetState extends State<MultiBackendStatusWidget> {
  final List<VoidCallback> _authListeners = [];
  SyncState? _syncState;

  @override
  void initState() {
    super.initState();
    _subscribeToAuthChanges();
  }

  @override
  void dispose() {
    _unsubscribeFromAuthChanges();
    super.dispose();
  }

  void _subscribeToAuthChanges() {
    for (final plugin in widget.registry.remoteAdapters) {
      final listener = () => setState(() {});
      plugin.auth.isAuthenticatedNotifier.addListener(listener);
      _authListeners.add(listener);
    }
  }

  void _unsubscribeFromAuthChanges() {
    for (var i = 0; i < widget.registry.remoteAdapters.length; i++) {
      widget.registry.remoteAdapters[i].auth.isAuthenticatedNotifier
          .removeListener(_authListeners[i]);
    }
    _authListeners.clear();
  }

  _AggregatedState _buildAggregatedState() {
    final activePlugin = widget.registry.activeRemote;
    final isAuthenticated = activePlugin != null;
    final isSyncing = _syncState?.status == SyncStatus.syncing;
    final hasError = _syncState?.status == SyncStatus.error;

    return _AggregatedState(
      isAuthenticated: isAuthenticated,
      isSyncing: isSyncing,
      hasError: hasError,
      errorMessage: _syncState?.errorMessage,
      activePluginId: activePlugin?.id,
      activePluginName: activePlugin?.displayName,
    );
  }

  Future<void> _showBackendSelectionMenu() async {
    await showModalBottomSheet(
      context: context,
      builder: (context) => _BackendSelectionSheet(
        registry: widget.registry,
        syncManager: widget.syncManager,
        onStateChanged: () => setState(() {}),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<SyncState>(
      stream: widget.syncManager.statusStream,
      initialData: widget.syncManager.currentState,
      builder: (context, snapshot) {
        _syncState = snapshot.data;
        final state = _buildAggregatedState();

        Widget icon;
        if (widget.iconBuilder != null) {
          icon = widget.iconBuilder!(context, state);
        } else {
          icon = _buildDefaultIcon(context, state);
        }

        return IconButton(
          icon: icon,
          onPressed: _showBackendSelectionMenu,
          tooltip: _buildTooltip(context, state),
        );
      },
    );
  }

  Widget _buildDefaultIcon(BuildContext context, _AggregatedState state) {
    final colorScheme = Theme.of(context).colorScheme;

    if (!state.isAuthenticated) {
      return Icon(
        Icons.cloud_off_outlined,
        color: colorScheme.onSurfaceVariant,
      );
    }

    if (state.hasError) {
      return Icon(
        Icons.cloud_off_outlined,
        color: colorScheme.error,
      );
    }

    if (state.isSyncing) {
      return SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: colorScheme.primary,
        ),
      );
    }

    return Icon(
      Icons.cloud_done_outlined,
      color: colorScheme.primary,
    );
  }

  String _buildTooltip(BuildContext context, _AggregatedState state) {
    final l10n = LocordaUILocalizations.of(context)!;

    if (!state.isAuthenticated) {
      return l10n.notConnected;
    }

    if (state.hasError) {
      return l10n.syncError;
    }

    if (state.isSyncing) {
      return l10n.syncing;
    }

    return '${state.activePluginName} - ${l10n.upToDate}';
  }
}

/// Internal state aggregated from plugin registry and sync manager.
class _AggregatedState {
  final bool isAuthenticated;
  final bool isSyncing;
  final bool hasError;
  final String? errorMessage;
  final String? activePluginId;
  final String? activePluginName;

  const _AggregatedState({
    required this.isAuthenticated,
    required this.isSyncing,
    required this.hasError,
    this.errorMessage,
    this.activePluginId,
    this.activePluginName,
  });
}

/// Bottom sheet for backend selection and management.
class _BackendSelectionSheet extends StatefulWidget {
  final UiAdapterRegistry registry;
  final SyncManager syncManager;
  final VoidCallback onStateChanged;

  const _BackendSelectionSheet({
    required this.registry,
    required this.syncManager,
    required this.onStateChanged,
  });

  @override
  State<_BackendSelectionSheet> createState() => _BackendSelectionSheetState();
}

class _BackendSelectionSheetState extends State<_BackendSelectionSheet> {
  bool _isProcessing = false;

  Future<void> _connectToBackend(RemoteUiAdapter plugin) async {
    setState(() => _isProcessing = true);

    try {
      // Ensure single active backend: disconnect others first
      final authenticatedPlugins = widget.registry.authenticatedRemotes;
      for (final authenticatedPlugin in authenticatedPlugins) {
        if (authenticatedPlugin.id != plugin.id) {
          _log.info(
              'Disconnecting ${authenticatedPlugin.displayName} before connecting to ${plugin.displayName}');
          await authenticatedPlugin.auth.logout();
        }
      }

      // Show login for selected backend
      if (!mounted) return;
      final success = await plugin.showLogin(context);

      if (success && mounted) {
        _log.info('Successfully connected to ${plugin.displayName}');

        // Trigger sync after successful login
        unawaited(widget.syncManager.sync(trigger: SyncTrigger.login));

        // Notify parent and close sheet
        widget.onStateChanged();
        Navigator.of(context).pop();
      }
    } catch (e, stackTrace) {
      _log.severe('Error connecting to ${plugin.displayName}', e, stackTrace);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              LocordaUILocalizations.of(context)!.errorConnecting(e.toString()),
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isProcessing = false);
      }
    }
  }

  Future<void> _disconnect(RemoteUiAdapter plugin) async {
    setState(() => _isProcessing = true);

    try {
      await plugin.auth.logout();
      _log.info('Disconnected from ${plugin.displayName}');

      if (mounted) {
        widget.onStateChanged();
        Navigator.of(context).pop();
      }
    } catch (e, stackTrace) {
      _log.severe(
          'Error disconnecting from ${plugin.displayName}', e, stackTrace);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              LocordaUILocalizations.of(context)!
                  .errorDisconnecting(e.toString()),
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isProcessing = false);
      }
    }
  }

  Future<void> _triggerSync() async {
    try {
      await widget.syncManager.sync(trigger: SyncTrigger.manual);
      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (e, stackTrace) {
      _log.severe('Error triggering sync', e, stackTrace);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = LocordaUILocalizations.of(context)!;
    final activePlugin = widget.registry.activeRemote;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Title
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                l10n.storageBackends,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            const SizedBox(height: 16),

            // Backend list (scrollable for many backends)
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Sync actions (only if authenticated)
                    if (activePlugin != null) ...[
                      ListTile(
                        enabled: !_isProcessing,
                        leading: const Icon(Icons.sync),
                        title: Text(l10n.syncNow),
                        onTap: _triggerSync,
                      ),
                      ListTile(
                        enabled: !_isProcessing,
                        leading: const Icon(Icons.logout),
                        title: Text(l10n.disconnect),
                        onTap: () => _disconnect(activePlugin),
                      ),
                      //const Divider(),
                    ],
                    if (activePlugin == null)
                      ...widget.registry.remoteAdapters.map((plugin) {
                        final isActive = plugin.id == activePlugin?.id;
                        final isAuthenticated =
                            plugin.auth.isAuthenticatedNotifier.isAuthenticated;

                        return ListTile(
                          enabled: !_isProcessing,
                          leading: Icon(plugin.icon),
                          title: Text(plugin.displayName),
                          subtitle: isAuthenticated
                              ? Text(l10n.connected)
                              : Text(l10n.notConnected),
                          trailing: isAuthenticated
                              ? (isActive
                                  ? null
                                  : IconButton(
                                      icon: const Icon(Icons.logout),
                                      onPressed: () => _disconnect(plugin),
                                    ))
                              : TextButton(
                                  onPressed: () => _connectToBackend(plugin),
                                  child: Text(l10n.connect),
                                ),
                        );
                      })
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
