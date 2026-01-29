import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_worker/worker.dart';

import '../drift_options.dart' show LocordaDriftWebOptions;
import '../drift_storage.dart' show DriftStorage;
import 'drift_native_options_connector_worker.dart';

export '../drift_options.dart' show LocordaDriftWebOptions;

class DriftWorkerHandler extends StorageWorkerHandler {
  final LocordaDriftWebOptions? _web;
  final bool _native;
  DriftWorkerHandler({LocordaDriftWebOptions? web, bool native = true})
      : _web = web,
        _native = native;

  @override
  Future<Storage> create(
      WorkerHandlerContext context, SyncEngineConfig config) async {
    return await DriftStorage.create(
      web: _web,
      native:
          _native ? await DriftNativeOptionsConnector.receiver(context) : null,
    );
  }
}
