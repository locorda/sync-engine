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
5. Checks if manual `lib/worker.dart` exists - skips generation if found.
6. Generates complete executable worker with `main()` entry point.

**Output**: `lib/worker_generated.g.dart` (build_to: source).

**Note**: Output renamed to avoid collision with `source_gen:combining_builder` which also generates `.g.dart` files.

**build.yaml** config:
```yaml
builders:
  worker_generator:
    import: "package:locorda_builder/builder.dart"
    builder_factories: ["workerGeneratorBuilder"]
    build_extensions:
      pubspec.yaml:
        - lib/worker_generated.g.dart
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

**Note**: Output is `worker_generated.g.dart` to avoid collision with `source_gen:combining_builder`. The web_worker builder compiles this to `web/worker_generated.dart.js` for distinct outputs.

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

The generated `lib/worker_generated.g.dart` is a complete, executable worker entry point:

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
4. **Check if manual `lib/worker.dart` exists**:
   - Use `buildStep.canRead(AssetId(inputId.package, 'lib/worker.dart'))`
   - Skip generation entirely if manual worker exists (logs info message)
   - This allows users to override generation for advanced use cases
5. Generate imports with sanitized aliases (replace `-` with `_` in package names).
6. **Check if mapping_bootstrap.g.dart exists**:
   - Use `buildStep.canRead(AssetId(inputId.package, 'lib/src/generated/mapping_bootstrap.g.dart'))`
   - Only import and reference `bootstrapMappings` if file exists
   - Otherwise use empty list `[]` for `mappingBootstrapSources`
7. Generate `main()` function:
   - Call `workerMain(generatedWorkerSetup)`
   - Optionally add `onWorkerSpawn` parameter if configured
8. Generate `generatedWorkerSetup()` function (public, for isolate import):
   - Spread all `...packageAlias.storages`
   - Spread all `...packageAlias.remotes`
   - Include `bootstrapMappings` (if found) or `[]` (if not)
9. Add `// ignore_for_file: depend_on_referenced_packages` comment at top of generated file
10. If `on_worker_spawn_import` and `on_worker_spawn_function` are configured:
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
builder compiles worker files to JavaScript. With generation, it compiles both:
- Manual `lib/worker.dart` → `web/worker.dart.js`
- Generated `lib/worker_generated.g.dart` → `web/worker_generated.dart.js`

Distinct output names prevent collisions when both files exist.

---

## Phase 4: Update Web Worker Builder

### Task 4.1: Support both manual and generated worker files with distinct outputs

**File**: `packages/locorda_builder/lib/src/web_worker_builder.dart`

**Goal**: Support coexistence of manual and generated workers with distinct JavaScript outputs.

Update `buildExtensions` to handle both files with distinct output names:
```dart
@override
Map<String, List<String>> get buildExtensions => {
  'lib/worker.dart': [  // Manual worker
    'web/worker.dart.js',
    'web/worker.dart.js.map'
  ],
  'lib/worker_generated.g.dart': [  // Generated worker (distinct output)
    'web/worker_generated.dart.js',
    'web/worker_generated.dart.js.map'
  ],
};
```

Update `build()` method to use dynamic output names:
```dart
@override
Future<void> build(BuildStep buildStep) async {
  final inputId = buildStep.inputId;
  
  // Determine output basename based on input file
  final String outputBasename;
  if (inputId.path == 'lib/worker.dart') {
    outputBasename = 'worker.dart';  // → worker.dart.js
  } else if (inputId.path == 'lib/worker_generated.g.dart') {
    outputBasename = 'worker_generated.dart';  // → worker_generated.dart.js
  } else {
    return;  // Unknown input, skip
  }
  
  // Create output assets using dynamic basename
  final jsOutput = AssetId(inputId.package, 'web/$outputBasename.js');
  final mapOutput = AssetId(inputId.package, 'web/$outputBasename.js.map');
  
  // ... rest of compilation logic using jsOutput and mapOutput
}
```

**Key difference from original plan**: 
- No priority/fallback logic - both files can coexist
- Distinct outputs prevent collisions: `worker.dart.js` vs `worker_generated.dart.js`
- User must specify correct `jsScript` parameter in `Locorda.create()`

**Migration path**:
1. Initially: Users have manual `worker.dart` → compiled to `worker.dart.js` as before
2. After adding locorda_dev: 
   - If manual `worker.dart` exists: No `worker_generated.g.dart` generated (skipped)
   - If no manual worker: `worker_generated.g.dart` generated → compiled to `worker_generated.dart.js`
3. User must update `Locorda.create(jsScript: 'worker_generated.dart.js')` when using generated worker
4. Escape hatch: Keep manual `worker.dart` to prevent generation entirely

---

## Phase 5: initLocorda Generator (Optional / Future)

