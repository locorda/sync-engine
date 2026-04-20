/// Worker-side API for Drift configuration connector (Pure Dart).
library;

import 'package:locorda_worker/worker.dart';

import '../shared/drift_config_messages.dart';
import 'worker_drift_config_receiver.dart';

/// Worker-side config connector for Drift storage settings.
class DriftConfigConnector {
  /// Receives Drift storage settings from the main thread.
  static Future<DriftSettingsMessage> receiveConfig(
      WorkerHandlerContext context, String id,
      {Duration timeout = const Duration(seconds: 2)}) {
    final receiver = WorkerDriftConfigReceiver(
      context.createChannel('locorda_drift/$id/drift_config'),
    );
    return receiver.getConfig(timeout: timeout);
  }
}
