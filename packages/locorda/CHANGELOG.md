## 0.5.1

## 0.5.0

- Initial public release
- Top-level facade package: re-exports `Locorda`, `ObjectSyncEngine`, `LocordaConfig`, `ResourceConfig` and storage layouts (`FilePerResource`, `ShardDataset`, `SingleFile`) from sub-packages
- Re-exports UI widgets `MultiBackendStatusWidget` and `SyncRefreshIndicator`
- Re-exports Drift storage handlers and worker entry points
- Re-exports all CRDT annotations (`@RootResource`, `@CrdtLwwRegister`, `@CrdtImmutable`, `@CrdtOrSet`)
- Includes Personal Notes App and minimal task-sync example applications