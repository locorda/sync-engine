# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

## 2026-05-19

### Changes

---

Packages with breaking changes:

 - There are no breaking changes in this release.

Packages with other changes:

 - [`locorda_core` - `v0.5.2`](#locorda_core---v052)
 - [`locorda_annotations` - `v0.5.2`](#locorda_annotations---v052)
 - [`locorda_builder` - `v0.5.2`](#locorda_builder---v052)
 - [`locorda_objects` - `v0.5.2`](#locorda_objects---v052)
 - [`locorda_init_generator` - `v0.5.2`](#locorda_init_generator---v052)
 - [`locorda_dev` - `v0.5.2`](#locorda_dev---v052)
 - [`locorda_dir` - `v0.5.2`](#locorda_dir---v052)
 - [`locorda_drift` - `v0.5.2`](#locorda_drift---v052)
 - [`locorda_flutter_core` - `v0.5.2`](#locorda_flutter_core---v052)
 - [`locorda_flutter` - `v0.5.2`](#locorda_flutter---v052)
 - [`locorda_gdrive` - `v0.5.2`](#locorda_gdrive---v052)
 - [`locorda_mapping_bootstrap_generator` - `v0.5.2`](#locorda_mapping_bootstrap_generator---v052)
 - [`locorda_solid_auth` - `v0.5.2`](#locorda_solid_auth---v052)
 - [`locorda_solid_auth_worker` - `v0.5.2`](#locorda_solid_auth_worker---v052)
 - [`locorda_solid_core` - `v0.5.2`](#locorda_solid_core---v052)
 - [`locorda_solid` - `v0.5.2`](#locorda_solid---v052)
 - [`locorda_ui` - `v0.5.2`](#locorda_ui---v052)
 - [`locorda_worker` - `v0.5.2`](#locorda_worker---v052)
 - [`locorda` - `v0.5.2`](#locorda---v052)

---

#### `locorda_core` - `v0.5.2`

 - **REFACTOR**(core): moved note_index_entry_regression_test to personal_notes_app to fix broken dev dependency. ([de742814](https://github.com/locorda/sync-engine/commit/de742814149857edd9db62d579d70a922600d153))
 - **FIX**(objects): await save() in ObjectSyncEngine to prevent missing index entries. ([7cefead4](https://github.com/locorda/sync-engine/commit/7cefead4ebe6541a5c976c083710b445bcec4879))
 - **FIX**(single-file): include all shard graphs in re-upload on 304-path. ([1d3c3db6](https://github.com/locorda/sync-engine/commit/1d3c3db64acae5d6b0dd884a842b110c1754e3a3))
 - **FIX**(sync): recover missing gdrive folder and surface upload failures. ([6bffaded](https://github.com/locorda/sync-engine/commit/6bffadedf127092a3b7bdfbdb6540f950c07e123))
 - **DOCS**: reposition packages as BYOB offline-first sync. ([9a03fd0a](https://github.com/locorda/sync-engine/commit/9a03fd0a170ace56bc9a372aae2effea1949aa19))
 - **DOCS**: update README and add package reference documentation. ([2b5119c9](https://github.com/locorda/sync-engine/commit/2b5119c996e59dde864b461685a3a3d5b9e18ad8))

#### `locorda_annotations` - `v0.5.2`

 - **DOCS**: reposition packages as BYOB offline-first sync. ([9a03fd0a](https://github.com/locorda/sync-engine/commit/9a03fd0a170ace56bc9a372aae2effea1949aa19))

#### `locorda_builder` - `v0.5.2`

 - **FIX**(dependencies): update analyzer version constraint to support Dart SDK range. ([f738f93b](https://github.com/locorda/sync-engine/commit/f738f93b94560dd96b94d86238ae2603f0437a41))
 - **DOCS**: reposition packages as BYOB offline-first sync. ([9a03fd0a](https://github.com/locorda/sync-engine/commit/9a03fd0a170ace56bc9a372aae2effea1949aa19))

#### `locorda_objects` - `v0.5.2`

 - **FIX**(objects): await save() in ObjectSyncEngine to prevent missing index entries. ([7cefead4](https://github.com/locorda/sync-engine/commit/7cefead4ebe6541a5c976c083710b445bcec4879))
 - **DOCS**: reposition packages as BYOB offline-first sync. ([9a03fd0a](https://github.com/locorda/sync-engine/commit/9a03fd0a170ace56bc9a372aae2effea1949aa19))

#### `locorda_init_generator` - `v0.5.2`

 - **FIX**(dependencies): update analyzer version constraint to support Flutter range. ([7c9668a4](https://github.com/locorda/sync-engine/commit/7c9668a41512056097e540f9c31440b696596061))
 - **DOCS**: reposition packages as BYOB offline-first sync. ([9a03fd0a](https://github.com/locorda/sync-engine/commit/9a03fd0a170ace56bc9a372aae2effea1949aa19))

#### `locorda_dev` - `v0.5.2`

 - **FIX**(dependencies): update analyzer version constraint to support Dart SDK range. ([f738f93b](https://github.com/locorda/sync-engine/commit/f738f93b94560dd96b94d86238ae2603f0437a41))
 - **DOCS**: reposition packages as BYOB offline-first sync. ([9a03fd0a](https://github.com/locorda/sync-engine/commit/9a03fd0a170ace56bc9a372aae2effea1949aa19))

#### `locorda_dir` - `v0.5.2`

 - **FIX**(dependencies): adjust file_picker version constraint to allow specific range. ([fdeab3e1](https://github.com/locorda/sync-engine/commit/fdeab3e1d426198d1ef15b942d98ecb567ad8b2f))
 - **FIX**(dependencies): update dependencies. ([f4f32697](https://github.com/locorda/sync-engine/commit/f4f32697722ac968bd554e833baffd9d37aa75c9))
 - **DOCS**(dir_main_integration_io): format directory path examples for clarity. ([64cf99eb](https://github.com/locorda/sync-engine/commit/64cf99eba1d8d6650a64f0d7418bbb224f765b2d))
 - **DOCS**: reposition packages as BYOB offline-first sync. ([9a03fd0a](https://github.com/locorda/sync-engine/commit/9a03fd0a170ace56bc9a372aae2effea1949aa19))

#### `locorda_drift` - `v0.5.2`

 - **DOCS**: reposition packages as BYOB offline-first sync. ([9a03fd0a](https://github.com/locorda/sync-engine/commit/9a03fd0a170ace56bc9a372aae2effea1949aa19))

#### `locorda_flutter_core` - `v0.5.2`

 - **DOCS**: reposition packages as BYOB offline-first sync. ([9a03fd0a](https://github.com/locorda/sync-engine/commit/9a03fd0a170ace56bc9a372aae2effea1949aa19))

#### `locorda_flutter` - `v0.5.2`

 - **DOCS**: reposition packages as BYOB offline-first sync. ([9a03fd0a](https://github.com/locorda/sync-engine/commit/9a03fd0a170ace56bc9a372aae2effea1949aa19))

#### `locorda_gdrive` - `v0.5.2`

 - **REFACTOR**(gdrive): introduce GDriveFolderStrategy interface. ([6e57be4c](https://github.com/locorda/sync-engine/commit/6e57be4c85c4eb68f2ef268b779082d0178d2617))
 - **FIX**(sync): recover missing gdrive folder and surface upload failures. ([6bffaded](https://github.com/locorda/sync-engine/commit/6bffadedf127092a3b7bdfbdb6540f950c07e123))
 - **FIX**(gdrive): append file extension to remote paths and disable mirror for SingleFile. ([e21d85f8](https://github.com/locorda/sync-engine/commit/e21d85f874226fb9299b325891a13564f3cc3c18))
 - **DOCS**(locorda_gdrive): add example, strict analysis, fix type annotations. ([b1e18e90](https://github.com/locorda/sync-engine/commit/b1e18e90d86b0ec670299545e6d8afb1c707d66e))
 - **DOCS**: reposition packages as BYOB offline-first sync. ([9a03fd0a](https://github.com/locorda/sync-engine/commit/9a03fd0a170ace56bc9a372aae2effea1949aa19))

#### `locorda_mapping_bootstrap_generator` - `v0.5.2`

 - **DOCS**: reposition packages as BYOB offline-first sync. ([9a03fd0a](https://github.com/locorda/sync-engine/commit/9a03fd0a170ace56bc9a372aae2effea1949aa19))

#### `locorda_solid_auth` - `v0.5.2`

 - **FIX**(auth): do not await genDpopToken - it is a synchronous operation. ([f60ea06c](https://github.com/locorda/sync-engine/commit/f60ea06ceb642b596539266095295524824c3a5e))

#### `locorda_solid_auth_worker` - `v0.5.2`

 - **DOCS**: reposition packages as BYOB offline-first sync. ([9a03fd0a](https://github.com/locorda/sync-engine/commit/9a03fd0a170ace56bc9a372aae2effea1949aa19))

#### `locorda_solid_core` - `v0.5.2`

 - **DOCS**: reposition packages as BYOB offline-first sync. ([9a03fd0a](https://github.com/locorda/sync-engine/commit/9a03fd0a170ace56bc9a372aae2effea1949aa19))

#### `locorda_solid` - `v0.5.2`

 - **DOCS**: reposition packages as BYOB offline-first sync. ([9a03fd0a](https://github.com/locorda/sync-engine/commit/9a03fd0a170ace56bc9a372aae2effea1949aa19))

#### `locorda_ui` - `v0.5.2`

 - **DOCS**: reposition packages as BYOB offline-first sync. ([9a03fd0a](https://github.com/locorda/sync-engine/commit/9a03fd0a170ace56bc9a372aae2effea1949aa19))

#### `locorda_worker` - `v0.5.2`

 - **DOCS**: reposition packages as BYOB offline-first sync. ([9a03fd0a](https://github.com/locorda/sync-engine/commit/9a03fd0a170ace56bc9a372aae2effea1949aa19))

#### `locorda` - `v0.5.2`

 - **REFACTOR**(core): moved note_index_entry_regression_test to personal_notes_app to fix broken dev dependency. ([de742814](https://github.com/locorda/sync-engine/commit/de742814149857edd9db62d579d70a922600d153))
 - **FEAT**: update GDrive integration to use visible folder mode for easier file inspection. ([1e809e5d](https://github.com/locorda/sync-engine/commit/1e809e5d0befa641310d2dcbd403c918b7a1719c))
 - **DOCS**(locorda): add example/README.md for pub.dev example tab recognition. ([f628d407](https://github.com/locorda/sync-engine/commit/f628d407eb96f3187849921ff3d310ec9042aa04))
 - **DOCS**: reposition packages as BYOB offline-first sync. ([9a03fd0a](https://github.com/locorda/sync-engine/commit/9a03fd0a170ace56bc9a372aae2effea1949aa19))


## 2026-04-22

### Changes

---

Packages with breaking changes:

 - There are no breaking changes in this release.

Packages with other changes:

 - [`locorda_core` - `v0.5.1`](#locorda_core---v051)
 - [`locorda_annotations` - `v0.5.1`](#locorda_annotations---v051)
 - [`locorda_builder` - `v0.5.1`](#locorda_builder---v051)
 - [`locorda_objects` - `v0.5.1`](#locorda_objects---v051)
 - [`locorda_init_generator` - `v0.5.1`](#locorda_init_generator---v051)
 - [`locorda_dev` - `v0.5.1`](#locorda_dev---v051)
 - [`locorda_dir` - `v0.5.1`](#locorda_dir---v051)
 - [`locorda_drift` - `v0.5.1`](#locorda_drift---v051)
 - [`locorda_flutter_core` - `v0.5.1`](#locorda_flutter_core---v051)
 - [`locorda_flutter` - `v0.5.1`](#locorda_flutter---v051)
 - [`locorda_gdrive` - `v0.5.1`](#locorda_gdrive---v051)
 - [`locorda_mapping_bootstrap_generator` - `v0.5.1`](#locorda_mapping_bootstrap_generator---v051)
 - [`locorda_solid_auth` - `v0.5.1`](#locorda_solid_auth---v051)
 - [`locorda_solid_auth_worker` - `v0.5.1`](#locorda_solid_auth_worker---v051)
 - [`locorda_solid_core` - `v0.5.1`](#locorda_solid_core---v051)
 - [`locorda_solid` - `v0.5.1`](#locorda_solid---v051)
 - [`locorda_ui` - `v0.5.1`](#locorda_ui---v051)
 - [`locorda_worker` - `v0.5.1`](#locorda_worker---v051)
 - [`locorda` - `v0.5.1`](#locorda---v051)

---

#### `locorda_core` - `v0.5.1`

 - **FIX**(core): translate preloadedResourceDocIris IRIs in PipelineIriTranslatingRemoteSyncStorage. ([8ca4520b](https://github.com/locorda/sync-engine/commit/8ca4520b666c6001c04af7e0b0d58fd4c3a5d88b))

#### `locorda_annotations` - `v0.5.1`

#### `locorda_builder` - `v0.5.1`

#### `locorda_objects` - `v0.5.1`

#### `locorda_init_generator` - `v0.5.1`

 - **FIX**: do not use field that was deprecated in analyzer 10 and removed in analyzer 12. ([fab5758e](https://github.com/locorda/sync-engine/commit/fab5758ec2b1115b8b2875ed4aa0055e59667ba7))

#### `locorda_dev` - `v0.5.1`

#### `locorda_dir` - `v0.5.1`

#### `locorda_drift` - `v0.5.1`

#### `locorda_flutter_core` - `v0.5.1`

#### `locorda_flutter` - `v0.5.1`

#### `locorda_gdrive` - `v0.5.1`

#### `locorda_mapping_bootstrap_generator` - `v0.5.1`

#### `locorda_solid_auth` - `v0.5.1`

#### `locorda_solid_auth_worker` - `v0.5.1`

#### `locorda_solid_core` - `v0.5.1`

#### `locorda_solid` - `v0.5.1`

#### `locorda_ui` - `v0.5.1`

#### `locorda_worker` - `v0.5.1`

#### `locorda` - `v0.5.1`


## 0.5.0

Initial public release of the Locorda monorepo. All packages debut at version 0.5.0.

### locorda

Top-level facade package re-exporting the most commonly used types from the sub-packages: `Locorda`, `ObjectSyncEngine`, `LocordaConfig`, `ResourceConfig`, storage layouts (`FilePerResource`, `ShardDataset`, `SingleFile`), UI widgets (`MultiBackendStatusWidget`, `SyncRefreshIndicator`), Drift storage handlers, worker entry points, and all CRDT annotations (`@RootResource`, `@CrdtLwwRegister`, `@CrdtImmutable`, `@CrdtOrSet`). Includes the Personal Notes App and a minimal task-sync example application.

### locorda_core

Platform-agnostic CRDT synchronisation engine. Provides `SyncEngine` / `StandardSyncEngine`, a two-pass fetch-and-merge / upload pipeline with typed events, three storage layout strategies (`FilePerResource`, `ShardDataset`, `SingleFile`), `SyncManager` for scheduling, `Storage` interface with `InMemoryStorage`, `Backend` / `PipelineBackend` pluggable remote storage, Hybrid Logical Clock (HLC) based CRDT merge (LWW-Register, OR-Set, FWW-Register, Immutable), `HydrationBatch`, `SyncEngineConfig`, `IriTranslator`, and index types `FullIndexData` / `GroupIndexData` with `RootResourceFetchPolicy`.

### locorda_annotations

Annotation library for CRDT merge strategies: `@RootResource`, `@CrdtLwwRegister`, `@CrdtFwwRegister`, `@CrdtOrSet`, `@CrdtImmutable`. Integrates with `rdf_mapper_annotations` for combined RDF mapping and CRDT code generation.

### locorda_objects

Type-safe façade over `SyncEngine`: `ObjectSyncEngine`, `LocordaConfig` / `ResourceConfig`, `hydrateWithCallbacks<T>()`, `save<T>()`, `deleteDocument<T>()`, and `GroupIndexSyncFailedException`.

### locorda_flutter

Flutter-specific top-level facade: `Locorda.create()` spawns the worker thread/isolate, wires backend handlers, exposes `syncManager` and `uiAdapterRegistry`. Re-exports index configuration types.

### locorda_flutter_core

`RemoteIntegration` interface (combined `RemoteMainHandler` + `RemoteUiAdapter`) and `LocordaGraph` — the unit of data transfer between main thread and worker.

### locorda_worker

Platform-agnostic worker infrastructure (Dart Isolates / Web Workers): `workerMain()`, `WorkerParams`, `ProxySyncEngine`, `SyncManager` proxy, `WorkerChannel` plugin system, `StorageMainHandler` / `StorageWorkerHandler`, and worker manifest auto-discovery.

### locorda_builder

Build-runner builders: `WorkerGeneratorBuilder` (auto-generates `worker_generated.g.dart`), `WebWorkerBuilder` (compiles worker Dart to JavaScript). Zero build config required for standard setups.

### locorda_dev

Unified dev-dependency that activates all Locorda build-time tooling: web worker compilation, mapping bootstrap generation, init generator, and RDF mapper generator.

### locorda_init_generator

Code generation: `InitLocordaBuilder` (generates `init_locorda.g.dart`), `ConfigBuilder` (generates `locorda_config.g.dart`), `CrdtMappingBuilder` (generates CRDT mapping Turtle documents).

### locorda_mapping_bootstrap_generator

`MappingBootstrapBuilder`: discovers CRDT mapping Turtle documents across dependencies and embeds them as `const List<String> bootstrapMappings` for offline-first merge contract loading.

### locorda_drift

Drift (SQLite) `Storage` implementation: `DriftStorage`, `DriftMainHandler`, `DriftWorkerHandler`, `LocordaDriftNativeOptions` / `LocordaDriftWebOptions`. Supports all Flutter platforms. Includes worker manifest for auto-discovery.

### locorda_dir

Local directory backend: `DirMainIntegration`, `DirWorkerHandler`, `DirLoginScreen`. ETag-based change detection, resource-type folder organisation, platform-aware default paths. Supports macOS, Linux, Windows, iOS/Android (sandbox); Web not supported.

### locorda_gdrive

Google Drive backend: `GDriveMainIntegration`, `GDriveWorkerHandler`, OAuth2 via `google_sign_in`, App Data Folder mode and Visible Folder mode, `GDriveLoginScreen` / `GDriveStatusWidget`. Supports iOS, Android, Web, Desktop.

### locorda_solid

Solid Pod backend: `SolidBackend` (`PipelineBackend`), `SolidAuthProvider`, `SolidConfig`. HTTP reads/writes against LDP resources with DPoP-authenticated requests.

### locorda_solid_core

Solid Pod pipeline backend: `SolidBackend`, `SolidAuthProvider` (worker-side), `SolidConfig`.

### locorda_solid_auth

Flutter UI and auth bridge for Solid OIDC: `SolidAuthBridge`, `SolidLoginPage`, `SolidStatusWidget`, `SolidStatusDefaults`, `SolidProviderService` / `DefaultSolidProviderService`, `SolidAuthLocalizations` (English, German).

### locorda_solid_auth_worker

Worker-side Solid authentication plumbing: `SolidAuthBridge`, `WorkerSolidAuthProvider`, `UpdateAuthMessage`. Enables DPoP token signing inside the worker without main-thread round-trips.

### locorda_ui

Flutter UI components shared across backends: `MultiBackendStatusWidget`, `SyncRefreshIndicator`, `RemoteUiAdapter`, `UiAdapterRegistry`, `LocordaStatusWidget` / `LocordaStatusDefaults`. Localisation: English and German.
