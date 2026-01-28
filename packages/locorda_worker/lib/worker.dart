/// Worker-based architecture for offloading heavy operations to isolate/worker.
///
/// Use this API to run SyncEngine in a separate thread, keeping the
/// main thread responsive for UI.
library;

export 'src/shared/worker_params.dart' show WorkerParams, WorkerSetup;
export 'src/worker/in_memory_storage_worker.dart'
    show InMemoryStorageWorkerHandler;
export 'src/worker/worker_channel.dart' show WorkerChannel;
export 'src/worker/worker_entry_point.dart' show workerMain, WorkerContext;
export 'src/worker/remote_worker_handler.dart'
    show RemoteWorkerHandler, RemoteMismatchException;
export 'src/worker/storage_worker_handler.dart' show StorageWorkerHandler;
