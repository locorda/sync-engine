# Worker Generator - Phase 3 Implementation

This document describes the implementation of Phase 3 of the worker generator tasks from `proposed-changes/018-worker-generator-tasks.md`.

## What Was Implemented

### 1. Worker Generator Builder (Tasks 3.1 & 3.3)

**File**: `packages/locorda_builder/lib/src/worker_generator_builder.dart`

The `WorkerGeneratorBuilder` is a build_runner builder that:
- Triggers on `pubspec.yaml` (similar to mapping_bootstrap generator)
- Discovers manifest files across all packages using `buildStep.packageConfig`
- Filters packages based on `exclude_packages` configuration
- Conditionally imports `mapping_bootstrap.g.dart` if it exists
- Supports optional `onWorkerSpawn` callback configuration
- Generates complete executable worker with `main()` entry point

**Key Features**:
- **Manifest Discovery**: Uses `buildStep.canRead()` to probe each package for manifest files
- **Package Name Sanitization**: Converts hyphens to underscores for valid Dart identifiers
- **Conditional Imports**: Only imports mapping_bootstrap and onWorkerSpawn when present
- **Aggregation**: Spreads all `storages` and `remotes` from discovered manifests

### 2. Builder Registration (Tasks 3.1 & 3.4)

**Files Modified**:
- `packages/locorda_builder/lib/builder.dart` - Exports `workerGeneratorBuilder()`
- `packages/locorda_builder/build.yaml` - Registers `worker_generator` builder
- `packages/locorda_dev/build.yaml` - Adds to `applies_builders` list

The builder is configured to:
- Generate `lib/worker.g.dart` from `pubspec.yaml`
- Auto-apply to dependent packages
- Run before `web_worker` builder

### 3. Web Worker Priority (Task 4.1)

**File**: `packages/locorda_builder/lib/src/web_worker_builder.dart`

Updated `WebWorkerBuilder` to:
- Accept both `lib/worker.dart` and `lib/worker.g.dart` as inputs
- Implement priority logic: manual `worker.dart` takes precedence
- Skip `worker.g.dart` compilation if `worker.dart` exists
- Log which file is being used for transparency

This provides:
- **Gradual migration path**: Generated file is ignored while manual file exists
- **Escape hatch**: Create `lib/worker.dart` to override generation
- **Clean transition**: Delete manual file to use generated version

### 4. Configuration Support

**File**: `packages/locorda/example/personal_notes_app/build.yaml` (new)

Created build configuration for personal_notes_app demonstrating:
```yaml
targets:
  $default:
    builders:
      locorda_builder|worker_generator:
        options:
          on_worker_spawn_import: 'package:personal_notes_app/utils/logging_setup.dart'
          on_worker_spawn_function: 'setupWorkerLogging'
```

## Generated Output Format

The generated `lib/worker.g.dart` includes:

1. **Header**: Generated code warning
2. **Manifest Imports**: All discovered manifests with sanitized aliases
3. **Framework Import**: locorda_worker package
4. **Conditional Imports**:
   - `mapping_bootstrap.g.dart` (if exists)
   - onWorkerSpawn callback (if configured)
5. **main() Function**: Entry point calling `workerMain()`
6. **generatedWorkerSetup() Function**: Public async function for isolate spawning

### Example Output

For personal_notes_app with all features enabled:

```dart
// GENERATED CODE - DO NOT MODIFY BY HAND

import 'package:locorda_drift/locorda_worker.manifest.dart' as locorda_drift;
import 'package:locorda_solid/locorda_worker.manifest.dart' as locorda_solid;
import 'package:locorda_gdrive/locorda_worker.manifest.dart' as locorda_gdrive;
import 'package:locorda_dir/locorda_worker.manifest.dart' as locorda_dir;
import 'package:personal_notes_app/locorda_worker.manifest.dart' as personal_notes_app;
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

## Configuration Options

### Builder Options

```yaml
locorda_builder|worker_generator:
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

### Usage Examples

**Minimal (no configuration needed)**:
- Builder automatically generates `worker.g.dart`
- Includes all adapter manifests from dependencies
- Empty `mappingBootstrapSources` if no RDF mapper

**Custom manifest**:
```dart
// lib/locorda_worker.manifest.dart
final storages = <StorageWorkerHandler>[];
final remotes = <RemoteWorkerHandler>[
  // Custom handler configurations
];
```

**Advanced configuration**:
```yaml
locorda_builder|worker_generator:
  options:
    exclude_packages: ['test_fixtures']
    manifest_files: ['lib/custom_worker.manifest.dart']
    on_worker_spawn_import: 'package:my_app/setup.dart'
    on_worker_spawn_function: 'setupWorker'
```

## Migration Path

1. **Current state**: Apps have manual `worker.dart` files
2. **After Phase 3**: `worker.g.dart` generated but ignored (manual takes priority)
3. **Transition**: Delete manual `worker.dart` → `worker.g.dart` compiles automatically
4. **Escape hatch**: Create `lib/worker.dart` to override generation

## What's Left

The following tasks from Phase 3 still need completion:

- [ ] **Testing**: Create unit tests for manifest discovery and code generation
- [ ] **Integration Testing**: Run `dart run build_runner build` on example apps
- [ ] **Verification**: Confirm generated `worker.g.dart` matches specification
- [ ] **Documentation**: Update package READMEs with generator usage

## Next Steps

To complete Phase 3:

1. Install Dart SDK in test environment
2. Run `dart pub get` in workspace
3. Run `dart run build_runner build` in personal_notes_app
4. Verify generated `lib/worker.g.dart` content
5. Test compilation to `web/worker.dart.js`
6. Create unit tests for the builder
7. Update documentation with usage examples

## Related Files

- **Specification**: `proposed-changes/018-worker-generator-tasks.md`
- **Builder Implementation**: `packages/locorda_builder/lib/src/worker_generator_builder.dart`
- **Web Worker Builder**: `packages/locorda_builder/lib/src/web_worker_builder.dart`
- **Builder Registration**: `packages/locorda_builder/build.yaml`
- **Meta Builder**: `packages/locorda_dev/build.yaml`
- **Example Config**: `packages/locorda/example/personal_notes_app/build.yaml`

## Prerequisites (Already Complete)

✅ Phase 1: Storage/Remote handlers have `id` fields  
✅ Phase 2: Manifest files created in all adapter packages
