/// Worker-thread handler interface for remote backends.
///
/// Defines the contract for creating backend instances in the worker thread.
/// Each remote backend must provide both a main-thread handler
/// ([RemoteMainHandler]) and a worker-thread handler ([RemoteWorkerHandler]).
///
/// ## Main vs Worker Separation
///
/// - **Main thread**: UI, authentication, user interaction ([RemoteMainHandler])
/// - **Worker thread**: HTTP, CRDT operations, backend communication ([RemoteWorkerHandler])
///
/// These run in separate isolates/threads and cannot share code directly.
/// Each remote backend provides separate handlers for both sides.
///
/// ## Example: Solid Pod Backend
///
/// ```dart
/// // Main thread - provides auth connector
/// class SolidMainIntegration implements RemoteIntegration {
///   final SolidAuth solidAuth;
///
///   @override
///   String get id => 'solid';
///
///   @override
///   List<WorkerPluginFactory> get workerConnectors => [
///     SolidAuthConnector.sender(solidAuth),  // Sends auth to worker
///   ];
/// }
///
/// // Worker thread - creates actual backend
/// class SolidWorkerHandler implements RemoteWorkerHandler {
///   @override
///   String get id => 'solid';
///
///   @override
///   Future<Backend> createBackend(WorkerContext context, SyncEngineConfig config) async {
///     return SolidBackend(
///       auth: SolidAuthConnector.receiver(context),  // Receives auth from main
///     );
///   }
/// }
/// ```
///
/// ## Validation
///
/// The framework automatically validates that handlers registered on the main
/// thread have corresponding worker-side implementations. If a handler is
/// missing on either side, a [RemoteMismatchException] is thrown with
/// a helpful error message.
library;

import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_worker/worker.dart';

/// Worker-thread handler for creating remote backend instances.
///
/// This interface must be implemented for each remote backend type
/// (Solid Pod, Google Drive, etc.) to provide the worker-thread
/// component of the handler architecture.
///
/// The [id] must match the corresponding [RemoteMainHandler.id] on the
/// main thread for validation to succeed.
abstract interface class RemoteWorkerHandler {
  /// Unique identifier matching the main-thread handler.
  ///
  /// Must be identical to [RemoteMainHandler.id] for the same backend.
  /// Examples: 'solid', 'gdrive'
  String get id;

  /// Creates a backend instance for this remote handler.
  ///
  /// Called once during worker initialization. The [context] provides
  /// access to connector receivers that receive data from the main thread
  /// (e.g., authentication credentials from [RemoteMainHandler.workerConnectors]).
  ///
  /// Example:
  /// ```dart
  /// @override
  /// Future<Backend> createBackend(WorkerContext context, SyncEngineConfig config) async {
  ///   return SolidBackend(
  ///     auth: SolidAuthConnector.receiver(context),
  ///   );
  /// }
  /// ```
  Future<Backend> createBackend(
      WorkerHandlerContext context, SyncEngineConfig config);
}

/// Exception thrown when main and worker handler registrations don't match.
///
/// This indicates that a remote handler was registered on one side (main or worker)
/// but is missing on the other side, which would cause runtime failures.
class RemoteMismatchException implements Exception {
  final String message;
  final List<String> missingOnWorker;
  final List<String> missingOnMain;

  RemoteMismatchException(
    this.message, {
    this.missingOnWorker = const [],
    this.missingOnMain = const [],
  });

  @override
  String toString() {
    final buffer = StringBuffer('RemoteMismatchException: $message\n');

    if (missingOnWorker.isNotEmpty) {
      buffer.writeln(
          '\nHandlers registered on main thread but missing on worker:');
      for (final id in missingOnWorker) {
        buffer.writeln('  - $id');
        buffer.writeln(
            '    Add: ${_capitalize(id)}WorkerHandler() to worker setup');
      }
    }

    if (missingOnMain.isNotEmpty) {
      buffer.writeln(
          '\nHandlers registered on worker but missing on main thread:');
      for (final id in missingOnMain) {
        buffer.writeln('  - $id');
        buffer.writeln(
            '    Add: ${_capitalize(id)}MainHandler() to remotes list');
      }
    }

    return buffer.toString();
  }

  String _capitalize(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}
