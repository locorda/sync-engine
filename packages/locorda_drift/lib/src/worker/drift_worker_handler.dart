import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_worker/worker.dart';

import '../drift_options.dart' show LocordaDriftWebOptions;
import '../drift_storage.dart' show DriftStorage;
import '../shared/consts.dart';
import 'drift_config_connector_worker.dart';
import 'drift_native_options_connector_worker.dart';

export '../drift_options.dart' show LocordaDriftWebOptions;

class DriftWorkerHandler extends StorageWorkerHandler {
  @override
  final String id;
  final bool _web;
  final bool _native;
  DriftWorkerHandler(
      {this.id = driftStorageHandlerId, bool web = true, bool native = true})
      : _web = web,
        _native = native;

  @override
  Future<Storage> create(
      WorkerHandlerContext context, SyncEngineConfig config) async {
    return await DriftStorage.create(
      web: _web ? await DriftConfigConnector.receiveConfig(context, id) : null,
      native: _native
          ? await DriftNativeOptionsConnector.receiver(context, id)
          : null,
    );
  }
}
