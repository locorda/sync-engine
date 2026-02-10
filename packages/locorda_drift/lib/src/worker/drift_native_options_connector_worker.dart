/// Worker-side API for Drift native options connector (Pure Dart).
///
/// This file delegates to DriftNativeOptionsReceiver for the actual implementation.
/// Used in web workers and native isolates via the worker.dart export.
library;

import 'dart:async';

import 'package:locorda_worker/worker.dart';

import '../drift_options.dart';
import 'drift_native_options_receiver_native.dart'
    if (dart.library.html) 'drift_native_options_receiver_web.dart';

/// Worker-side Drift native options connector (Pure Dart).
///
/// Provides receiver() method for use in workers. This is a thin wrapper
/// around DriftNativeOptionsReceiver to maintain consistent API naming.
class DriftNativeOptionsConnector {
  /// Worker-side receiver that waits for database paths from main thread.
  ///
  /// Call this in the worker's engine params factory to get native options:
  ///
  /// ```dart
  /// Future<EngineParams> createEngineParams(
  ///   SyncEngineConfig config,
  ///   WorkerContext context,
  /// ) async {
  ///   final nativeOptions = await DriftNativeOptionsConnector.receiver(context);
  ///   final storage = await DriftStorage.create(
  ///     web: LocordaDriftWebOptions(...),
  ///     native: nativeOptions,
  ///   );
  ///   // ... return EngineParams
  /// }
  /// ```
  ///
  /// Throws [TimeoutException] after 5 seconds if no response is received,
  /// with helpful error message about missing plugin registration.
  static Future<LocordaDriftNativeOptions> receiver(
    WorkerHandlerContext context, String id, {
    Duration timeout = const Duration(seconds: 5),
  }) =>
      DriftNativeOptionsReceiver.receiver(context, id, timeout: timeout);
}
