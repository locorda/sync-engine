import 'package:locorda_worker/worker_main.dart';

import 'drift_native_options_connector.dart';

class DriftMainHandler extends StorageMainHandler {
  @override
  List<MainHandlerFactory> create() {
    return [DriftNativeOptionsConnector.sender()];
  }
}
