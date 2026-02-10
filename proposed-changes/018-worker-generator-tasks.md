# 018 Worker Generator — Implementation Tasks

Parent document: [018-worker-generator.md](018-worker-generator.md)

## Context

Currently, users must manually write both `worker.dart` and the main-side `initLocorda()` call,
carefully keeping handler registrations in sync. This proposal introduces a **manifest-based
worker generator** that auto-generates a complete `worker.g.dart` with the `main()` entry point.

Key insights:
- `BuildStep.findAssets` only searches the current package, so discovery of manifests across
  transitive dependencies must use `buildStep.packageConfig` + `buildStep.canRead(AssetId(...))`
- Manifests contain lightweight handler instances (heavy initialization deferred until
  `toEngineParams()` selects active handlers)
- Generated `worker.g.dart` replaces manual `worker.dart` entirely
- Optional `onWorkerSpawn` callback support via build.yaml configuration

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

### Task 2.1: Define the manifest Dart format

Each adapter package provides a public manifest file with concrete handler
instances. The handlers remain lightweight until `toEngineParams()` selects
the active IDs.

**New file**: `lib/locorda_worker.manifest.dart`

```dart
import 'package:locorda_worker/worker.dart';

final storages = <StorageWorkerHandler>[
  // DriftWorkerHandler(id: driftStorageHandlerId),
];

final remotes = <RemoteWorkerHandler>[
  // SolidWorkerHandler(id: solidRemoteHandlerId),
];
```

### Task 2.2: Create manifest files in existing adapter packages

Each adapter package provides a hand-written manifest at:
`lib/locorda_worker.manifest.dart`

**locorda_drift** — `packages/locorda_drift/lib/locorda_worker.manifest.dart`:
```dart
import 'package:locorda_drift/src/shared/consts.dart';
import 'package:locorda_drift/worker.dart';
import 'package:locorda_worker/worker.dart';

final storages = <StorageWorkerHandler>[
  DriftWorkerHandler(id: driftStorageHandlerId),
];

final remotes = <RemoteWorkerHandler>[];
```

**locorda_solid** — `packages/locorda_solid/lib/locorda_worker.manifest.dart`:
```dart
import 'package:locorda_solid/src/solid/shared/consts.dart';
import 'package:locorda_solid/worker.dart';
import 'package:locorda_worker/worker.dart';

final storages = <StorageWorkerHandler>[];

final remotes = <RemoteWorkerHandler>[
  SolidWorkerHandler(id: solidRemoteHandlerId),
];
```

**locorda_gdrive** — `packages/locorda_gdrive/lib/locorda_worker.manifest.dart`:
```dart
import 'package:locorda_gdrive/src/shared/consts.dart';
import 'package:locorda_gdrive/worker.dart';
import 'package:locorda_worker/worker.dart';

final storages = <StorageWorkerHandler>[];

final remotes = <RemoteWorkerHandler>[
  GDriveWorkerHandler(id: gDriveRemoteHandlerId),
];
```

**locorda_dir** — `packages/locorda_dir/lib/locorda_worker.manifest.dart`:
```dart
import 'package:locorda_dir/src/shared/consts.dart';
import 'package:locorda_dir/worker.dart';
import 'package:locorda_worker/worker.dart';

final storages = <StorageWorkerHandler>[];

final remotes = <RemoteWorkerHandler>[
  DirWorkerHandler(id: directoryRemoteHandlerId),
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

## Phase 3: Worker Generator

### Task 3.1: Create the worker generator builder

**New builder in `locorda_builder`**: Add a builder that:

1. Triggers on `pubspec.yaml` (like mapping_bootstrap).
2. Reads `buildStep.packageConfig` to list all packages.
3. For each package, probes for manifest files (default: `lib/locorda_worker.manifest.dart`).
4. Applies `exclude_packages` filter from builder options.
5. Generates complete executable worker with `main()` entry point.

**Output**: `lib/worker.g.dart` (build_to: source).

**build.yaml** config:
```yaml
builders:
  worker_generator:
    import: "package:locorda_builder/builder.dart"
    builder_factories: ["workerGeneratorBuilder"]
    build_extensions:
      pubspec.yaml:
        - lib/worker.g.dart
    auto_apply: dependents
    build_to: source
    required_inputs:
      - .dart  # For manifest discovery
      - lib/src/generated/mapping_bootstrap.g.dart  # Optional dependency
    defaults:
      generate_for:
        - pubspec.yaml
      options:
        # Packages to exclude from manifest discovery
        exclude_packages: []
        # Custom manifest file paths (for non-standard locations)
        manifest_files: ['lib/locorda_worker.manifest.dart']
        # Optional: Import path for onWorkerSpawn callback
        on_worker_spawn_import: null
        # Optional: Function name for onWorkerSpawn callback
        on_worker_spawn_function: null
