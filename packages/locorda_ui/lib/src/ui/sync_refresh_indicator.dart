/// Pull-to-refresh widget integrated with Locorda sync.
library;

import 'package:flutter/material.dart';
import 'package:locorda_core/locorda_core.dart';

/// A [RefreshIndicator] wrapper that integrates with Locorda's [SyncManager].
///
/// This widget provides a standard pull-to-refresh experience that triggers
/// synchronization through the sync manager. It automatically handles:
/// - Pull-to-refresh gestures
/// - Sync progress indication
/// - Error handling
///
/// Usage:
/// ```dart
/// SyncRefreshIndicator(
///   syncManager: locorda.syncManager,
///   child: ListView(
///     children: [...],
///   ),
/// )
/// ```
class SyncRefreshIndicator extends StatelessWidget {
  /// The sync manager to trigger synchronization.
  final SyncManager syncManager;

  /// The child widget to wrap (typically a scrollable).
  final Widget child;

  /// Optional callback when sync completes successfully.
  final VoidCallback? onSyncComplete;

  /// Optional callback when sync fails.
  final void Function(Object error)? onSyncError;

  const SyncRefreshIndicator({
    super.key,
    required this.syncManager,
    required this.child,
    this.onSyncComplete,
    this.onSyncError,
  });

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _handleRefresh,
      child: child,
    );
  }

  Future<void> _handleRefresh() async {
    try {
      await syncManager.sync(trigger: SyncTrigger.pullToRefresh);
      onSyncComplete?.call();
    } catch (error) {
      onSyncError?.call(error);
      // Don't rethrow - RefreshIndicator handles completion
    }
  }
}
