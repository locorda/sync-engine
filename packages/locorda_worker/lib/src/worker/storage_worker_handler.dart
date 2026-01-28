/// Worker-thread handler interface for local storage backends.
///
/// Defines the contract for creating storage instances in the worker thread.
/// Works together with [StorageMainHandler] on the main thread side.
///
/// This is separate from [RemoteWorkerHandler] to distinguish between:
/// - **Storage**: Local database (Drift) for offline-first operation
/// - **Remotes**: Cloud backends (Solid, GDrive) for sync
///
/// ## Example: Drift Storage
///
/// ```dart
/// class DriftWorkerHandler implements StorageWorkerHandler {
///   final LocordaDriftWebOptions? webOptions;
///
///   DriftWorkerHandler({this.webOptions});
///
///   @override
///   Future<Storage> create(WorkerContext context, SyncEngineConfig config) async {
///     return DriftStorage(
///       web: webOptions,
///       config: config,
///     );
///   }
/// }
/// ```
library;

import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_worker/worker.dart';

/// Worker-thread handler for creating local storage instances.
///
/// Implementations create and configure the local storage backend
/// (typically Drift/SQLite) that provides offline-first capabilities.
abstract class StorageWorkerHandler {
  /// Creates a storage instance for the worker thread.
  ///
  /// Called once during worker initialization. The [config] provides
  /// the sync engine configuration, and [context] provides access to
  /// any connectors from [StorageMainHandler.create].
  ///
  /// Returns a [Storage] implementation that handles local persistence.
  Future<Storage> create(WorkerContext context, SyncEngineConfig config);
}
