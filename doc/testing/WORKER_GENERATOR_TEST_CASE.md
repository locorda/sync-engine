# WorkerGeneratorBuilder - Manual Test Case

## Objective
Manually verify that the WorkerGeneratorBuilder generates the correct `worker.g.dart` file for `personal_notes_app` by tracing through the generator logic.

---

## Input Configuration

### Package Being Processed
- **Package:** `personal_notes_app`
- **Trigger File:** `pubspec.yaml`

### Build Options (from build.yaml)
```yaml
locorda_builder|worker_generator:
  options:
    on_worker_spawn_import: 'package:personal_notes_app/utils/logging_setup.dart'
    on_worker_spawn_function: 'setupWorkerLogging'
    exclude_packages: []  # default
    manifest_files: ['lib/locorda_worker.manifest.dart']  # default
```

---

## Step 1: Manifest Discovery Process

### 1.1 Scan All Packages
The builder iterates through all available packages and checks for manifests:

| Package | Manifest Path | Status | Found |
|---------|---------------|--------|-------|
| locorda_drift | lib/locorda_worker.manifest.dart | ✅ | YES |
| locorda_solid | lib/locorda_worker.manifest.dart | ✅ | YES |
| locorda_gdrive | lib/locorda_worker.manifest.dart | ✅ | YES |
| locorda_dir | lib/locorda_worker.manifest.dart | ✅ | YES |
| personal_notes_app | lib/locorda_worker.manifest.dart | ✅ | YES |
| locorda_worker | lib/locorda_worker.manifest.dart | ✅ | YES (but may not be included based on discovery order) |

### 1.2 Manifest Content

**locorda_drift/lib/locorda_worker.manifest.dart:**
```dart
final storages = <StorageWorkerHandler>[
  DriftWorkerHandler(id: driftStorageHandlerId),
];
final remotes = <RemoteWorkerHandler>[];
```

**locorda_solid/lib/locorda_worker.manifest.dart:**
```dart
final storages = <StorageWorkerHandler>[];
final remotes = <RemoteWorkerHandler>[
  SolidWorkerHandler(id: solidRemoteHandlerId),
];
```

**locorda_gdrive/lib/locorda_worker.manifest.dart:**
```dart
final storages = <StorageWorkerHandler>[];
final remotes = <RemoteWorkerHandler>[
  GDriveWorkerHandler(id: gDriveRemoteHandlerId),
];
```

**locorda_dir/lib/locorda_worker.manifest.dart:**
```dart
final storages = <StorageWorkerHandler>[];
final remotes = <RemoteWorkerHandler>[
  if (DirWorkerHandler.isPlatformSupported) ...[
    DirWorkerHandler(id: directoryRemoteHandlerId),
  ],
];
```

**personal_notes_app/lib/locorda_worker.manifest.dart:**
```dart
final storages = <StorageWorkerHandler>[];
final remotes = <RemoteWorkerHandler>[
  if (DirWorkerHandler.isPlatformSupported) ...[
    DirWorkerHandler(id: dirDatasetPerShardRemoteId, useShardDatasets: true),
  ],
];
```

---

## Step 2: Bootstrap Mapping Check

### 2.1 File Existence Check
- **Checked Path:** `lib/src/generated/mapping_bootstrap.g.dart`
- **Package:** `personal_notes_app`
- **Status:** ✅ **EXISTS**
- **Action:** Include `bootstrapMappings` in generated code

---

## Step 3: Package Name Sanitization

### 3.1 Alias Generation
The generator creates aliases by replacing hyphens with underscores:

| Package Name | Alias |
|--------------|-------|
| locorda_drift | locorda_drift |
| locorda_solid | locorda_solid |
| locorda_gdrive | locorda_gdrive |
| locorda_dir | locorda_dir |
| personal_notes_app | personal_notes_app |

(No hyphens present, so aliases match package names exactly)

---

## Step 4: Expected Generated Code

### Output File: `personal_notes_app/lib/worker.g.dart`

```dart
// GENERATED CODE - DO NOT MODIFY BY HAND

import 'package:locorda_drift/lib/locorda_worker.manifest.dart' as locorda_drift;
import 'package:locorda_solid/lib/locorda_worker.manifest.dart' as locorda_solid;
import 'package:locorda_gdrive/lib/locorda_worker.manifest.dart' as locorda_gdrive;
import 'package:locorda_dir/lib/locorda_worker.manifest.dart' as locorda_dir;
import 'package:personal_notes_app/lib/locorda_worker.manifest.dart' as personal_notes_app;
import 'package:locorda_worker/worker.dart';
import 'src/generated/mapping_bootstrap.g.dart';
import 'package:personal_notes_app/utils/logging_setup.dart' show setupWorkerLogging;

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

---

## Step 5: Code Generation Verification Checklist

### 5.1 Header
- [x] Comment: `// GENERATED CODE - DO NOT MODIFY BY HAND`
- [x] Blank line after header

