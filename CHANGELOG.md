
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
