/// Worker-side API for Solid configuration connector (Pure Dart).
library;

import 'package:locorda_solid_core/locorda_solid_core.dart';
import 'package:locorda_worker/worker.dart';

import 'worker_solid_config_receiver.dart';

/// Worker-side config connector (Pure Dart).
class SolidConfigConnector {
  /// Receives SolidConfig from main thread.
  static Future<SolidConfig> receiveConfig(
      WorkerHandlerContext context, String id) {
    final receiver = WorkerSolidConfigReceiver(
      context.createChannel('locorda_solid/$id/solid_config'),
    );
    return receiver.getConfig();
  }
}