**Scope**: This is a stretch goal. It can be implemented later — manual `Locorda.create` calls
work fine with the generated worker. This phase depends on:
- RDF mapper generator (for `init_rdf_mapper.g.dart`)
- Worker generator (Phase 3, for `worker_generated.g.dart`)
- Optional: LocordaConfig generator (future work)

### Task 5.1: Create `init_locorda_generator_builder`

**New builder in `locorda_builder`**: Add a builder that generates `lib/init_locorda.g.dart`:

1. Triggers on `pubspec.yaml` (like worker_generator).
2. Detects presence of `init_rdf_mapper.g.dart` and `worker_generated.g.dart`.
3. Analyzes `initRdfMapper` signature to extract custom parameters.
4. Optionally detects `locorda_config.g.dart` for LocordaConfig.
5. Generates `initLocorda()` function that simplifies Locorda initialization.

**Output**: `lib/init_locorda.g.dart` (build_to: source).

**build.yaml** config:
```yaml
builders:
  init_locorda_generator:
    import: "package:locorda_builder/builder.dart"
    builder_factories: ["initLocordaGeneratorBuilder"]
    build_extensions:
      pubspec.yaml:
        - lib/init_locorda.g.dart
    auto_apply: dependents
    build_to: source
```

**Builder options**:
```yaml
targets:
  $default:
    builders:
      locorda_builder|init_locorda_generator:
        options:
          # Package name for imports (defaults to package name from pubspec)
          package_name: null
          # Output file name (defaults to 'lib/init_locorda.g.dart')
          output_file: null
```

### Task 5.2: Implement initRdfMapper signature analyzer

**Purpose**: Extract custom parameters from generated `initRdfMapper()` to propagate them through `initLocorda()`.

**Implementation**:
1. Use `analyzer` package to parse `init_rdf_mapper.g.dart`.
2. Find the `initRdfMapper` function declaration.
3. Extract all parameters with their types and nullability.
4. Filter out framework parameters:
   - `rdfMapper` (optional RdfMapper) → EXCLUDE (framework-managed)
   - Parameters starting with `$` → EXCLUDE (framework-injected: `$indexItemIriFactory`, `$resourceIriFactory`, `$resourceRefFactory`)
5. Return list of custom parameters to propagate.

**Data structure**:
```dart
class ParameterInfo {
  final String name;
  final String type;
  final bool isRequired;
  final bool isNamed;
}
```

**Example** (current personal_notes_app):
```dart
// Generated initRdfMapper signature:
RdfMapper initRdfMapper({
  RdfMapper? rdfMapper,                           // EXCLUDE (framework)
  required IriTermMapper<(String id,)> Function<T>(Type) $indexItemIriFactory,  // EXCLUDE ($-prefix)
  required IriTermMapper<(String id,)> Function<T>(RootIriConfig) $resourceIriFactory,  // EXCLUDE
  required IriTermMapper<String> Function<T>(Type) $resourceRefFactory,  // EXCLUDE
})

// Result: Empty list (no custom params to propagate)
List<ParameterInfo> customParams = [];
```

**Example** (hypothetical app with custom dependencies):
```dart
// Generated initRdfMapper with custom params:
RdfMapper initRdfMapper({
  RdfMapper? rdfMapper,                           // EXCLUDE
  required CategoryService categoryService,       // INCLUDE (custom dependency)
  String? defaultLocale,                          // INCLUDE (custom config)
  required IriTermMapper<(String id,)> Function<T>(Type) $indexItemIriFactory,  // EXCLUDE
  required IriTermMapper<(String id,)> Function<T>(RootIriConfig) $resourceIriFactory,  // EXCLUDE
  required IriTermMapper<String> Function<T>(Type) $resourceRefFactory,  // EXCLUDE
})

// Result: Custom params to propagate
List<ParameterInfo> customParams = [
  ParameterInfo(name: 'categoryService', type: 'CategoryService', isRequired: true, isNamed: true),
  ParameterInfo(name: 'defaultLocale', type: 'String?', isRequired: false, isNamed: true),
];
```

### Task 5.3: Implement LocordaConfig detection

**Purpose**: Detect if `locorda_config.g.dart` exists (from future LocordaConfig generator).

**Implementation**:
1. Use `buildStep.canRead()` to check for `lib/src/generated/locorda_config.g.dart`.
2. If exists: Import and use generated config.
3. If not exists: Keep `config` as required parameter in `initLocorda()` signature.

**Generated code difference**:

**With config generator**:
```dart
import 'src/generated/locorda_config.g.dart' show generatedLocordaConfig;

Future<Locorda> initLocorda({
  required StorageMainHandler storage,
  List<RemoteIntegration> remotes = const [],
  // ... other params
}) async {
  return Locorda.create(
    config: generatedLocordaConfig,  // Auto-injected
    // ...
  );
}
```

