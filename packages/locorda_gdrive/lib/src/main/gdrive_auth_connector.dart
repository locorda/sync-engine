/// Main-thread bridge for Google Drive authentication in worker architecture.
///
/// Synchronizes authentication state from main thread to worker isolate.
library;

import 'package:locorda_gdrive/locorda_gdrive.dart';
import 'package:locorda_worker/worker_main.dart';

import 'gdrive_auth_sender.dart';

/// Worker plugin that bridges Google Drive authentication from main thread to worker.
///
/// This connector:
/// 1. Listens to [GDriveAuth.isAuthenticatedNotifier] for state changes
/// 2. Extracts OAuth2 credentials when authenticated
/// 3. Sends [UpdateAuthMessage] to worker via [WorkerChannel]
/// 4. Clears credentials in worker when logged out
/// 5. Handles token refresh requests from worker
///
/// The worker's [WorkerGDriveAuthProvider] receives these messages and provides
/// authentication for [GDriveBackend] HTTP requests.
///
/// ## Usage (Main Thread)
///
/// Register as plugin during sync system setup:
///
/// ```dart
/// final gdriveAuth = GDriveAuth(...);
/// await gdriveAuth.init();
///
/// final sync = await Locorda.createWithWorker(
///   engineParamsFactory: createEngineParams,
///   jsScript: 'worker.dart.js',
///   plugins: [
///     GDriveAuthConnector.sender(gdriveAuth),
///   ],
///   // ... other config
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
///   final authProvider = GDriveAuthConnector.receiver(context);
///   final backend = GDriveBackend(auth: authProvider);
///   // ... create storage and return EngineParams
/// }
/// ```
class GDriveAuthConnector {
  /// Creates a plugin factory for this connector.
  ///
  /// Pass the main thread's [authBridge] instance. The returned factory will be
  /// called by the worker framework with the [MainHandlerContext].
  static MainHandlerFactory sender(GDriveAuthProvider authBridge, String id) {
    return (MainHandlerContext context) {
      return GDriveAuthSender(
        authBridge: authBridge,
        workerHandle: context.createChannel('locorda_gdrive/${id}/gdrive_auth'),
      );
    };
  }
}
