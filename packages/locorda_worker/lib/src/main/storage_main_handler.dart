/// Main-thread handler interface for local storage backends.
///
/// Defines the contract for integrating local storage backends (Drift/SQLite)
/// on the main thread side. Works together with [StorageWorkerHandler]
/// implementations in the worker thread.
///
/// This is separate from [RemoteMainHandler] to distinguish between:
/// - **Storage**: Local database (Drift) for offline-first operation
/// - **Remotes**: Cloud backends (Solid, GDrive) for sync
///
/// ## Example: Drift Storage
///
/// ```dart
/// class DriftMainHandler implements StorageMainHandler {
///   @override
///   List<WorkerPluginFactory> create() {
///     // Drift typically doesn't need main-to-worker connectors
///     // Configuration is passed directly to worker
///     return [];
///   }
/// }
/// ```
library;

import 'main_handler.dart';

/// Main-thread handler for local storage backend.
///
/// Provides worker thread connector factories for communicating storage
/// configuration from main thread to worker thread.
abstract class StorageMainHandler {
  /// Creates worker connector factories for storage configuration.
  ///
  /// Returns a list of factories that create plugins for bridging
  /// storage-related data to the worker thread. For most storage backends
  /// (like Drift), this returns an empty list as configuration is passed
  /// directly to [StorageWorkerHandler.create].
  List<MainHandlerFactory> create();
}
