import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_worker/worker.dart';
import 'package:logging/logging.dart';

import '../drift_storage.dart' show DriftStorage;
import '../shared/consts.dart';
import 'drift_config_connector_worker.dart';
import 'drift_native_options_connector_worker.dart';

import '../drift_options.dart';
export '../drift_options.dart' show LocordaDriftWebOptions;

final _log = Logger('DriftWorkerHandler');

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
    _log.info('DriftWorkerHandler[$id]: Creating DriftStorage...');

    _log.info('DriftWorkerHandler[$id]: Waiting for settings from main...');
    final settings = await DriftConfigConnector.receiveConfig(context, id);
    _log.info('DriftWorkerHandler[$id]: Settings received '
        '(hasWebOptions: ${settings.webOptions != null}, '
        'deduplicateOnLoad: ${settings.deduplicateOnLoad})');

    LocordaDriftNativeWorkerOptions? nativeOpts;
    if (_native) {
      _log.info(
          'DriftWorkerHandler[$id]: Requesting native options from main...');
      nativeOpts = await DriftNativeOptionsConnector.receiver(context, id);
      _log.info('DriftWorkerHandler[$id]: Native options received');
    }

    _log.info(
        'DriftWorkerHandler[$id]: All options received, creating DriftStorage...');
    final storage = await DriftStorage.create(
      web: _web ? settings.webOptions : null,
      native: nativeOpts,
      deduplicateOnLoad: settings.deduplicateOnLoad,
      perflog: context.perflog,
    );
    _log.info('DriftWorkerHandler[$id]: DriftStorage created successfully');
    return storage;
  }
}
