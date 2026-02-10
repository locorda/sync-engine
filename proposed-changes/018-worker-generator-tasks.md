# 018 Worker Generator — Implementation Tasks

Parent document: [018-worker-generator.md](018-worker-generator.md)

## Context

Currently, users must manually write both `worker.dart` and the main-side `initLocorda()` call,
carefully keeping handler registrations in sync. This proposal introduces a **manifest-based
adapter registry** that allows a builder to auto-generate the worker entry point. The key
architectural insight is that `BuildStep.findAssets` only searches the current package, so
discovery of manifests across transitive dependencies must use `buildStep.packageConfig` +
`buildStep.canRead(AssetId(...))` per package.

### Current Architecture (relevant parts)

| Concept | Main side | Worker side |
|---------|-----------|-------------|
| Storage | `StorageMainHandler` (no `id`) | `StorageWorkerHandler` (no `id`) |
| Remote | `RemoteMainHandler` (has `id`) | `RemoteWorkerHandler` (has `id`) |
| Params | `Locorda.create(storage: ..., remotes: [...])` | `WorkerParams(storage: ..., remotes: [...])` |
| Conversion | — | `toEngineParams(wp, ctx, config)` |

Key: `StorageWorkerHandler` / `StorageMainHandler` currently have **no `id` field** and assume
exactly one storage. `RemoteWorkerHandler` / `RemoteMainHandler` already have `id` fields and
support multiple instances (e.g., Dir with different IDs).

---

## Phase 1: Core Infrastructure — Add `id` to Storage Handlers

### Task 1.1: Add `id` to `StorageWorkerHandler`

**File**: `packages/locorda_worker/lib/src/worker/storage_worker_handler.dart`

- Add abstract `String get id;` to `StorageWorkerHandler` (mirrors `RemoteWorkerHandler`).
- Update `DriftWorkerHandler` in `packages/locorda_drift/lib/src/worker/drift_worker_handler.dart`
  to add `id` parameter (default `'drift'`).
- Update any other `StorageWorkerHandler` implementations (search codebase).

### Task 1.2: Add `id` to `StorageMainHandler`

**File**: `packages/locorda_worker/lib/src/main/storage_main_handler.dart`

- Add abstract `String get id;` to `StorageMainHandler`.
- Update `DriftMainHandler` in `packages/locorda_drift/lib/src/main/drift_main_handler.dart`
  to add `id` parameter (default `'drift'`).
- Update the minimal example's `InMemoryStorageMainHandler` in
  `packages/locorda/example/minimal/lib/main.dart`.
- Search for any other implementations and update them.

### Task 1.3: Change `WorkerParams.storage` from single to list

**File**: `packages/locorda_worker/lib/src/shared/worker_params.dart`

- Rename `storage` → `storages` (type: `List<StorageWorkerHandler>`).
- Update all call sites that construct `WorkerParams(storage: ...)`.
  - `packages/locorda/example/personal_notes_app/lib/worker.dart`
  - `packages/locorda/example/minimal/lib/worker.dart`
  - Any test files.

### Task 1.4: Update `toEngineParams` for ID-based selection

**File**: `packages/locorda_worker/lib/src/worker/worker_params_to_engine_params.dart`

- Accept a set of active storage IDs and active remote IDs (communicated from main).
- Filter `wp.storages` to the one matching the active storage ID.
- Filter `wp.remotes` to those matching active remote IDs.
- Validate: exactly one storage remains after filtering, throw descriptive error otherwise.
- Validate: all active remote IDs have matching worker handlers (existing `RemoteMismatchException`
  pattern).

### Task 1.5: Communicate active IDs from main to worker

**Files**:
- `packages/locorda_worker/lib/src/main/sync_engine_with_worker.dart` (or wherever `InitConfig` is sent)
- `packages/locorda_worker/lib/src/worker/worker_entry_point.dart` (where `InitConfig` is received)

- Add `activeStorageId` (String) and `activeRemoteIds` (List<String>) to the init config
  message sent from main to worker.