**Without config generator**:
```dart
Future<Locorda> initLocorda({
  required LocordaConfig config,  // User must provide
  required StorageMainHandler storage,
  List<RemoteIntegration> remotes = const [],
  // ... other params
}) async {
  return Locorda.create(
    config: config,  // Pass-through
    // ...
  );
}
```

### Task 5.4: Implement mapperInitializer lambda generation

**Purpose**: Generate the `mapperInitializer` parameter for `Locorda.create()`.

**Behavior**:
1. **If `init_rdf_mapper.g.dart` exists**:
   - Import the generated `initRdfMapper` function
   - Generate lambda that calls `initRdfMapper` with framework params from context
   - Pass through any custom parameters from Task 5.2
   - Example:
     ```dart
     import 'init_rdf_mapper.g.dart' show initRdfMapper;
     
     mapperInitializer: (context) => initRdfMapper(
       rdfMapper: context.baseRdfMapper,
       $indexItemIriFactory: context.indexItemIriFactory,
       $resourceIriFactory: context.resourceIriFactory,
       $resourceRefFactory: context.resourceRefFactory,
       categoryService: categoryService,  // Propagated custom param
       defaultLocale: defaultLocale,       // Propagated custom param
     ),
     ```

2. **If `init_rdf_mapper.g.dart` does NOT exist**:
   - Keep `mapperInitializer` as required parameter in `initLocorda()` signature
   - Pass through directly to `Locorda.create()`

### Task 5.5: Generate complete `initLocorda()` function

**Purpose**: Generate the main initialization function with all pieces integrated.

**Generated function signature** (without LocordaConfig generator, with custom mapper params):
```dart
/// Initialize Locorda with generated worker and RDF mapper.
///
/// This function is generated to simplify Locorda initialization by:
/// - Automatically wiring up the generated worker setup
/// - Connecting the RDF mapper with framework-injected dependencies
/// - Propagating application-specific parameters
///
/// ## Parameters
/// - [config]: Resource configuration with types, CRDT mappings, and indices
/// - [storage]: Main thread handler for storage backend (typically Drift)
/// - [remotes]: Main thread handlers for remote backends (Solid, GDrive, etc.)
/// - [categoryService]: Custom dependency for CategoryMapper
/// - [defaultLocale]: Custom configuration for localization
/// - [iriTermFactory]: Optional custom IRI term factory
/// - [rdfCore]: Optional custom RDF core
/// - [jsScript]: Web worker JS filename (default: 'worker_generated.dart.js')
/// - [plugins]: Additional worker plugins for custom functionality
/// - [onWorkerSpawn]: Optional callback to run when worker thread spawns
/// - [debugName]: Optional name for debugging worker communication
Future<Locorda> initLocorda({
  required LocordaConfig config,
  required StorageMainHandler storage,
  List<RemoteIntegration> remotes = const [],
  required CategoryService categoryService,  // Propagated from initRdfMapper
  String? defaultLocale,                      // Propagated from initRdfMapper
  IriTermFactory? iriTermFactory,
  RdfCore? rdfCore,
  String jsScript = 'worker_generated.dart.js',
  List<MainHandlerFactory> plugins = const [],
  void Function()? onWorkerSpawn,
  String? debugName,
}) async {
  return Locorda.create(
    workerSetup: generatedWorkerSetup,
    onWorkerSpawn: onWorkerSpawn,
    config: config,
    mapperInitializer: (context) => initRdfMapper(
      rdfMapper: context.baseRdfMapper,
      $indexItemIriFactory: context.indexItemIriFactory,
      $resourceIriFactory: context.resourceIriFactory,
      $resourceRefFactory: context.resourceRefFactory,
      categoryService: categoryService,
      defaultLocale: defaultLocale,
    ),
    storage: storage,
    jsScript: jsScript,
    remotes: remotes,
    plugins: plugins,
    iriTermFactory: iriTermFactory,
    rdfCore: rdfCore,
    debugName: debugName,
  );
}
```

**Simplest case** (no custom params, no config generator):
```dart
import 'package:locorda/locorda.dart';
import 'init_rdf_mapper.g.dart' show initRdfMapper;
import 'worker_generated.g.dart' show generatedWorkerSetup;

/// Initialize Locorda with generated worker and RDF mapper.
Future<Locorda> initLocorda({
  required LocordaConfig config,
  required StorageMainHandler storage,
  List<RemoteIntegration> remotes = const [],
  IriTermFactory? iriTermFactory,
  RdfCore? rdfCore,
  String jsScript = 'worker_generated.dart.js',
  List<MainHandlerFactory> plugins = const [],
  void Function()? onWorkerSpawn,
  String? debugName,
}) async {
  return Locorda.create(
    workerSetup: generatedWorkerSetup,
    onWorkerSpawn: onWorkerSpawn,
    config: config,
    mapperInitializer: (context) => initRdfMapper(
      rdfMapper: context.baseRdfMapper,
      $indexItemIriFactory: context.indexItemIriFactory,
      $resourceIriFactory: context.resourceIriFactory,
      $resourceRefFactory: context.resourceRefFactory,
    ),
    storage: storage,
    jsScript: jsScript,
    remotes: remotes,
    plugins: plugins,
    iriTermFactory: iriTermFactory,
    rdfCore: rdfCore,
    debugName: debugName,
  );
}
```