```

**Dependency**: This builder runs after `mapping_bootstrap` generator (if present) because
it conditionally imports `mapping_bootstrap.g.dart`.

**App-level configuration example** (`build.yaml` in personal_notes_app):
```yaml
targets:
  $default:
    builders:
      locorda_builder|worker_generator:
        options:
          on_worker_spawn_import: 'package:personal_notes_app/utils/logging_setup.dart'
          on_worker_spawn_function: 'setupWorkerLogging'
```

### Task 3.2: Define the generated output format

The generated `lib/worker.g.dart` is a complete, executable worker entry point:

**Without onWorkerSpawn or mapping_bootstrap** (minimal example):
```dart
// GENERATED CODE - DO NOT MODIFY BY HAND

import 'package:locorda_drift/locorda_worker.manifest.dart' as locorda_drift;
import 'package:locorda_worker/worker.dart';

void main() {
  workerMain(generatedWorkerSetup);
}

Future<WorkerParams> generatedWorkerSetup() async => WorkerParams(
  storages: [...locorda_drift.storages],
  remotes: [],
  mappingBootstrapSources: [],
);
```

**With mapping_bootstrap** (when RDF mapper generator is used):
```dart
// GENERATED CODE - DO NOT MODIFY BY HAND

import 'package:locorda_drift/locorda_worker.manifest.dart' as locorda_drift;
import 'package:locorda_worker/worker.dart';
import 'src/generated/mapping_bootstrap.g.dart';

void main() {
  workerMain(generatedWorkerSetup);
}

Future<WorkerParams> generatedWorkerSetup() async => WorkerParams(
  storages: [...locorda_drift.storages],
  remotes: [],
  mappingBootstrapSources: bootstrapMappings,
);
```

**With onWorkerSpawn** (personal_notes_app):
```dart
// GENERATED CODE - DO NOT MODIFY BY HAND

import 'package:locorda_drift/locorda_worker.manifest.dart' as locorda_drift;
import 'package:locorda_solid/locorda_worker.manifest.dart' as locorda_solid;
import 'package:locorda_gdrive/locorda_worker.manifest.dart' as locorda_gdrive;
import 'package:locorda_dir/locorda_worker.manifest.dart' as locorda_dir;
import 'package:personal_notes_app/locorda_worker.manifest.dart'
    as personal_notes_app;
import 'package:locorda_worker/worker.dart';
import 'src/generated/mapping_bootstrap.g.dart';
import 'package:personal_notes_app/utils/logging_setup.dart'
    show setupWorkerLogging;

/// Worker entry point for web workers.
///
/// On web, the compiled JS is loaded and main() is called automatically.
void main() {
  workerMain(generatedWorkerSetup, onWorkerSpawn: setupWorkerLogging);
}

