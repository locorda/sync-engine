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
