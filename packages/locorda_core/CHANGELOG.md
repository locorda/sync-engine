## 0.5.2

 - **REFACTOR**(core): moved note_index_entry_regression_test to personal_notes_app to fix broken dev dependency. ([de742814](https://github.com/locorda/sync-engine/commit/de742814149857edd9db62d579d70a922600d153))
 - **FIX**(objects): await save() in ObjectSyncEngine to prevent missing index entries. ([7cefead4](https://github.com/locorda/sync-engine/commit/7cefead4ebe6541a5c976c083710b445bcec4879))
 - **FIX**(single-file): include all shard graphs in re-upload on 304-path. ([1d3c3db6](https://github.com/locorda/sync-engine/commit/1d3c3db64acae5d6b0dd884a842b110c1754e3a3))
 - **FIX**(sync): recover missing gdrive folder and surface upload failures. ([6bffaded](https://github.com/locorda/sync-engine/commit/6bffadedf127092a3b7bdfbdb6540f950c07e123))
 - **DOCS**: reposition packages as BYOB offline-first sync. ([9a03fd0a](https://github.com/locorda/sync-engine/commit/9a03fd0a170ace56bc9a372aae2effea1949aa19))
 - **DOCS**: update README and add package reference documentation. ([2b5119c9](https://github.com/locorda/sync-engine/commit/2b5119c996e59dde864b461685a3a3d5b9e18ad8))

## 0.5.1

 - **FIX**(core): translate preloadedResourceDocIris IRIs in PipelineIriTranslatingRemoteSyncStorage. ([8ca4520b](https://github.com/locorda/sync-engine/commit/8ca4520b666c6001c04af7e0b0d58fd4c3a5d88b))

## 0.5.0

- Initial public release
- `SyncEngine`: core interface for CRDT merge operations, hydration streams, and sync lifecycle management
- `EngineParams` / `StandardSyncEngine`: concrete engine implementation wired to a `Storage` and a list of `Backend` instances
- Two-pass sync pipeline: fetch-and-merge phase followed by upload phase, with typed pipeline events (`ShardRefEvent`, `MergedResourceEvent`, `UploadedResourceEvent`, etc.)
- Three storage layout strategies: `FilePerResource` (one file per RDF resource), `ShardDataset` (packed shards, configurable count), `SingleFile` (everything in one file)
- `SyncManager` / `StandardSyncManager`: sync triggering, auto-sync scheduling, and status streaming (`SyncState`, `SyncStatus`)
- `Storage` interface with `InMemoryStorage` for testing; Drift-backed implementation in `locorda_drift`
- `Backend` / `PipelineBackend`: pluggable remote storage interface with upload/download result types and auth-retry support
- Hybrid Logical Clock (HLC) based CRDT merge: LWW-Register, OR-Set, FWW-Register and Immutable strategies
- `HydrationBatch`: typed batch of graph updates and deletion IDs delivered to the application on each sync cycle
- `SyncEngineConfig`: IRI-level configuration for resources, index types and root resource fetch policies
- `IriTranslator` hierarchy for local ↔ remote IRI mapping
- Index types: `FullIndexData` (monolithic) and `GroupIndexData` (partitioned by regex key) with `RootResourceFetchPolicy` (onRequest / prefetch)
