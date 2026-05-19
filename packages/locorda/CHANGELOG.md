## 0.5.2

 - **REFACTOR**(core): moved note_index_entry_regression_test to personal_notes_app to fix broken dev dependency. ([de742814](https://github.com/locorda/sync-engine/commit/de742814149857edd9db62d579d70a922600d153))
 - **FEAT**: update GDrive integration to use visible folder mode for easier file inspection. ([1e809e5d](https://github.com/locorda/sync-engine/commit/1e809e5d0befa641310d2dcbd403c918b7a1719c))
 - **DOCS**(locorda): add example/README.md for pub.dev example tab recognition. ([f628d407](https://github.com/locorda/sync-engine/commit/f628d407eb96f3187849921ff3d310ec9042aa04))
 - **DOCS**: reposition packages as BYOB offline-first sync. ([9a03fd0a](https://github.com/locorda/sync-engine/commit/9a03fd0a170ace56bc9a372aae2effea1949aa19))

## 0.5.1

## 0.5.0

- Initial public release
- Top-level facade package: re-exports `Locorda`, `ObjectSyncEngine`, `LocordaConfig`, `ResourceConfig` and storage layouts (`FilePerResource`, `ShardDataset`, `SingleFile`) from sub-packages
- Re-exports UI widgets `MultiBackendStatusWidget` and `SyncRefreshIndicator`
- Re-exports Drift storage handlers and worker entry points
- Re-exports all CRDT annotations (`@RootResource`, `@CrdtLwwRegister`, `@CrdtImmutable`, `@CrdtOrSet`)
- Includes Personal Notes App and minimal task-sync example applications