- Derive these from `Locorda.create` parameters:
  - `activeStorageId = storage.id`
  - `activeRemoteIds = remotes.map((r) => r.id).toList()`
- Pass them through to `toEngineParams`.

### Task 1.6: Update all existing example apps and tests

- Update `personal_notes_app/lib/worker.dart`: `storage:` → `storages: [...]`
- Update `minimal/lib/worker.dart`: same
- Run all tests, fix any breakages.

---

## Phase 2: Manifest Format

### Task 2.1: Define the manifest Dart contract

**New file**: `packages/locorda_worker/lib/src/manifest/adapter_manifest.dart` (or in `locorda_worker/worker.dart` exports)

Define types that a manifest file will use:

```dart
/// Describes a worker-side handler available from an adapter package.
///
/// Manifest files use these to declare what handlers they provide.
/// The aggregator builder collects them across all dependencies.
class AdapterManifestEntry {
  /// Unique handler key, e.g. 'drift', 'solid', 'gdrive', 'local_dir'.
  /// Corresponds to StorageWorkerHandler.id / RemoteWorkerHandler.id.
  final String key;

  /// Whether this is a storage or remote handler.
  final AdapterKind kind;

  /// Factory that creates a worker handler instance for a given id.
  /// The id parameter allows multiple instances of the same handler type.
  final WorkerHandlerFactory factory;

  const AdapterManifestEntry({
    required this.key,
    required this.kind,
    required this.factory,
  });
}

enum AdapterKind { storage, remote }

/// Factory signature: given an instance id, create the handler.
/// The id may differ from the key (e.g., key='local_dir', id='local_dir_sd').
typedef StorageWorkerHandlerFactory = StorageWorkerHandler Function(String id);
typedef RemoteWorkerHandlerFactory = RemoteWorkerHandler Function(String id);
```

**Open question**: Should the factory accept additional config (Map) or only the id?
If all config comes via main→worker connectors, only the id may suffice.
But DriftWorkerHandler currently takes `web: LocordaDriftWebOptions(...)` in its constructor —
this needs to come from main as well (see Task 2.3).

### Task 2.2: Create manifest files in existing adapter packages

Each adapter package provides a hand-written manifest at:
`lib/src/locorda_adapter_registry.manifest.dart`

**locorda_drift** — `packages/locorda_drift/lib/src/locorda_adapter_registry.manifest.dart`:
```dart
import 'package:locorda_worker/worker.dart';
import '../worker/drift_worker_handler.dart';

final locordaAdapterManifest = [
  AdapterManifestEntry(
    key: 'drift',
    kind: AdapterKind.storage,
    factory: (id) => DriftWorkerHandler(id: id),
  ),
];
```

**locorda_solid** — `packages/locorda_solid/lib/src/locorda_adapter_registry.manifest.dart`:
```dart
final locordaAdapterManifest = [
  AdapterManifestEntry(
    key: 'solid',
    kind: AdapterKind.remote,
    factory: (id) => SolidWorkerHandler(id: id),
  ),
];
```

**locorda_gdrive** — `packages/locorda_gdrive/lib/src/locorda_adapter_registry.manifest.dart`:
```dart
final locordaAdapterManifest = [
  AdapterManifestEntry(
    key: 'gdrive',
    kind: AdapterKind.remote,
    factory: (id) => GDriveWorkerHandler(id: id),
  ),
];
```

**locorda_dir** — `packages/locorda_dir/lib/src/locorda_adapter_registry.manifest.dart`:
```dart
final locordaAdapterManifest = [
  AdapterManifestEntry(
    key: 'local_dir',
    kind: AdapterKind.remote,
    factory: (id) => DirWorkerHandler(id: id),
  ),
];
```

### Task 2.3: Migrate DriftWorkerHandler config to main→worker transfer

Currently `DriftWorkerHandler` takes `web: LocordaDriftWebOptions(...)` directly in its
constructor in worker.dart. For the generated worker to work, this config must come from main.

- Add a `DriftConfigConnector` (like `SolidConfigConnector`) to transfer drift web options
  from main to worker.
