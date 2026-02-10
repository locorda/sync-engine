import 'package:locorda_core/locorda_core.dart';
import '../shared/worker_params.dart' show WorkerParams;
import 'worker_entry_point.dart' show WorkerContext;
import 'remote_worker_handler.dart' show RemoteMismatchException;

Future<EngineParams> toEngineParams(
    WorkerParams wp, WorkerContext context, SyncEngineConfig config,
    {String? activeStorageId, Iterable<String>? activeRemoteIds}) async {
  final workerHandlerContext = context.workerHandlerContext;
  if (wp.storages.isEmpty) {
    throw StateError('WorkerParams.storages must not be empty.');
  }

  final selectedStorageHandlers = activeStorageId == null
      ? [wp.storages.first]
      : wp.storages.where((storage) => storage.id == activeStorageId).toList();
  if (selectedStorageHandlers.length != 1) {
    final available = wp.storages.map((storage) => storage.id).toList();
    throw StateError('Expected exactly one storage for id "$activeStorageId" '
        'but found ${selectedStorageHandlers.length}. Available: $available');
  }

  final selectedStorageHandler = selectedStorageHandlers.single;

  final selectedRemotes = activeRemoteIds == null
      ? wp.remotes
      : wp.remotes
          .where((remote) => activeRemoteIds.contains(remote.id))
          .toList();
  if (activeRemoteIds != null) {
    final activeSet = activeRemoteIds.toSet();
    final selectedSet = selectedRemotes.map((remote) => remote.id).toSet();
    final missing = activeSet.difference(selectedSet);
    if (missing.isNotEmpty) {
      throw RemoteMismatchException(
        'Active remotes are missing worker handlers.',
        missingOnWorker: missing.toList(),
      );
    }
  }

  return EngineParams(
    storage: await selectedStorageHandler.create(workerHandlerContext, config),
    backends: await Future.wait(selectedRemotes
        .map((b) => b.createBackend(workerHandlerContext, config))),
    physicalTimestampFactory: wp.physicalTimestampFactory,
    installationIdFactory: wp.installationIdFactory,
    iriFactory: wp.iriFactory,
    rdfCore: wp.rdfCore,
    httpClient: wp.httpClient,
    fetcher: wp.fetcher,
    mappingBootstrapSources: wp.mappingBootstrapSources,
  );
}
