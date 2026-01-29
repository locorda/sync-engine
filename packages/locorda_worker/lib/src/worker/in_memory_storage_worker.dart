import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_worker/worker.dart';

class InMemoryStorageWorkerHandler extends StorageWorkerHandler {
  @override
  Future<Storage> create(
      WorkerHandlerContext context, SyncEngineConfig config) {
    return Future.value(InMemoryStorage());
  }
}
