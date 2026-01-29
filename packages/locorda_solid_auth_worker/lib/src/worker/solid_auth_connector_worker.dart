/// Worker-side API for Solid authentication connector (Pure Dart).
///
/// This file provides only the receiver side without Flutter dependencies.
/// Used in web workers and native isolates.
library;

import 'package:locorda_solid_core/locorda_solid_core.dart';
import 'package:locorda_worker/worker.dart';

import 'worker_solid_auth_provider.dart';

/// Worker-side auth connector (Pure Dart).
///
/// Only provides receiver() method for use in workers.
class SolidAuthConnector {
  /// Creates auth provider for worker context.
  ///
  /// Call this in the worker entry point to create a [SolidAuthProvider]
  /// that receives credentials from the main thread and generates DPoP tokens
  /// locally for HTTP requests.
  ///
  /// Example:
  /// ```dart
  /// Future<EngineParams> createEngineParams(
  ///   SyncEngineConfig config,
  ///   WorkerContext context,
  /// ) async {
  ///   final authProvider = SolidAuthConnector.receiver(context);
  ///   final backend = SolidBackend(auth: authProvider);
  ///   // ... return EngineParams
  /// }
  /// ```
  static SolidAuthProvider receiver(WorkerHandlerContext context) {
    return SolidAuthReceiver(
        context.createChannel("locorda_solid_auth_worker/solid_auth"));
  }
}
