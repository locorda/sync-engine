## 0.5.2

 - **DOCS**: reposition packages as BYOB offline-first sync. ([9a03fd0a](https://github.com/locorda/sync-engine/commit/9a03fd0a170ace56bc9a372aae2effea1949aa19))

## 0.5.1

## 0.5.0

- Initial public release
- `DriftStorage`: Drift (SQLite) implementation of the `Storage` interface; supports all Flutter platforms (iOS, Android, Web, Windows, macOS, Linux)
- `DriftMainHandler`: main-thread handler that manages the Drift database lifecycle and coordinates with the worker
- `DriftWorkerHandler`: worker-thread storage handler; all SQLite I/O runs off the main thread
- `LocordaDriftNativeOptions` / `LocordaDriftWebOptions`: platform-specific Drift configuration (WAL mode, database path, etc.)
- Worker manifest (`locorda_worker.manifest.dart`) for auto-discovery by `locorda_builder`
