import 'package:locorda_worker/worker_main.dart';

import '../shared/consts.dart';

import '../drift_options.dart';
import 'drift_config_connector.dart';
import 'drift_native_options_connector.dart';

class DriftMainHandler extends StorageMainHandler {
  @override
  final String id;
  final LocordaDriftWebOptions? _webOptions;

  DriftMainHandler({
    this.id = driftStorageHandlerId,
    LocordaDriftWebOptions? webOptions,
  }) : _webOptions = webOptions;

  @override
  List<MainHandlerFactory> create() {
    return [
      DriftNativeOptionsConnector.sender(id: id),
      DriftConfigConnector.sender(_webOptions, id),
    ];
  }
}
