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

## Phase 5: initLocorda Generator

### Overview

**Status**: Active development (not optional/stretch goal)

**Goal**: Generate a convenience wrapper `initLocorda()` that automatically configures `Locorda.create()` by:
1. Detecting and auto-setting `workerSetup` and `jsScript` when `worker_generated.g.dart` exists
2. Detecting and auto-generating `mapperInitializer` when `init_rdf_mapper.g.dart` exists
3. Propagating all other parameters from `Locorda.create` dynamically
4. Propagating custom parameters from `initRdfMapper` (excluding `rdfMapper` and `$*` params)

**Key Challenge**: This requires **full Dart code analysis** using `analyzer` package to:
- Parse `Locorda.create` factory constructor signature (which may evolve)
- Parse generated `initRdfMapper` function signature (which varies per application)
- Extract parameter names, types, defaults, required/optional status

**Architecture Decision**: Separate package `locorda_init_generator` because:
- Requires heavy `analyzer` dependency (~20MB, complex API)
- More advanced than other builders
- Should not burden apps that don't use this feature

### Task 5.1: Create locorda_init_generator package

**New package**: `packages/locorda_init_generator/`

**Structure**:
```
locorda_init_generator/
├── lib/
│   ├── builder.dart                     # Public API
│   └── src/
│       ├── init_locorda_generator.dart  # Main builder class
│       ├── locorda_analyzer.dart        # Analyzes Locorda.create signature
│       ├── mapper_analyzer.dart         # Analyzes initRdfMapper signature
│       └── code_generator.dart          # Generates initLocorda.g.dart
├── pubspec.yaml
├── build.yaml
└── README.md
```

**Package setup commands**:
```bash
# Create package structure
cd packages/
mkdir -p locorda_init_generator/{lib/src,test}
cd locorda_init_generator

# Initialize basic pubspec.yaml
cat > pubspec.yaml << 'EOF'
name: locorda_init_generator
description: Code generator for Locorda convenience wrapper (initLocorda)
version: 0.0.1
publish_to: none

environment:
  sdk: ^3.5.0

dependencies:
  # CRITICAL: Must support range from stable Flutter (8.4.x) to latest (10.x)
  # See: https://github.com/flutter/flutter/blob/stable/packages/flutter_tools/lib/src/web/compile.dart
  analyzer: '>=8.1.0 <11.0.0'

dev_dependencies:
  test: any
EOF

# Add other dependencies using pub (ensures current versions)
dart pub add build source_gen locorda_flutter
dart pub add -d build_runner

# Verify analyzer constraint is correct
grep 'analyzer:' pubspec.yaml
```

**Rationale for analyzer version constraint**:
- Flutter stable (as of Feb 2026) pins `analyzer: 8.4.x`
- Latest analyzer is at `10.x.x`
- Range `'>=8.1.0 <11.0.0'` covers both
- **Critical**: Narrow ranges break in Flutter projects

**build.yaml**:
```yaml
builders:
  init_locorda_generator:
    import: "package:locorda_init_generator/builder.dart"
    builder_factories: ["initLocordaBuilder"]
    build_extensions:
      pubspec.yaml:
        - lib/init_locorda.g.dart
    auto_apply: dependents
    build_to: source
    required_inputs:
      - .dart
      - lib/worker_generated.g.dart       # Optional: for worker detection
      - lib/init_rdf_mapper.g.dart        # Optional: for mapper detection
    defaults:
      generate_for:
        - pubspec.yaml
```

### Task 5.2: Implement Locorda.create signature analyzer

**File**: `lib/src/locorda_analyzer.dart`

**Goal**: Dynamically extract all parameters from `Locorda.create` factory constructor.

**Implementation requirements**:
1. Use `analyzer` to resolve `Locorda` class from `package:locorda_flutter/locorda_flutter.dart`
2. Find `create` factory constructor using AST traversal
3. Extract all parameters with full metadata:
   - Parameter name
   - Parameter type (as string, preserving generic types)
   - Whether required/optional/named
   - Default value (if any)
   - Documentation comment
4. Return structured `ParameterInfo` objects

**Key considerations**:
- Must handle generic types: `List<RemoteIntegration>`, `Future<Locorda>`
- Must preserve defaults: `jsScript = 'worker.dart.js'`
- Must distinguish positional vs named parameters
- Must handle imports for types (preserve full qualified names if needed)

