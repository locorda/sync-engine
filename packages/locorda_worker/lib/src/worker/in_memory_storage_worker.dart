import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_worker/worker.dart';

class InMemoryStorageWorkerHandler extends StorageWorkerHandler {
  @override
  final String id;

  InMemoryStorageWorkerHandler({this.id = 'in_memory'});

  @override
  Future<Storage> create(
      WorkerHandlerContext context, SyncEngineConfig config) {
    return Future.value(InMemoryStorage());
  }
}