/// Generated worker setup that registers all discovered adapters.
///
/// Active handlers are selected at runtime based on IDs received from main.
/// 
/// This function is public so main-side code can import and pass it to
/// Locorda.create(workerSetup: generatedWorkerSetup) for isolate spawning.
Future<WorkerParams> generatedWorkerSetup() async => WorkerParams(
  storages: [
    ...locorda_drift.storages,
    ...locorda_solid.storages,
    ...locorda_gdrive.storages,
    ...locorda_dir.storages,
    ...personal_notes_app.storages,
  ],
  remotes: [
    ...locorda_drift.remotes,
    ...locorda_solid.remotes,
    ...locorda_gdrive.remotes,
    ...locorda_dir.remotes,
    ...personal_notes_app.remotes,
  ],
  mappingBootstrapSources: bootstrapMappings,
);
```

### Task 3.3: Implement manifest discovery and code generation

The builder needs to:
1. Read `manifest_files` option (default: `['lib/locorda_worker.manifest.dart']`).
2. For each package in `buildStep.packageConfig`, check if any manifest file exists.
3. Skip packages in `exclude_packages` list.
4. Generate imports with sanitized aliases (replace `-` with `_` in package names).
5. **Check if mapping_bootstrap.g.dart exists**:
   - Use `buildStep.canRead(AssetId(inputId.package, 'lib/src/generated/mapping_bootstrap.g.dart'))`
   - Only import and reference `bootstrapMappings` if file exists
   - Otherwise use empty list `[]` for `mappingBootstrapSources`
6. Generate `main()` function:
   - Call `workerMain(generatedWorkerSetup)`
   - Optionally add `onWorkerSpawn` parameter if configured
7. Generate `generatedWorkerSetup()` function (public, for isolate import):
   - Spread all `...packageAlias.storages`
   - Spread all `...packageAlias.remotes`
   - Include `bootstrapMappings` (if found) or `[]` (if not)
8. If `on_worker_spawn_import` and `on_worker_spawn_function` are configured:
   - Add import statement
   - Pass function to `workerMain()`

### Task 3.4: Add to locorda_dev applies_builders

**File**: `packages/locorda_dev/build.yaml`

Add the worker generator to the meta-builder's `applies_builders` list:
```yaml
applies_builders:
  - locorda_mapping_bootstrap_generator:mapping_bootstrap
  - locorda_rdf_mapper_generator:cache_builder
  - locorda_rdf_mapper_generator:source_builder
  - locorda_rdf_mapper_generator:init_file_builder
  - locorda_builder:worker_generator  # <-- Add this
  - locorda_builder:web_worker
```

**Note**: `worker_generator` must run before `web_worker` because the web worker
builder compiles `lib/worker.dart` → `web/worker.dart.js`. With generation,
it will compile `lib/worker.g.dart` instead (requires updating web_worker builder
to look for `worker.g.dart`).

---

## Phase 4: Update Web Worker Builder

### Task 4.1: Support both manual and generated worker files

**File**: `packages/locorda_builder/lib/src/web_worker_builder.dart`

**Goal**: Support gradual migration and provide escape hatch for advanced use cases.

Update `buildExtensions` and `build()` method to check for both files:
```dart
@override
Map<String, List<String>> get buildExtensions => {
  'lib/worker.dart': [  // Manual worker (priority)
    'web/worker.dart.js',
    'web/worker.dart.js.map'
  ],
  'lib/worker.g.dart': [  // Generated worker (fallback)
    'web/worker.dart.js',
    'web/worker.dart.js.map'
  ],
};

@override
Future<void> build(BuildStep buildStep) async {
  final inputId = buildStep.inputId;
  
  // Priority: manual worker.dart over generated worker.g.dart
  AssetId? workerFile;
  
  if (inputId.path == 'lib/worker.dart') {
    workerFile = inputId;
  } else if (inputId.path == 'lib/worker.g.dart') {
    // Only use worker.g.dart if worker.dart doesn't exist
    final manualWorker = AssetId(inputId.package, 'lib/worker.dart');
    if (await buildStep.canRead(manualWorker)) {
      log.info('Skipping worker.g.dart because manual worker.dart exists');
      return;
    }
    workerFile = inputId;
  }
  
  if (workerFile == null) return;
  
  // ... existing compilation logic
}
```

**Migration path**:
1. Initially: Users have manual `worker.dart` → compiled as before
2. After adding locorda_builder builder: `worker.g.dart` is generated but ignored
3. User deletes `worker.dart` → `worker.g.dart` is now compiled
4. Escape hatch: User can always add manual `worker.dart` to override generation

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

## Phase 6: Update Examples and Documentation

### Task 6.1: Update personal_notes_app

**Configuration** — Add `build.yaml` with `onWorkerSpawn`:
```yaml
targets:
  $default:
    builders:
      locorda_builder|worker_generator:
        options:
          on_worker_spawn_import: 'package:personal_notes_app/utils/logging_setup.dart'
          on_worker_spawn_function: 'setupWorkerLogging'
```

**Custom Manifest** — Create `lib/locorda_worker.manifest.dart` for custom Dir variant:
```dart
import 'package:locorda_dir/worker.dart';
import 'package:locorda_worker/worker.dart';

const dirDatasetPerShardRemoteId = 'personal_notes_app:dir:dataset_sharded';

final storages = <StorageWorkerHandler>[];