- Update `DriftMainHandler` to accept and send web options.
- Update `DriftWorkerHandler.create()` to receive options from `WorkerHandlerContext`.
- This means `DriftWorkerHandler(id: id)` in the manifest can be config-free.

---

## Phase 3: Registry Aggregator Builder

### Task 3.1: Create the aggregator builder

**New package or in `locorda_builder`**: Add a builder that:

1. Triggers on `pubspec.yaml` (like mapping_bootstrap).
2. Reads `buildStep.packageConfig` to list all packages.
3. For each package, probes `buildStep.canRead(AssetId(pkg, 'lib/src/locorda_adapter_registry.manifest.dart'))`.
4. Reads all found manifests.
5. Applies `exclude_packages` filter from builder options.
6. Generates an aggregated worker setup file.

**Output**: `lib/src/generated/worker_registry.g.dart` (build_to: source).

**build.yaml** config:
```yaml
builders:
  worker_registry:
    import: "package:locorda_builder/builder.dart"
    builder_factories: ["workerRegistryBuilder"]
    build_extensions:
      pubspec.yaml:
        - lib/src/generated/worker_registry.g.dart
    auto_apply: dependents
    build_to: source
    defaults:
      generate_for:
        - pubspec.yaml
      options:
        exclude_packages: []
```

### Task 3.2: Define the generated output format

The generated `worker_registry.g.dart` should contain:

```dart
// GENERATED CODE - DO NOT MODIFY BY HAND

import 'package:locorda_drift/src/locorda_adapter_registry.manifest.dart' as drift;
import 'package:locorda_solid/src/locorda_adapter_registry.manifest.dart' as solid;
import 'package:locorda_gdrive/src/locorda_adapter_registry.manifest.dart' as gdrive;
import 'package:locorda_dir/src/locorda_adapter_registry.manifest.dart' as dir;
import 'package:locorda_worker/worker.dart';

/// Aggregated adapter manifest from all dependencies.
final List<AdapterManifestEntry> workerAdapterRegistry = [
  ...drift.locordaAdapterManifest,
  ...solid.locordaAdapterManifest,
  ...gdrive.locordaAdapterManifest,
  ...dir.locordaAdapterManifest,
];
```

### Task 3.3: Implement manifest file parsing in the builder

The builder needs to:
1. Read each manifest file as a string.
2. Extract the package name and import path.
3. No need to parse Dart AST — just generate import + spread.
4. The variable name is always `locordaAdapterManifest` (convention).

### Task 3.4: Add to locorda_dev applies_builders

**File**: `packages/locorda_dev/build.yaml`

Add the registry aggregator to the meta-builder's `applies_builders` list.

---

## Phase 4: Worker Generator

### Task 4.1: Generate `worker.dart` (or a worker setup function)

**New builder** (or extend existing web_worker builder):

Generate `lib/src/generated/worker_setup.g.dart`:

```dart
// GENERATED CODE - DO NOT MODIFY BY HAND

import 'package:locorda_worker/worker.dart';
import 'worker_registry.g.dart';
import 'mapping_bootstrap.g.dart';

/// Generated worker setup that registers all discovered adapters.
///
/// Active handlers are selected at runtime based on IDs received from main.
Future<WorkerParams> generatedWorkerSetup() async => WorkerParams(
  storages: workerAdapterRegistry
      .where((e) => e.kind == AdapterKind.storage)
      .map((e) => e.factory(e.key) as StorageWorkerHandler)
      .toList(),
  remotes: workerAdapterRegistry
      .where((e) => e.kind == AdapterKind.remote)
      .map((e) => e.factory(e.key) as RemoteWorkerHandler)
      .toList(),
  mappingBootstrapSources: bootstrapMappings,
);
```

**Alternative**: User still writes `worker.dart` by hand but imports the generated registry
and setup function. This is simpler and more flexible:

```dart
// user-written worker.dart
import 'package:locorda/worker.dart';
import 'src/generated/worker_setup.g.dart';

void main() {
  workerMain(generatedWorkerSetup);
}
```