**Output example** (for current signature):
```dart
List<ParameterInfo> parameters = [
  ParameterInfo(
    name: 'workerSetup',
    type: 'WorkerSetup',
    isRequired: true,
    isNamed: true,
    defaultValue: null,
  ),
  ParameterInfo(
    name: 'onWorkerSpawn',
    type: 'void Function()?',
    isRequired: false,
    isNamed: true,
    defaultValue: null,
  ),
  ParameterInfo(
    name: 'config',
    type: 'LocordaConfig',
    isRequired: true,
    isNamed: true,
    defaultValue: null,
  ),
  // ... all other parameters
];
```

### Task 5.3: Implement initRdfMapper signature analyzer

**File**: `lib/src/mapper_analyzer.dart`

**Goal**: Dynamically extract parameters from generated `initRdfMapper` function (if exists).

**Implementation requirements**:
1. Check if `lib/init_rdf_mapper.g.dart` exists in the current package
2. If not found: return empty parameter list (graceful degradation)
3. If found:
   - Parse the file using `analyzer`
   - Find `initRdfMapper` function declaration
   - Extract all parameters except:
     - `rdfMapper` (provided by context)
     - Parameters starting with `$` (framework-provided: `$indexItemIriFactory`, etc.)
4. Return structured `ParameterInfo` objects

**Parameter filtering rules**:
- **Exclude**: `rdfMapper` (always provided by `context.baseRdfMapper`)
- **Exclude**: Any parameter name starting with `$` (framework injections)
- **Include**: All other parameters (required and optional)

**Example** (current personal_notes_app has no custom params):
```dart
// initRdfMapper has ONLY these parameters:
// - rdfMapper (optional) → EXCLUDE
// - $indexItemIriFactory (required) → EXCLUDE (starts with $)
// - $resourceIriFactory (required) → EXCLUDE (starts with $)
// - $resourceRefFactory (required) → EXCLUDE (starts with $)

// Result: Empty list (no params to propagate)
List<ParameterInfo> mapperParams = [];
```

**Example** (hypothetical app with custom mapper dependencies):
```dart
// Generated initRdfMapper signature:
RdfMapper initRdfMapper({
  RdfMapper? rdfMapper,
  required CategoryService categoryService,  // Custom dependency
  String? defaultLocale,                      // Custom config
  required IriTermMapper<(String id,)> Function<T>(Type) $indexItemIriFactory,
  required IriTermMapper<(String id,)> Function<T>(RootIriConfig) $resourceIriFactory,
  required IriTermMapper<String> Function<T>(Type) $resourceRefFactory,
})

// Result after filtering:
List<ParameterInfo> mapperParams = [
  ParameterInfo(
    name: 'categoryService',
    type: 'CategoryService',
    isRequired: true,
    isNamed: true,
    defaultValue: null,
  ),
  ParameterInfo(
    name: 'defaultLocale',
    type: 'String?',
    isRequired: false,
    isNamed: true,
    defaultValue: null,
  ),
];
```

### Task 5.4: Implement worker detection logic

**File**: `lib/src/init_locorda_generator.dart` (part of main builder)

**Goal**: Detect presence of `worker_generated.g.dart` to auto-configure worker params.

**Implementation**:
```dart
final hasGeneratedWorker = await buildStep.canRead(
  AssetId(inputId.package, 'lib/worker_generated.g.dart'),
);
```

**Decision rules**:

**If `worker_generated.g.dart` exists**:
- **Remove** `workerSetup` from generated `initLocorda` signature
- **Remove** `jsScript` from generated `initLocorda` signature
- **Auto-set** these in the body:
  ```dart
  return Locorda.create(
    workerSetup: generatedWorkerSetup,
    jsScript: 'worker_generated.dart.js',
    // ... other params
  );
  ```
- **Add import**: `import 'worker_generated.g.dart' show generatedWorkerSetup;`

**If `worker_generated.g.dart` does NOT exist**:
- **Keep** `workerSetup` in signature (required, pass-through)
- **Keep** `jsScript` in signature (optional with default, pass-through)

