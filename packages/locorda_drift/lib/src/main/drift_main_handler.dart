import 'package:locorda_worker/worker_main.dart';

import '../shared/consts.dart';

import 'drift_native_options_connector.dart';

class DriftMainHandler extends StorageMainHandler {
  @override
  final String id;

  DriftMainHandler({this.id = driftStorageHandlerId});

  @override
  List<MainHandlerFactory> create() {
    return [DriftNativeOptionsConnector.sender()];
  }
}
