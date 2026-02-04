/// Main-thread bridge for local directory authentication in worker architecture.
///
/// Synchronizes authentication state from main thread to worker isolate.
library;

import 'package:locorda_worker/worker_main.dart';

import '../auth/dir_auth.dart';
import 'dir_auth_sender.dart';

/// Worker plugin that bridges local directory authentication from main thread to worker.
///
/// This connector:
/// 1. Listens to [DirAuth.isAuthenticatedNotifier] for state changes
/// 2. Sends enable/disable state to worker via [WorkerChannel]
/// 3. Sends sync directory path to worker
///
/// The worker's [WorkerDirAuthProvider] receives these messages and provides
/// authentication for [DirBackend] file operations.
///
/// ## Usage (Main Thread)
///
/// Register as plugin during sync system setup:
///
/// ```dart
/// final dirAuth = await DirAuth.create(...);
///
/// final sync = await Locorda.createWithWorker(
///   plugins: [
///     DirAuthConnector.sender(dirAuth),
///   ],
/// );
/// ```
///
/// ## Usage (Worker Thread)
///
/// Create the auth provider in worker entry point:
///
/// ```dart
/// Future<EngineParams> createEngineParams(
///   SyncEngineConfig config,
///   WorkerContext context,
/// ) async {
///   final authProvider = DirAuthConnector.receiver(context);
///   final backend = DirBackend(auth: authProvider, ...);
/// }
/// ```
class DirAuthConnector {
  /// Creates a plugin factory for this connector.
  ///
  /// Pass the main thread's [dirAuth] instance. The returned factory will be
  /// called by the worker framework with the [MainHandlerContext].
  static MainHandlerFactory sender(DirAuth dirAuth, String id) {
    return (MainHandlerContext context) {
      return DirAuthSender(
        dirAuth: dirAuth,
        workerHandle: context.createChannel('locorda_dir/$id/dir_auth'),
      );
    };
  }
}