### Task 5.6: Update analyzer dependency

**File**: `packages/locorda_builder/pubspec.yaml`

**Change**:
```yaml
dependencies:
  # OLD:
  analyzer: '>=7.4.0 <10.0.0'
  
  # NEW:
  analyzer: '>=8.1.0 <11.0.0'
```

**Rationale**: 
- Avoid outdated and deprecated dependencies
- Ensure compatibility with latest analyzer features
- Follow project guideline: "We must never use outdated and deprecated dependencies"

### Task 5.7: Add to locorda_dev applies_builders

**File**: `packages/locorda_dev/build.yaml`

Add the init_locorda generator to the meta-builder's `applies_builders` list:
```yaml
applies_builders:
  - locorda_mapping_bootstrap_generator:mapping_bootstrap
  - locorda_rdf_mapper_generator:cache_builder
  - locorda_rdf_mapper_generator:source_builder
  - locorda_rdf_mapper_generator:init_file_builder
  - locorda_builder:worker_generator
  - locorda_builder:init_locorda_generator  # <-- Add this
  - locorda_builder:web_worker
```

**Note**: `init_locorda_generator` must run after `worker_generator` and `init_file_builder` because it depends on their outputs (`worker_generated.g.dart` and `init_rdf_mapper.g.dart`).

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
- Remove manual `lib/worker.dart` to allow generation of `lib/worker_generated.g.dart`
- Update `Locorda.create(jsScript: 'worker_generated.dart.js')` in main code
- Verify build: `dart run build_runner clean && dart run build_runner build -d`
- Verify `web/worker_generated.dart.js` is generated correctly

### Task 6.2: Update minimal example

**No configuration needed** (uses defaults):
- No `build.yaml` required
- No custom manifest needed
- Remove manual `lib/worker.dart` to allow generation
- Update `Locorda.create(jsScript: 'worker_generated.dart.js')`
- Verify build succeeds

### Task 6.3: Document configuration options

Create usage guide covering:

**Basic usage** (no config):
- Builder automatically generates `worker_generated.g.dart` (if no manual `worker.dart` exists)
- Compiled to `web/worker_generated.dart.js` by web_worker builder
- Includes all adapter manifests from dependencies
- Empty `mappingBootstrapSources` if no RDF mapper
- Use `Locorda.create(jsScript: 'worker_generated.dart.js')` in main code

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
- Create `lib/worker.dart` to prevent generation of `worker_generated.g.dart`
- Worker generator skips generation when manual worker detected
- Compiled to `web/worker.dart.js` (distinct from generated output)
- Use `Locorda.create(jsScript: 'worker.dart.js')` when using manual worker
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

### Task 7.5: Unit test web worker builder distinct outputs

- Test that manual `worker.dart` compiles to `worker.dart.js`.
- Test that generated `worker_generated.g.dart` compiles to `worker_generated.dart.js`.
- Test that both can be compiled independently (distinct outputs).
- Test that worker_generator skips generation when manual `worker.dart` exists.

### Task 7.6: Integration test with example apps

- `dart run build_runner build -d` succeeds for personal_notes_app.
- `dart run build_runner build -d` succeeds for minimal example.
- Generated `worker_generated.dart.js` compiles correctly.
- Materialization still works (imports like `mapping_bootstrap.g.dart` are included in compiled output).
- Verify `jsScript` parameter is correctly set in `Locorda.create()` calls.

---

## Dependency Order

```
Phase 1 (Tasks 1.1–1.6)   Core infrastructure: id fields, list storage, selection
    ↓
Phase 2 (Tasks 2.1–2.3)   Manifest format, adapter manifests, drift config transfer
    ↓
Phase 3 (Tasks 3.1–3.4)   Worker generator (generates worker_generated.g.dart, conditional bootstrapMappings, skip if manual exists)
    ↓
Phase 4 (Task 4.1)        Update web worker builder (distinct outputs: worker.dart.js vs worker_generated.dart.js)
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
| Breaking change for existing projects | Distinct outputs prevent collisions; manual `worker.dart` prevents generation entirely |
| mapping_bootstrap.g.dart not always present | Builder conditionally imports using `canRead()`; uses empty list if not found |
| source_gen collision on worker.g.dart filename | Renamed output to `worker_generated.g.dart` to avoid collision with combining_builder |
