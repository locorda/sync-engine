/// Worker-based architecture for offloading heavy operations to isolate/worker.
///
/// Use this API to run SyncEngine in a separate thread, keeping the
/// main thread responsive for UI.
library;

export 'src/main/locorda_worker.dart' show LocordaWorker;
export 'src/main/remote_main_handler.dart' show RemoteMainHandler;
export 'src/main/storage_main_handler.dart' show StorageMainHandler;
export 'src/main/sync_engine_with_worker.dart' show SyncEngineWithWorker;
export 'src/main/worker_plugin.dart' show WorkerPlugin, WorkerPluginFactory;
export 'src/shared/worker_params.dart' show WorkerSetup, WorkerParams;
