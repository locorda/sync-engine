/// Worker-side API for Drift web configuration connector (Pure Dart).
library;

import 'package:locorda_worker/worker.dart';

import '../drift_options.dart';
import 'worker_drift_config_receiver.dart';

/// Worker-side config connector for Drift web options.
class DriftConfigConnector {
  /// Receives Drift web options from the main thread.
  static Future<LocordaDriftWebOptions?> receiveConfig(
      WorkerHandlerContext context, String id,
      {Duration timeout = const Duration(seconds: 2)}) {
    final receiver = WorkerDriftConfigReceiver(
      context.createChannel('locorda_drift/$id/drift_config'),
    );
    return receiver.getConfig(timeout: timeout);
  }
}
