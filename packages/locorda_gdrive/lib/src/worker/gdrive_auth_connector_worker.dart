/// Main-thread bridge for Google Drive authentication in worker architecture.
///
/// Synchronizes authentication state from main thread to worker isolate.
library;

import 'package:locorda_worker/worker.dart';

import '../auth/gdrive_auth_provider.dart';
import 'worker_gdrive_auth_provider.dart';

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
  /// Creates auth provider for worker context.
  ///
  /// Call this in the worker entry point to create a [GDriveAuthProvider]
  /// that receives credentials from the main thread for HTTP requests.
  ///
  /// Example:
  /// ```dart
  /// void workerEntryPoint() {
  ///   startWorkerIsolate((context) async {
  ///     final authProvider = GDriveAuthConnector.receiver(context);
  ///     final backend = GDriveBackend(auth: authProvider);
  ///   });
  /// }
  /// ```
  static GDriveAuthProvider receiver(WorkerContext context) {
    return WorkerGDriveAuthProvider(context.channel);
  }
}
