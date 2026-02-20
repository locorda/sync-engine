import 'package:locorda_core/locorda_core.dart';
import 'package:logging/logging.dart';

import '../shared/worker_params.dart' show WorkerParams;
import 'worker_entry_point.dart' show WorkerContext;
import 'remote_worker_handler.dart' show RemoteMismatchException;

final _log = Logger('WorkerParamsToEngineParams');

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
  _log.info('Worker: Selected storage handler: ${selectedStorageHandler.id}');

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
  final remoteIds = selectedRemotes.map((r) => r.id).toList();
  _log.info('Worker: Selected remote handlers: $remoteIds');

  _log.info('Worker: Creating storage (${selectedStorageHandler.id})...');
  final storage =
      await selectedStorageHandler.create(workerHandlerContext, config);
  _log.info('Worker: Storage created successfully');

  _log.info('Worker: Creating ${selectedRemotes.length} remote backends...');
  final backends = await Future.wait(selectedRemotes
      .map((b) => b.createBackend(workerHandlerContext, config)));
  _log.info('Worker: All remote backends created');

  return EngineParams(
    storage: storage,
    backends: backends,
    physicalTimestampFactory: wp.physicalTimestampFactory,
    installationIdFactory: wp.installationIdFactory,
    iriFactory: wp.iriFactory,
    rdfCore: wp.rdfCore,
    httpClient: wp.httpClient,
    fetcher: wp.fetcher,
    mappingBootstrapSources: wp.mappingBootstrapSources,
  );
}
