## 0.5.0

- Initial public release
- `ObjectSyncEngine`: type-safe facade over `SyncEngine` that maps between Dart domain objects and RDF graphs via `RdfMapper`
- `LocordaConfig` / `ResourceConfig`: Dart-level configuration API (types, annotations, layouts) that is validated and converted to `SyncEngineConfig` internally
- `hydrateWithCallbacks<T>()`: stream-based hydration delivering decoded domain objects and deletion ids
- `save<T>()`, `deleteDocument<T>()`: typed save/delete operations
- `GroupIndexSyncFailedException`: structured error for group-index sync failures