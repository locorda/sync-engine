/// Plugin system for extending worker functionality.
///
/// Plugins run on main thread and can communicate with worker via [LocordaWorker].
/// Common use cases: authentication bridges, custom sync strategies, monitoring.
library;

import 'locorda_worker.dart';

/// Factory for creating worker plugins with access to the worker handle.
///
/// The framework calls this factory after worker creation, passing the handle
/// for communication with the worker thread.
typedef WorkerPluginFactory = WorkerPlugin Function(LocordaWorker workerHandle);

/// Plugin interface for main-thread components that interact with worker.
///
/// Plugins are initialized after worker creation and disposed before worker shutdown.
/// Use [WorkerChannel] via the worker handle for custom message passing.
///
/// Example: Authentication bridge that forwards credentials to worker
/// ```dart
/// class AuthPlugin implements WorkerPlugin {
///   final Auth _auth;
///   final LocordaWorker _worker;
///
///   AuthPlugin(this._auth, this._worker);
///
///   @override
///   Future<void> initialize() async {
///     _auth.onStateChange.listen((state) {
///       _worker.sendMessage({'auth': state.toJson()});
///     });
///   }
///
///   @override
///   Future<void> dispose() async {
///     // Clean up listeners
///   }
/// }
/// ```
abstract interface class WorkerPlugin {
  /// Initialize plugin after worker is ready.
  ///
  /// Called once during worker setup. Perform subscriptions, send initial
  /// state, or register handlers here.
  Future<void> initialize();

  /// Clean up plugin resources before worker shutdown.
  ///
  /// Called once during worker disposal. Remove listeners, close streams, etc.
  Future<void> dispose();
}