**Rationale for REMOVE (not optional)**:
- When detected, values are guaranteed correct
- Optional params would add complexity without benefit
- User can still override by editing generated code (it's in source control)
- Simpler mental model: "generator configures what it detects"

### Task 5.5: Implement mapper detection and Lambda generation

**File**: `lib/src/init_locorda_generator.dart`

**Goal**: Detect `init_rdf_mapper.g.dart` and auto-generate `mapperInitializer` parameter.

**Implementation**:
```dart
final hasInitMapper = await buildStep.canRead(
  AssetId(inputId.package, 'lib/init_rdf_mapper.g.dart'),
);

List<ParameterInfo> mapperParams = [];
if (hasInitMapper) {
  mapperParams = await MapperAnalyzer.analyzeInitRdfMapper(buildStep, inputId.package);
}
```

**Decision rules**:

**If `init_rdf_mapper.g.dart` exists**:
1. **Remove** `mapperInitializer` from `initLocorda` signature
2. **Propagate** all filtered parameters from `initRdfMapper` to `initLocorda` signature
3. **Auto-generate** `mapperInitializer` lambda in body:
   ```dart
   mapperInitializer: (context) => initRdfMapper(
     rdfMapper: context.baseRdfMapper,
     $indexItemIriFactory: context.indexItemIriFactory,
     $resourceIriFactory: context.resourceIriFactory,
     $resourceRefFactory: context.resourceRefFactory,
     // ... pass-through any propagated params
   ),
   ```
4. **Add import**: `import 'init_rdf_mapper.g.dart' show initRdfMapper;`

**If `init_rdf_mapper.g.dart` does NOT exist**:
- **Keep** `mapperInitializer` in signature (required, pass-through)

**Lambda generation logic**:
```dart
// Always include framework params (from context):
mapperInitializer: (context) => initRdfMapper(
  rdfMapper: context.baseRdfMapper,
  ${includeIfDetected('$indexItemIriFactory', '$indexItemIriFactory: context.indexItemIriFactory,')}
  ${includeIfDetected('$resourceIriFactory', '$resourceIriFactory: context.resourceIriFactory,')}
  ${includeIfDetected('$resourceRefFactory', '$resourceRefFactory: context.resourceRefFactory,')}
  ${includeIfDetected('$indexShardIriFactory', '$indexShardIriFactory: context.indexShardIriFactory,')}
  // Pass-through any custom params:
  ${for (param in propagatedMapperParams) '${param.name}: ${param.name},'}
),
```

**Note**: Must inspect actual `initRdfMapper` signature to know which `$*` params exist!

### Task 5.6: Implement code generator

**File**: `lib/src/code_generator.dart`

**Goal**: Generate `lib/init_locorda.g.dart` combining all analyzed information.

**Input data**:
- `hasGeneratedWorker`: bool
- `hasInitMapper`: bool  
- `locordaParams`: List<ParameterInfo> (from Locorda.create analysis)
- `mapperParams`: List<ParameterInfo> (from initRdfMapper analysis, filtered)
- `detectedMapperFrameworkParams`: Set<String> (which `$*` params exist)

**Generation steps**:

1. **Header**:
   ```dart
   // GENERATED CODE - DO NOT MODIFY BY HAND
   // ignore_for_file: unused_import
   ```

2. **Imports**:
   ```dart
   import 'package:locorda/locorda.dart';
   ${if hasGeneratedWorker} import 'worker_generated.g.dart' show generatedWorkerSetup;
   ${if hasInitMapper} import 'init_rdf_mapper.g.dart' show initRdfMapper;
   ```

3. **Function signature**:
   ```dart
   /// Convenience wrapper for Locorda.create with auto-detected settings.
   ///
   /// Auto-configures:
   ${if hasGeneratedWorker}
   /// - workerSetup: generatedWorkerSetup (from worker_generated.g.dart)
   /// - jsScript: 'worker_generated.dart.js'
   ${endif}
   ${if hasInitMapper}
   /// - mapperInitializer: Generated from initRdfMapper
   ${endif}
   Future<Locorda> initLocorda({
     ${for param in buildFinalSignature(locordaParams, mapperParams, hasGeneratedWorker, hasInitMapper)}
       ${if param.isRequired}required ${endif}
       ${param.type} ${param.name}
       ${if param.defaultValue != null} = ${param.defaultValue}${endif},
     ${endfor}
   }) async {
   ```

4. **Function body**:
   ```dart
     return Locorda.create(
       ${if hasGeneratedWorker}
       workerSetup: generatedWorkerSetup,
       jsScript: 'worker_generated.dart.js',
       ${endif}
       ${if hasInitMapper}
       mapperInitializer: (context) => initRdfMapper(
         rdfMapper: context.baseRdfMapper,
         ${for frameworkParam in detectedMapperFrameworkParams}
         ${frameworkParam}: context.${frameworkParam.substring(1)},
         ${endfor}
         ${for param in mapperParams}
         ${param.name}: ${param.name},
         ${endfor}
       ),
       ${endif}
       ${for param in locordaPassThroughParams(locordaParams, hasGeneratedWorker, hasInitMapper)}
       ${param.name}: ${param.name},
       ${endfor}
     );
   }
   ```

**Signature building logic** (`buildFinalSignature`):
1. Start with all `Locorda.create` parameters
2. Filter out auto-configured params:
   - Remove `workerSetup` if `hasGeneratedWorker`
   - Remove `jsScript` if `hasGeneratedWorker`
   - Remove `mapperInitializer` if `hasInitMapper`
3. Prepend any propagated `mapperParams` (they become required deps for `initLocorda`)
4. Preserve parameter order, types, defaults, required/optional status

**Example output** (personal_notes_app with all features):
```dart
// lib/init_locorda.g.dart
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: unused_import

import 'package:locorda/locorda.dart';
import 'worker_generated.g.dart' show generatedWorkerSetup;
import 'init_rdf_mapper.g.dart' show initRdfMapper;

/// Convenience wrapper for Locorda.create with auto-detected settings.
///
/// Auto-configures:
/// - workerSetup: generatedWorkerSetup (from worker_generated.g.dart)
/// - jsScript: 'worker_generated.dart.js'
/// - mapperInitializer: Generated from initRdfMapper
Future<Locorda> initLocorda({
  // No mapper params to propagate (initRdfMapper has no custom params in this app)
  
  // Filtered Locorda.create params (workerSetup, jsScript, mapperInitializer removed):
  void onWorkerSpawn()?,
  required LocordaConfig config,
  required StorageMainHandler storage,
  List<RemoteIntegration> remotes = const [],
  List<MainHandlerFactory> plugins = const [],
  IriTermFactory? iriTermFactory,
  RdfCore? rdfCore,
  String? debugName,
}) async {
  return Locorda.create(
    workerSetup: generatedWorkerSetup,
    jsScript: 'worker_generated.dart.js',
    mapperInitializer: (context) => initRdfMapper(
      rdfMapper: context.baseRdfMapper,
      $indexItemIriFactory: context.indexItemIriFactory,
      $resourceIriFactory: context.resourceIriFactory,
      $resourceRefFactory: context.resourceRefFactory,
    ),
    onWorkerSpawn: onWorkerSpawn,
    config: config,
    storage: storage,
    remotes: remotes,
    plugins: plugins,
    iriTermFactory: iriTermFactory,
    rdfCore: rdfCore,
    debugName: debugName,
  );
}
```

### Task 5.7: Implement main builder

**File**: `lib/src/init_locorda_generator.dart`

**Goal**: Orchestrate analysis and generation.

**Implementation outline**:
```dart
class InitLocordaBuilder implements Builder {
  @override
  Map<String, List<String>> get buildExtensions => {
    'pubspec.yaml': ['lib/init_locorda.g.dart'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    final inputId = buildStep.inputId;
    
    // Only process pubspec.yaml
    if (inputId.path != 'pubspec.yaml') return;
    
    // Step 1: Detect worker_generated.g.dart
    final hasGeneratedWorker = await buildStep.canRead(
      AssetId(inputId.package, 'lib/worker_generated.g.dart'),
    );
    
    // Step 2: Detect init_rdf_mapper.g.dart
    final hasInitMapper = await buildStep.canRead(
      AssetId(inputId.package, 'lib/init_rdf_mapper.g.dart'),
    );
    
    // Step 3: Analyze Locorda.create signature
    final locordaAnalyzer = LocordaAnalyzer(buildStep);
    final locordaParams = await locordaAnalyzer.analyzeCreateSignature();
    
    // Step 4: Analyze initRdfMapper signature (if exists)
    List<ParameterInfo> mapperParams = [];
    Set<String> detectedFrameworkParams = {};
    if (hasInitMapper) {
      final mapperAnalyzer = MapperAnalyzer(buildStep, inputId.package);
      final result = await mapperAnalyzer.analyzeInitRdfMapper();
      mapperParams = result.customParams;
      detectedFrameworkParams = result.frameworkParams;
    }
    
    // Step 5: Generate code
    final generator = CodeGenerator(
      hasGeneratedWorker: hasGeneratedWorker,
      hasInitMapper: hasInitMapper,
      locordaParams: locordaParams,
      mapperParams: mapperParams,
      detectedMapperFrameworkParams: detectedFrameworkParams,
    );
    final generatedCode = generator.generate();
    
    // Step 6: Write output
    final outputId = AssetId(inputId.package, 'lib/init_locorda.g.dart');
    await buildStep.writeAsString(outputId, generatedCode);
    
    log.info('Generated init_locorda.g.dart for ${inputId.package}');
  }
}
```

### Task 5.8: Add to locorda_dev applies_builders

**File**: `packages/locorda_dev/build.yaml`

Add the init generator to the meta-builder's `applies_builders` list:
```yaml
applies_builders:
  - locorda_mapping_bootstrap_generator:mapping_bootstrap
  - locorda_rdf_mapper_generator:cache_builder
  - locorda_rdf_mapper_generator:source_builder
  - locorda_rdf_mapper_generator:init_file_builder
  - locorda_builder:worker_generator
  - locorda_builder:web_worker
  - locorda_init_generator:init_locorda_generator  # <-- Add this
```

**Dependency order**: Must run after worker_generator and mapper generators
(because it detects their outputs).

### Task 5.9: Add to locorda_dev pubspec.yaml

**File**: `packages/locorda_dev/pubspec.yaml`

Add dependency:
```yaml
dependencies:
  # ... existing dependencies
  locorda_init_generator: any
```

### Task 5.10: Handle edge cases and validation

**Edge cases to handle**:

1. **Neither worker nor mapper detected**:
   - Generate full pass-through (all Locorda.create params)
   - Still useful as migration helper
   - Log info: "No auto-configuration available; generating pass-through"

2. **Locorda.create signature changes** (future-proofing):
   - Analyzer dynamically extracts params
   - Generated code automatically includes new params
   - No generator code changes needed

3. **initRdfMapper signature varies** (per-app):
   - Analyzer dynamically extracts filtered params
   - Propagated params vary per app
   - Generator handles 0-N custom params gracefully

4. **Circular dependency risk**:
   - `init_locorda.g.dart` imports `worker_generated.g.dart` and `init_rdf_mapper.g.dart`
   - Those files don't import `init_locorda.g.dart`
   - No circular dependency possible

5. **Build order**:
   - `worker_generator` runs on `pubspec.yaml` → outputs `worker_generated.g.dart`
   - `mapper_generator` runs on `*.dart` → outputs `init_rdf_mapper.g.dart`
   - `init_locorda_generator` runs on `pubspec.yaml` → can read both outputs
   - Build system ensures correct order via `required_inputs`

### Task 5.11: Error handling and logging

**Error scenarios**:

1. **Cannot resolve Locorda class**:
   - Log error with package version mismatch hint
   - Skip generation (fail gracefully)

2. **Cannot parse initRdfMapper**:
   - Log warning
   - Proceed without mapper integration (partial generation)

3. **Conflicting parameter names**:
   - If mapper param name conflicts with Locorda param name
   - Log error with parameter names
   - Skip generation

**Logging strategy**:
```dart
// Info: Normal operation
log.info('Generated init_locorda.g.dart with worker and mapper integration');

// Fine: Detection results
log.fine('Detected worker_generated.g.dart: $hasGeneratedWorker');
log.fine('Detected init_rdf_mapper.g.dart: $hasInitMapper');
log.fine('Propagating ${mapperParams.length} mapper parameters');

// Warning: Partial generation
log.warning('Could not analyze initRdfMapper, proceeding without mapper integration');

// Severe: Generation failed
log.severe('Failed to analyze Locorda.create signature', error, stackTrace);
```

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

### Task 7.7: Unit test Locorda.create analyzer

- Test that analyzer correctly extracts all parameters from `Locorda.create`.
- Test handling of generic types: `List<RemoteIntegration>`.
- Test handling of function types: `void Function()?`.
- Test extraction of default values: `jsScript = 'worker.dart.js'`.
- Test distinction between required/optional/named parameters.
- Mock different Locorda.create signatures to test future-proofing.

### Task 7.8: Unit test initRdfMapper analyzer

- Test detection of `init_rdf_mapper.g.dart` existence.
- Test graceful degradation when file doesn't exist (empty result).
- Test filtering of `rdfMapper` parameter.
- Test filtering of `$*` parameters (`$indexItemIriFactory`, etc.).
- Test extraction of custom parameters (required and optional).
- Test detection of which framework params exist in signature.
- Mock various initRdfMapper signatures with different param combinations.

### Task 7.9: Unit test code generator

- Test signature building with various parameter combinations.
- Test parameter filtering based on detection flags.
- Test mapper parameter propagation.
- Test framework parameter detection and Lambda generation.
- Test import generation (conditional imports).
- Test documentation comment generation.
- Test edge case: no detections (full pass-through).
- Test edge case: only worker detected, no mapper.
- Test edge case: only mapper detected, no worker.
- Test edge case: both detected.

### Task 7.10: Integration test init_locorda generation

- Generate `init_locorda.g.dart` for personal_notes_app.
- Verify correct signature (no workerSetup, jsScript, mapperInitializer).
- Verify correct imports (worker_generated, init_rdf_mapper).
- Verify correct Lambda generation with all framework params.
- Verify generated code compiles and type-checks.
- Test with modified initRdfMapper (add custom param) - verify propagation.
- Test without worker_generated.g.dart - verify workerSetup kept in signature.
- Test without init_rdf_mapper.g.dart - verify mapperInitializer kept.

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
Phase 5 (Tasks 5.1–5.11)  initLocorda generator (new package: locorda_init_generator)
    │                      - Task 5.1: Package setup with analyzer dependency
    │                      - Task 5.2: Locorda.create signature analyzer
    │                      - Task 5.3: initRdfMapper signature analyzer
    │                      - Task 5.4: Worker detection logic
    │                      - Task 5.5: Mapper detection and Lambda generation
    │                      - Task 5.6: Code generator implementation
    │                      - Task 5.7: Main builder orchestration
    │                      - Task 5.8–5.9: Integration with locorda_dev
    │                      - Task 5.10–5.11: Edge cases and error handling
    ↓
Phase 6 (Tasks 6.1–6.3)   Update examples and documentation
    │                      - Update to use init_locorda.g.dart
    │                      - Document generated convenience API
    ↓
Phase 7 (Tasks 7.1–7.10)  Tests
    │                      - Tasks 7.1–7.6: Worker generator tests (existing)
    │                      - Tasks 7.7–7.10: initLocorda generator tests (new)
```

**Parallelization opportunities**:
- Phases 1 and 2 can be partially parallelized (Task 2.1 depends on nothing, Task 2.2 depends on 1.1/1.2, Task 2.3 is independent)
- Phase 5 can start after Phase 3 completes (worker_generated.g.dart must exist for detection testing)
- Phase 5 requires RDF mapper generator to be complete (for init_rdf_mapper.g.dart detection)

**Critical path**:
- Phase 5 is on critical path for Phase 6 (examples want to use generated convenience API)
- Phase 5 can be skipped initially - manual `Locorda.create()` works fine with generated worker

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
| **Phase 5: analyzer package adds ~20MB dependency** | Separate package `locorda_init_generator`; only apps using feature pay the cost |
| **Phase 5: Locorda.create signature changes break generator** | Dynamic analysis via `analyzer` package auto-adapts to signature changes |
| **Phase 5: initRdfMapper signature varies per app** | Dynamic parameter extraction and filtering; handles 0-N custom params |
| **Phase 5: Complex AST traversal for generic types** | Use `analyzer` TypeSystem for robust type resolution; extensive testing with various signatures |
| **Phase 5: Parameter name conflicts (mapper vs Locorda)** | Detect conflicts, log error, skip generation; unlikely in practice (mapper uses domain names) |
| **Phase 5: Build order issues (dependencies on generated files)** | Use `required_inputs` in build.yaml; Phase 5 runs after worker and mapper generators |
| **Phase 5: Generated code has syntax errors** | Extensive unit tests for code generation; integration tests compile generated code |
| **Phase 5: Users expect config auto-generation too** | Phase 5 explicitly does NOT generate config (future work); document clearly |
