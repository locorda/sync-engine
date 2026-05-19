## 0.5.2

 - **FIX**(objects): await save() in ObjectSyncEngine to prevent missing index entries. ([7cefead4](https://github.com/locorda/sync-engine/commit/7cefead4ebe6541a5c976c083710b445bcec4879))
 - **DOCS**: reposition packages as BYOB offline-first sync. ([9a03fd0a](https://github.com/locorda/sync-engine/commit/9a03fd0a170ace56bc9a372aae2effea1949aa19))

## 0.5.1

## 0.5.0

- Initial public release
- `ObjectSyncEngine`: type-safe facade over `SyncEngine` that maps between Dart domain objects and RDF graphs via `RdfMapper`
- `LocordaConfig` / `ResourceConfig`: Dart-level configuration API (types, annotations, layouts) that is validated and converted to `SyncEngineConfig` internally
- `hydrateWithCallbacks<T>()`: stream-based hydration delivering decoded domain objects and deletion ids
- `save<T>()`, `deleteDocument<T>()`: typed save/delete operations
- `GroupIndexSyncFailedException`: structured error for group-index sync failures