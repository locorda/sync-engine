## 0.5.2

 - **DOCS**: reposition packages as BYOB offline-first sync. ([9a03fd0a](https://github.com/locorda/sync-engine/commit/9a03fd0a170ace56bc9a372aae2effea1949aa19))

## 0.5.1

## 0.5.0

- Initial public release
- Platform-agnostic worker infrastructure: Dart Isolates on native, Web Workers on web
- `workerMain()`: worker entry point; accepts a `WorkerParams` factory and routes all framework messages
- `WorkerParams`: declares storage handlers, remote handlers and CRDT mapping bootstrap data for the worker
- `ProxySyncEngine`: main-thread transparent proxy — all `SyncEngine` calls are forwarded to the worker
- `SyncManager` support: sync triggering, auto-sync scheduling and status streaming work seamlessly across the thread boundary
- Plugin system via `WorkerChannel`: bidirectional pub/sub for cross-thread concerns such as authentication bridges
- `StorageMainHandler` / `StorageWorkerHandler`: split storage interface for main ↔ worker storage coordination
- Worker manifest system: packages expose a `locorda_worker.manifest.dart` that is auto-discovered by `locorda_builder`
