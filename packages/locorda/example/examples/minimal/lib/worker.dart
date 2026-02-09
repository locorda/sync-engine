/// Worker entry point for minimal task sync example.
library;

import 'package:locorda/worker.dart';
import 'package:locorda_dir/worker.dart';
import 'package:locorda_worker/worker.dart';

// #docregion worker-setup
/// Worker entry point (runs in isolate/web worker).
void main() {
  workerMain(setupWorkerEngine);
}

/// Configure SyncEngine in the worker.
Future<WorkerParams> setupWorkerEngine() async => WorkerParams(
      // Must match main thread remotes
      remotes: [DirWorkerHandler(id: 'local_dir')],
      
      // InMemoryStorage for worker
      storage: InMemoryStorageWorkerHandler(),
    );
// #enddocregion worker-setup
