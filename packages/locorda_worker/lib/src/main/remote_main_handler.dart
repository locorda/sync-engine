/// Main-thread handler interface for remote backends.
///
/// Defines the contract for integrating remote storage backends
/// (Solid Pod, Google Drive, etc.) on the main thread side.
/// Works together with [RemoteWorkerHandler] implementations in the worker thread.
///
/// This handler is responsible for:
/// - Providing worker-thread connectors for communication
/// - Unique identification matching worker-side handler
///
/// Note: For full remote backend integration including UI,
/// implementations typically also implement [RemoteUiAdapter] via [RemoteIntegration].
library;

import 'main_handler.dart';

/// Main-thread handler for remote backend communication.
///
/// Each remote backend (Solid, GDrive) provides a main-thread handler
/// that manages worker communication. This is typically combined with
/// [RemoteUiAdapter] in a [RemoteIntegration] implementation.
///
/// ## Implementation Pattern
///
/// Most applications implement [RemoteIntegration] which combines this
/// interface with [RemoteUiAdapter]:
///
/// ```dart
/// class SolidMainIntegration implements RemoteIntegration {
///   final SolidAuth _solidAuth;
///
///   // RemoteMainHandler implementation
///   @override
///   String get id => 'solid';
///
///   @override
///   List<WorkerPluginFactory> get workerConnectors => [
///     SolidAuthConnector.sender(_solidAuth),
///   ];
///
///   // RemoteUiAdapter implementation
///   @override
///   String get displayName => 'Solid Pod';
///
///   @override
///   Auth get auth => _solidAuth;
///
///   @override
///   Future<bool> showLogin(BuildContext context) async {
///     // Show Solid login UI
///   }
/// }
/// ```
abstract interface class RemoteMainHandler {
  /// Unique identifier for this remote backend (e.g., 'solid', 'gdrive').
  ///
  /// Must match [RemoteWorkerHandler.id] of the corresponding worker-side handler.
  /// Used for validation and routing between main and worker threads.
  String get id;

  /// Worker thread connector factories for main-to-worker communication.
  ///
  /// These factories create plugins that bridge data from the main thread
  /// (e.g., auth credentials, configuration) to the worker thread.
  ///
  /// Example:
  /// ```dart
  /// @override
  /// List<WorkerPluginFactory> get workerConnectors => [
  ///   SolidAuthConnector.sender(solidAuth),  // Sends auth to worker
  /// ];
  /// ```
  List<MainHandlerFactory> get workerConnectors;
}
