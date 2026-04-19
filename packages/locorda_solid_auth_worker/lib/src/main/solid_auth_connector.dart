/// Main-thread bridge for Solid authentication in worker architecture.
///
/// Synchronizes authentication state from main thread to worker isolate.
library;

import 'package:locorda_worker/worker_main.dart';
import 'package:solid_oidc_auth/solid_oidc_auth.dart';

import 'solid_auth_sender.dart';

/// Worker plugin that bridges Solid authentication from main thread to worker.
///
/// This connector:
/// 1. Listens to [SolidAuth.isAuthenticatedNotifier] for state changes
/// 2. Extracts DPoP credentials and WebID when authenticated
/// 3. Sends [UpdateAuthMessage] to worker via [WorkerChannel]
/// 4. Clears credentials in worker when logged out
///
/// The worker's [SolidAuthReceiver] receives these messages and provides
/// authentication for [SolidBackend] HTTP requests.
///
/// ## Usage
///
/// Register as plugin during sync system setup:
///
/// ```dart
/// final solidAuth = SolidAuth(...);
/// await solidAuth.init();
///
/// final sync = await Locorda.createWithWorker(
///   engineParamsFactory: createEngineParams,
///   jsScript: 'worker.dart.js',
///   plugins: [
///     SolidAuthConnector.sender(solidAuth),
///   ],
///   // ... other config
/// );
/// ```
///
/// In worker, create the SyncEngine instance:
///
/// ```dart
/// Future<SyncEngine> createEngineParams(
///   SyncEngineConfig config,
///   WorkerContext context,
/// ) async {
///   final authProvider = SolidAuthConnector.receiver(context);
///   final backend = SolidBackend(auth: authProvider);
///   // ... create storage and return SyncEngine
/// }
/// ```
class SolidAuthConnector {
  /// Creates a plugin factory for this connector.
  ///
  /// Pass the main thread's [solidAuth] instance. The returned factory will be
  /// called by the worker framework with the [MainHandlerContext].
  static MainHandlerFactory sender(SolidOidcAuth solidAuth, String id) {
    return (MainHandlerContext context) {
      return SolidAuthSender(
        solidAuth: solidAuth,
        workerHandle:
            context.createChannel('locorda_solid_auth_worker/$id/solid_auth'),
      );
    };
  }
}
