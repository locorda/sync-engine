## 0.5.2

 - **DOCS**: reposition packages as BYOB offline-first sync. ([9a03fd0a](https://github.com/locorda/sync-engine/commit/9a03fd0a170ace56bc9a372aae2effea1949aa19))

## 0.5.1

## 0.5.0

- Initial public release
- `Locorda`: top-level Flutter facade wrapping `ObjectSyncEngine` with worker lifecycle and UI adapter registry
- `Locorda.create()`: factory that spawns the worker thread/isolate, wires backend handlers and returns a fully initialised instance
- Exposes `syncManager` (manual trigger, status stream, auto-sync control) and `uiAdapterRegistry` (multi-backend UI integration)
- Re-exports `CrdtIndexConfig`, `FullIndexConfig`, `GroupIndexConfig`, `RootResourceFetchPolicy`, `ResourceConfig` and related index configuration types