final remotes = <RemoteWorkerHandler>[
  DirWorkerHandler(id: dirDatasetPerShardRemoteId, useShardDatasets: true),
];
```

**Migration**:
- Remove manual `lib/worker.dart` (now generated as `lib/worker.g.dart`)
- Verify build: `dart run build_runner clean && dart run build_runner build -d`
- Verify `web/worker.dart.js` is generated correctly

### Task 6.2: Update minimal example

**No configuration needed** (uses defaults):
- No `build.yaml` required
- No custom manifest needed
- Remove manual `lib/worker.dart` (now generated)
- Verify build succeeds

### Task 6.3: Document configuration options

Create usage guide covering:

**Basic usage** (no config):
- Builder automatically generates `worker.g.dart`
- Includes all adapter manifests from dependencies
- Empty `mappingBootstrapSources` if no RDF mapper

**Custom manifest** for app-specific handlers:
```dart
// lib/locorda_worker.manifest.dart
final storages = <StorageWorkerHandler>[];
final remotes = <RemoteWorkerHandler>[
  // Custom handler configurations
];
```

**Advanced configuration** (`build.yaml`):
```yaml
locorda_builder|worker_generator:
  options:
    # Exclude packages from manifest discovery
    exclude_packages: ['test_fixtures']
    # Custom manifest paths
    manifest_files: ['lib/custom_worker.manifest.dart']
    # Worker spawn callback
    on_worker_spawn_import: 'package:my_app/setup.dart'
    on_worker_spawn_function: 'setupWorker'
```

**Escape hatch** — Manual worker.dart:
- Create `lib/worker.dart` to override generation
- Useful for debugging or complex custom setups

---

## Phase 7: Tests

### Task 7.1: Unit test manifest discovery and aggregation

- Test that the aggregator correctly discovers manifests across packages.
- Test `exclude_packages` filtering.
- Test that the app's own manifest is included alongside dependency manifests.

### Task 7.2: Unit test runtime selection in toEngineParams

- Test that only active IDs are instantiated.
- Test "exactly one storage" validation.
- Test remote mismatch detection with helpful error messages.
- Test that inactive handlers are not created (no side effects).

### Task 7.3: Unit test onWorkerSpawn configuration

- Test that generated code includes onWorkerSpawn when configured.
- Test that generated code omits onWorkerSpawn when not configured.
- Test that import path is correctly generated.

### Task 7.4: Unit test conditional mapping_bootstrap import

- Test that generated code includes import when `mapping_bootstrap.g.dart` exists.
- Test that generated code uses empty list when file doesn't exist.
- Test that builder uses `canRead()` to detect file presence.

### Task 7.5: Unit test web worker builder file priority

- Test that manual `worker.dart` takes priority over `worker.g.dart`.
- Test that `worker.g.dart` is compiled when `worker.dart` doesn't exist.
- Test that `worker.g.dart` is skipped when both files exist.

### Task 7.6: Integration test with example apps

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
Phase 3 (Tasks 3.1–3.4)   Worker generator (generates worker.g.dart, conditional bootstrapMappings)
    ↓
Phase 4 (Task 4.1)        Update web worker builder (support both worker.dart and worker.g.dart)
    ↓
Phase 5 (Task 5.1)        initLocorda generator (stretch goal)
    ↓
Phase 6 (Tasks 6.1–6.3)   Update examples and documentation
    ↓
Phase 7 (Tasks 7.1–7.6)   Tests
```

Phases 1 and 2 can be partially parallelized (Task 2.1 depends on nothing,
Task 2.2 depends on 1.1/1.2, Task 2.3 is independent).

---

## Risk Assessment

| Risk | Mitigation |
|------|-----------|
| `buildStep.canRead` may not see all transitive deps | Verified: `packageConfig` lists all packages; `canRead` works cross-package |
| Manifest file name collisions in packages | Use distinctive name `locorda_worker.manifest.dart`; allow custom paths via `manifest_files` option |
| DriftWorkerHandler config migration (Task 2.3) is complex | Already completed in Phase 2 using DriftConfigConnector |
| Generated worker.js bundle includes unused handlers | Runtime selection via `toEngineParams` filters by active IDs; `exclude_packages` option for build-time exclusion |
| onWorkerSpawn configuration discoverability | Document in builder options; provide clear examples in Phase 6 |
| Breaking change for existing projects | Gradual migration: web_worker builder supports both files; manual `worker.dart` takes priority |
| mapping_bootstrap.g.dart not always present | Builder conditionally imports using `canRead()`; uses empty list if not found |
