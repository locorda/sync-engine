/// Solid Pod storage plugin - worker thread implementation.
library solid_worker_plugin;

import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_solid_core/locorda_solid_core.dart';
import 'package:locorda_solid_auth_worker/worker.dart';
import 'package:locorda_worker/worker.dart';

/// Worker-thread [RemoteWorkerHandler] implementation for Solid Pod backend.
///
/// Creates [SolidBackend] instances in the worker thread for Pod communication.
/// This plugin handles all backend operations:
/// - HTTP requests to Solid Pods
/// - DPoP token generation
/// - RDF graph fetching and pushing

/// ## Main Thread Counterpart
///
/// This plugin requires a corresponding [SolidMainHandler] on the main thread.
/// The main thread handles authentication and sends credentials
/// to the worker via [SolidAuthConnector].
class SolidWorkerHandler implements RemoteWorkerHandler {
  @override
  String get id => 'solid';

  @override
  Future<Backend> createBackend(
          WorkerHandlerContext context, SyncEngineConfig config) async =>
      SolidBackend(
        auth: SolidAuthConnector.receiver(context),
      );
}