### 5.2 Manifest Imports
- [x] 5 manifest imports generated
- [x] Format: `import 'package:{packageName}/lib/locorda_worker.manifest.dart' as {alias};`
- [x] Aliases created correctly
- [x] Each import on separate line
- [x] Blank line after manifest imports

### 5.3 Package Imports
- [x] `locorda_worker/worker.dart` imported
- [x] `mapping_bootstrap.g.dart` conditionally imported (file exists)
- [x] Relative path for bootstrap: `src/generated/mapping_bootstrap.g.dart`
- [x] onWorkerSpawn import present: `package:personal_notes_app/utils/logging_setup.dart`
- [x] Show clause used: `show setupWorkerLogging`
- [x] Blank line after imports

### 5.4 main() Function
- [x] Documentation comment included
- [x] Function signature: `void main() {`
- [x] Call to: `workerMain(generatedWorkerSetup, onWorkerSpawn: setupWorkerLogging);`
- [x] Closing brace on new line
- [x] Blank line after function

### 5.5 generatedWorkerSetup() Function
- [x] Documentation comment included
- [x] Function signature: `Future<WorkerParams> generatedWorkerSetup() async =>`
- [x] Returns `WorkerParams(` with proper formatting
- [x] **storages** list:
  - [x] 5 spread operators: `...locorda_drift.storages,` etc.
  - [x] Closing bracket with comma
- [x] **remotes** list:
  - [x] 5 spread operators: `...locorda_drift.remotes,` etc.
  - [x] Closing bracket with comma
- [x] **mappingBootstrapSources**:
  - [x] `bootstrapMappings` included (not empty array)
- [x] Closing parenthesis and semicolon
- [x] No trailing blank line

---

## Step 6: Runtime Behavior

### 6.1 Manifest Aggregation
When `generatedWorkerSetup()` executes:
1. Spreads storage handlers from all 5 manifests
   - Result: `[DriftWorkerHandler(...)]` (4 empty lists)
2. Spreads remote handlers from all 5 manifests
   - Result: `[SolidWorkerHandler(...), GDriveWorkerHandler(...), DirWorkerHandler(...) conditionally x2]`
3. Includes bootstrap mappings from `mapping_bootstrap.g.dart`

### 6.2 Worker Entry Point
When `main()` is called (by JavaScript on web):
1. Calls `workerMain()` with:
   - `generatedWorkerSetup` function reference
   - `onWorkerSpawn: setupWorkerLogging` callback
2. The callback will be invoked when the worker spawns to set up logging

---

## Step 7: Key Implementation Details to Verify

### 7.1 Import Format
The import uses the **full manifest file path**, not just the package:
```dart
import 'package:locorda_drift/lib/locorda_worker.manifest.dart' as locorda_drift;
                         └─ lib/ is included in the path
```

### 7.2 Bootstrap Path
The bootstrap is imported as a **relative path** from the worker.g.dart file:
```dart
import 'src/generated/mapping_bootstrap.g.dart';
        └─ relative to lib/ directory
```

### 7.3 Spread Operator Aggregation
All manifests contribute to the lists via spread operators:
```dart
storages: [
  ...locorda_drift.storages,      // DriftWorkerHandler
  ...locorda_solid.storages,      // (empty)
  ...locorda_gdrive.storages,     // (empty)
  ...locorda_dir.storages,        // (empty)
  ...personal_notes_app.storages, // (empty)
],
```

### 7.4 OnWorkerSpawn Conditions
Both conditions must be true for the callback:
```dart
✅ on_worker_spawn_import is not null
✅ on_worker_spawn_function is not null
→ Then import and use in workerMain() call
```

---

## Test Success Criteria

The generated `worker.g.dart` should:

1. ✅ Exist at `personal_notes_app/lib/worker.g.dart`
2. ✅ Have exactly 5 manifest imports
3. ✅ Include all 3 dependency imports (locorda_worker, mapping_bootstrap, logging_setup)
4. ✅ Have a `main()` function that accepts no parameters
5. ✅ Have `main()` call `workerMain()` with onWorkerSpawn callback
6. ✅ Have `generatedWorkerSetup()` function that returns `Future<WorkerParams>`
7. ✅ Aggregate storages from all 5 manifests
8. ✅ Aggregate remotes from all 5 manifests
9. ✅ Include `bootstrapMappings` in the WorkerParams
10. ✅ Be valid Dart code that compiles without errors

---

## Notes

- The actual order of packages may vary depending on `buildStep.packageConfig` iteration order
- The `locorda_worker` manifest may or may not be included depending on package enumeration
- Platform-specific handlers (like DirWorkerHandler) will be filtered at runtime via `if (DirWorkerHandler.isPlatformSupported)`
- The generated code is idempotent—running the builder multiple times should produce identical output
