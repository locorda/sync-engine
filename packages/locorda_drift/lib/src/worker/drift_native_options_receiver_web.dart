/// Pure Dart implementation of Drift native options receiver.
///
/// Shared by both drift_native_options_connector_worker.dart (exported via worker.dart)
/// and drift_native_options_connector.dart (main thread can also call receiver).
///
/// This file has no Flutter dependencies and can be used in web workers.
library;

import 'dart:async';

import 'package:locorda_worker/worker.dart';

import '../drift_options.dart';

// No-Op implementation for web:
class DriftNativeOptionsReceiver {
  static Future<LocordaDriftNativeOptions> receiver(
    WorkerHandlerContext context, {
    Duration timeout = const Duration(seconds: 5),
  }) =>
      Future.value(LocordaDriftNativeOptions());
}
