# WorkerGeneratorBuilder Manual Test - Summary

## Quick Reference

### Test Scenario
Testing the `WorkerGeneratorBuilder` code generator for the `personal_notes_app` package by manually tracing through the logic to predict the generated `worker.g.dart` output.

### Files Created for This Test
1. **WORKER_GENERATOR_TEST_CASE.md** - Complete test specification with all inputs/outputs
2. **WORKER_GENERATOR_WALKTHROUGH.md** - Line-by-line code execution walkthrough
3. **MANUAL_TEST_WORKER_GENERATOR.md** - Detailed manifest discovery process

## Key Findings

### ✅ Manifest Discovery
The builder discovers **5 manifest files** across packages:
- ✅ `locorda_drift/lib/locorda_worker.manifest.dart`
- ✅ `locorda_solid/lib/locorda_worker.manifest.dart`
- ✅ `locorda_gdrive/lib/locorda_worker.manifest.dart`
- ✅ `locorda_dir/lib/locorda_worker.manifest.dart`
- ✅ `personal_notes_app/lib/locorda_worker.manifest.dart`

### ✅ Bootstrap Mapping
- ✅ File exists: `personal_notes_app/lib/src/generated/mapping_bootstrap.g.dart`
- ✅ Will be imported and included in generated code

### ✅ OnWorkerSpawn Configuration
From `build.yaml`:
```yaml
on_worker_spawn_import: 'package:personal_notes_app/utils/logging_setup.dart'
on_worker_spawn_function: 'setupWorkerLogging'
```
- ✅ Both import and function name present
- ✅ Will be imported with `show` clause
- ✅ Will be passed to `workerMain()` as callback

## Expected Generated Code

The builder should generate `personal_notes_app/lib/worker.g.dart`:

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

## What This Code Does

### At Build Time
1. Discovers all manifest files from 5 packages
2. Creates import statements with aliases
3. Aggregates storage and remote handlers via spread operators
4. Includes bootstrap mappings for RDF entity mapping
5. Includes optional onWorkerSpawn callback for logging setup

### At Runtime - Web
1. JavaScript calls `main()` automatically when worker script loads
2. `main()` calls `workerMain()` with the generated setup
3. `setupWorkerLogging` callback is invoked to initialize logging in the worker
4. Worker registers all available handlers and waits for messages from main thread

### At Runtime - Dart VM (Isolate)
1. Main isolate can import `generatedWorkerSetup` directly
2. Pass it to `Locorda.create(workerSetup: generatedWorkerSetup)`
3. Creates a worker isolate with all handlers ready
4. Logging is optionally set up when the isolate is created

## Code Generation Logic Verification

### ✅ Import Path Format
```dart
import 'package:{packageName}/{manifestPath}' as {alias};
```
- Correct: uses full path including `lib/`
- Alias sanitizes package name (replaces hyphens with underscores)

### ✅ Bootstrap Path Format
```dart
import 'src/generated/mapping_bootstrap.g.dart';
```
- Relative path from `lib/` directory
- Correctly resolves to `lib/src/generated/mapping_bootstrap.g.dart`

### ✅ Spread Operator Usage
```dart
storages: [
  ...alias.storages,  // Contributes 0+ items
  ...alias.storages,
  ...alias.storages,
]
```
- Each manifest can provide any number of handlers
- Empty lists contribute nothing to final list

### ✅ Conditional Features
```dart
if (hasMappingBootstrap) {
  // Include bootstrap mappings
}
if (onWorkerSpawnFunction != null) {
  // Include onWorkerSpawn callback parameter
}
```
- Both are correctly conditional
- Generate different code based on availability

## Validation Checklist

Before running the actual code generator, verify:

- [ ] WorkerGeneratorBuilder code compiles without errors
- [ ] BuilderOptions correctly parses YAML config
- [ ] AssetId lookups work for all packages
- [ ] Package enumeration includes all expected packages
- [ ] Manifest file discovery finds all 5 files
- [ ] Bootstrap file check returns true
- [ ] Generated code is valid Dart syntax
- [ ] Generated code compiles without errors
- [ ] main() is called with correct function
- [ ] generatedWorkerSetup() returns correct type
- [ ] All 5 manifests are imported
- [ ] All storage handlers are aggregated
- [ ] All remote handlers are aggregated
- [ ] Bootstrap mappings are included
- [ ] Logging callback is properly imported and used

## Next Steps

1. Run the actual code generator with `build_runner`
2. Check that `personal_notes_app/lib/worker.g.dart` matches this expected output
3. Verify the generated file compiles
4. Test that the worker can be run (web and isolate contexts)
5. Verify handlers are correctly registered
6. Verify logging setup callback is invoked

---

**Test Created:** Manual walkthrough of WorkerGeneratorBuilder logic
**Scope:** personal_notes_app package with 5 discovered manifests
**Expected Outcome:** Single well-formed worker.g.dart file with aggregated handlers