### Task 4.2: Handle user-written manifest for custom instances

Users who need custom handler configurations (e.g., two Dir instances with different settings)
can write their own `lib/src/locorda_adapter_registry.manifest.dart` in their app package.
The aggregator picks it up alongside dependency manifests.

Example (in personal_notes_app):
```dart
import 'package:locorda_dir/worker.dart';
import 'package:locorda_worker/worker.dart';

final locordaAdapterManifest = [
  AdapterManifestEntry(
    key: 'local_dir_sd',
    kind: AdapterKind.remote,
    factory: (id) => DirWorkerHandler(id: id, useShardDatasets: true),
  ),
];
```

This adds `local_dir_sd` alongside the standard `local_dir` from `locorda_dir`'s own manifest.

---

## Phase 5: initLocorda Generator (Optional / Future)

### Task 5.1: Generate `initLocorda()` function

**Scope**: This is a stretch goal. It can be implemented later — manual `Locorda.create` calls
work fine with the generated worker.

If implemented, the builder would generate a main-side init function that:
- Accepts storage and remote integration parameters.
- Derives `activeStorageId` / `activeRemoteIds` automatically.
- References the generated worker setup.
- References the generated RDF mapper initializer.
- References the generated mapping bootstrap sources.

This task depends on the RDF mapper generator and LocordaConfig generator being available,
which are separate efforts.

---

## Phase 6: Update Examples

### Task 6.1: Update personal_notes_app

- Add manifest file for custom Dir variants.
- Update `worker.dart` to use generated worker setup (or keep manual as reference).
- Update `main.dart` to show both manual and generated paths.
- Verify build succeeds: `dart run build_runner clean && dart run build_runner build -d`.

### Task 6.2: Update minimal example

- Simplest possible setup: no custom manifest needed.
- worker.dart uses generated setup function.
- Verify build.

---

## Phase 7: Tests

### Task 7.1: Unit test registry aggregation

- Test that the aggregator correctly discovers manifests across packages.
- Test `exclude_packages` filtering.
- Test that the app's own manifest is included alongside dependency manifests.

### Task 7.2: Unit test runtime selection in toEngineParams

- Test that only active IDs are instantiated.
- Test "exactly one storage" validation.
- Test remote mismatch detection with helpful error messages.
- Test that inactive handlers are not created (no side effects).

### Task 7.3: Integration test with example apps

- `dart run build_runner build -d` succeeds for personal_notes_app.
- `dart run build_runner build -d` succeeds for minimal example.
- Generated worker.js compiles correctly (materialization still works).

---

## Dependency Order

```
Phase 1 (Tasks 1.1–1.6)   Core infrastructure: id fields, list storage, selection
    ↓
Phase 2 (Tasks 2.1–2.3)   Manifest format, adapter manifests, drift config transfer
    ↓
Phase 3 (Tasks 3.1–3.4)   Registry aggregator builder
    ↓
Phase 4 (Tasks 4.1–4.2)   Worker generator / setup function
    ↓
Phase 5 (Task 5.1)        initLocorda generator (stretch goal)
    ↓
Phase 6 (Tasks 6.1–6.2)   Update examples
    ↓
Phase 7 (Tasks 7.1–7.3)   Tests
```

Phases 1 and 2 can be partially parallelized (Task 2.1 depends on nothing,
Task 2.2 depends on 1.1/1.2, Task 2.3 is independent).

---

## Risk Assessment

| Risk | Mitigation |
|------|-----------|
| `buildStep.canRead` may not see all transitive deps | Verified: `packageConfig` lists all packages; `canRead` works cross-package |
| Manifest convention name collisions | Enforce exactly one `locordaAdapterManifest` per package via file convention |
| DriftWorkerHandler config migration (Task 2.3) is complex | Can be deferred — keep manual worker.dart as escape hatch |
| Generated worker.js bundle includes unused handlers | Document `exclude_packages` in build.yaml; tree-shaking may help too |
