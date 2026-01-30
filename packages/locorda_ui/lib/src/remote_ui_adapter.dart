/// UI adapter interface for remote storage backends.
///
/// Provides UI integration for remote backends (Solid Pod, Google Drive, etc.),
/// including authentication, display properties, and login flows.
///
/// This interface focuses on UI-specific aspects, while [RemoteMainHandler]
/// handles communication with the worker thread for actual backend operations.
///
/// ## Implementation Pattern
///
/// Each remote backend typically provides a [RemoteIntegration] that implements
/// both [RemoteUiAdapter] (this interface) and [RemoteMainHandler]:
///
/// - **Main thread**: [RemoteIntegration] provides UI integration + worker communication
/// - **Worker thread**: `*WorkerHandler` implements actual backend operations
///
/// Example:
/// ```dart
/// // Main thread (implements RemoteIntegration)
/// class SolidMainIntegration implements RemoteIntegration {
///   final SolidAuth solidAuth;
///
///   // RemoteUiAdapter properties (UI)
///   @override
///   String get id => 'solid';
///
///   @override
///   String get displayName => 'Solid Pod';
///
///   @override
///   IconData get icon => Icons.cloud;
///
///   @override
///   Auth get auth => solidAuth;
///
///   @override
///   Future<bool> showLogin(BuildContext context) async {
///     // Show Solid login UI
///   }
///
///   // RemoteMainHandler methods (worker communication)
///   // ... connector methods for worker thread ...
/// }
/// ```
library;

import 'package:flutter/widgets.dart';
import 'package:locorda_core/locorda_core.dart';

/// UI adapter for remote storage backends.
///
/// Defines the UI integration points for remote backends like Solid Pod,
/// Google Drive, etc. Implementations provide authentication UI, display
/// properties, and auth state management.
abstract interface class RemoteUiAdapter {
  /// Unique identifier for this remote backend (e.g., 'solid', 'gdrive').
  ///
  /// Used for programmatic lookup and persistence.
  /// Must be stable across app versions.
  String get id;

  /// Human-readable name for UI display (e.g., 'Solid Pod', 'Google Drive').
  String get displayName;

  /// Icon representing this remote backend in UI.
  IconData get icon;

  /// Authentication provider for this remote backend.
  ///
  /// Used to check auth state and trigger login/logout.
  Auth get auth;

  /// Shows login UI for this remote backend.
  ///
  /// Called when user taps "Connect" for this backend.
  /// Should present appropriate authentication flow (OAuth, WebID, etc.)
  ///
  /// Returns `true` if authentication succeeded, `false` otherwise.
  Future<bool> showLogin(BuildContext context);
}
