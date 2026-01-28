import 'package:locorda_core/locorda_core.dart';
import '../shared/worker_params.dart' show WorkerParams;
import 'worker_entry_point.dart' show WorkerContext;

Future<EngineParams> toEngineParams(
    WorkerParams wp, WorkerContext context, SyncEngineConfig config) async {
  return EngineParams(
    storage: await wp.storage.create(context, config),
    backends: await Future.wait(
        wp.remotes.map((b) => b.createBackend(context, config))),
    physicalTimestampFactory: wp.physicalTimestampFactory,
    installationIdFactory: wp.installationIdFactory,
    iriFactory: wp.iriFactory,
    rdfCore: wp.rdfCore,
    httpClient: wp.httpClient,
    fetcher: wp.fetcher,
  );
}
