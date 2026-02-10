# WorkerGeneratorBuilder - Code Walkthrough

This document traces through the `WorkerGeneratorBuilder` code execution step-by-step for the `personal_notes_app` scenario.

---

## Function Execution Flow

### 1. build() - Main Entry Point

```dart
// INPUT
inputId.path = 'pubspec.yaml'  // personal_notes_app
inputId.package = 'personal_notes_app'

// CODE
if (inputId.path != 'pubspec.yaml') {
  return;  // ← NOT executed (path matches)
}

// OUTCOME
→ Continue to manifest discovery
```

### 2. _discoverManifests() - Find All Manifest Files

```dart
// CONFIGURATION READ
excludePackages = {} // empty (default)
manifestFiles = ['lib/locorda_worker.manifest.dart'] // default

// ITERATION (pseudo-code for all packages in packageConfig)
for (final package in packageConfig.packages) {  // ~15+ packages
  
  // For locorda_drift:
  if (excludePackages.contains('locorda_drift')) {
    // Not executed (not in exclude list)
  }
  
  for (final manifestPath in ['lib/locorda_worker.manifest.dart']) {
    final assetId = AssetId('locorda_drift', 'lib/locorda_worker.manifest.dart')
    
    if (await buildStep.canRead(assetId)) {
      // ✅ TRUE - File exists!
      manifests.add(ManifestInfo(
        packageName: 'locorda_drift',
        manifestPath: 'lib/locorda_worker.manifest.dart',
      ));
      break; // Only first found manifest per package
    }
  }
  
  // Similar iteration for: locorda_solid, locorda_gdrive, locorda_dir, personal_notes_app
  // All found ✅
}

// RETURN VALUE
List<ManifestInfo> manifests = [
  ManifestInfo('locorda_drift', 'lib/locorda_worker.manifest.dart'),
  ManifestInfo('locorda_solid', 'lib/locorda_worker.manifest.dart'),
  ManifestInfo('locorda_gdrive', 'lib/locorda_worker.manifest.dart'),
  ManifestInfo('locorda_dir', 'lib/locorda_worker.manifest.dart'),
  ManifestInfo('personal_notes_app', 'lib/locorda_worker.manifest.dart'),
  // possibly more...
]
```

### 3. Bootstrap File Check

```dart
// CODE
final hasMappingBootstrap = await buildStep.canRead(
  AssetId(inputId.package, 'lib/src/generated/mapping_bootstrap.g.dart'),
  // ↓ AssetId('personal_notes_app', 'lib/src/generated/mapping_bootstrap.g.dart')
);

// RESULT
hasMappingBootstrap = true  // ✅ File exists at this exact location
```

### 4. _generateWorkerCode() - Code Generation

#### 4.1 Header

```dart
buffer.writeln('// GENERATED CODE - DO NOT MODIFY BY HAND');
buffer.writeln();  // blank line

// OUTPUT
// GENERATED CODE - DO NOT MODIFY BY HAND
//
```

#### 4.2 Manifest Imports

```dart
for (final manifest in manifests) {
  // Iteration 1: locorda_drift
  final alias = _sanitizePackageName('locorda_drift');
  // → alias = 'locorda_drift' (no hyphens)
  
  final importPath = 'lib/locorda_worker.manifest.dart';
  
  buffer.writeln(
    "import 'package:locorda_drift/lib/locorda_worker.manifest.dart' as locorda_drift;"
  );
  
  // Iterations 2-5: locorda_solid, locorda_gdrive, locorda_dir, personal_notes_app
  // Same pattern...
}

// OUTPUT
import 'package:locorda_drift/lib/locorda_worker.manifest.dart' as locorda_drift;
import 'package:locorda_solid/lib/locorda_worker.manifest.dart' as locorda_solid;
import 'package:locorda_gdrive/lib/locorda_worker.manifest.dart' as locorda_gdrive;
import 'package:locorda_dir/lib/locorda_worker.manifest.dart' as locorda_dir;
import 'package:personal_notes_app/lib/locorda_worker.manifest.dart' as personal_notes_app;
```

#### 4.3 locorda_worker Import

```dart
buffer.writeln("import 'package:locorda_worker/worker.dart';");

// OUTPUT
import 'package:locorda_worker/worker.dart';
```

#### 4.4 Bootstrap Import (Conditional)

```dart
if (hasMappingBootstrap) {  // ✅ TRUE
  buffer.writeln("import 'src/generated/mapping_bootstrap.g.dart';");
}

// OUTPUT
import 'src/generated/mapping_bootstrap.g.dart';
```

#### 4.5 OnWorkerSpawn Import (Conditional)

```dart
final onWorkerSpawnImport = 'package:personal_notes_app/utils/logging_setup.dart';
final onWorkerSpawnFunction = 'setupWorkerLogging';

if (onWorkerSpawnImport != null && onWorkerSpawnFunction != null) {  // ✅ Both TRUE
  buffer.writeln(
    "import 'package:personal_notes_app/utils/logging_setup.dart' show setupWorkerLogging;"
  );
}

// OUTPUT
import 'package:personal_notes_app/utils/logging_setup.dart' show setupWorkerLogging;

// Blank line after all imports
buffer.writeln();
```

#### 4.6 main() Function

```dart
buffer.writeln('/// Worker entry point for web workers.');
buffer.writeln('///');
buffer.writeln('/// On web, the compiled JS is loaded and main() is called automatically.');
buffer.writeln('void main() {');

if (onWorkerSpawnFunction != null) {  // ✅ TRUE
  buffer.writeln(
    '  workerMain(generatedWorkerSetup, onWorkerSpawn: setupWorkerLogging);'
  );
} else {
  // Not executed
  buffer.writeln('  workerMain(generatedWorkerSetup);');
}

buffer.writeln('}');
buffer.writeln();

// OUTPUT
/// Worker entry point for web workers.
///
/// On web, the compiled JS is loaded and main() is called automatically.
void main() {
  workerMain(generatedWorkerSetup, onWorkerSpawn: setupWorkerLogging);
}

```

#### 4.7 generatedWorkerSetup() Function - Documentation

```dart
buffer.writeln('/// Generated worker setup that registers all discovered adapters.');
buffer.writeln('///');
buffer.writeln('/// Active handlers are selected at runtime based on IDs received from main.');
buffer.writeln('///');
buffer.writeln('/// This function is public so main-side code can import and pass it to');
buffer.writeln('/// Locorda.create(workerSetup: generatedWorkerSetup) for isolate spawning.');

// OUTPUT
/// Generated worker setup that registers all discovered adapters.
///
/// Active handlers are selected at runtime based on IDs received from main.
///
/// This function is public so main-side code can import and pass it to
/// Locorda.create(workerSetup: generatedWorkerSetup) for isolate spawning.
```

#### 4.8 generatedWorkerSetup() Function - Signature & Start

```dart
buffer.writeln('Future<WorkerParams> generatedWorkerSetup() async => WorkerParams(');

// OUTPUT
Future<WorkerParams> generatedWorkerSetup() async => WorkerParams(
```

#### 4.9 storages List

```dart
buffer.writeln('  storages: [');

for (final manifest in manifests) {
  // Iteration 1: locorda_drift
  final alias = _sanitizePackageName('locorda_drift');
  // → alias = 'locorda_drift'
  
  buffer.writeln('    ...locorda_drift.storages,');
  
  // Iteration 2-5: similar pattern
  // ...locorda_solid.storages,
  // ...locorda_gdrive.storages,
  // ...locorda_dir.storages,
  // ...personal_notes_app.storages,
}

buffer.writeln('  ],');

// OUTPUT
  storages: [
    ...locorda_drift.storages,
    ...locorda_solid.storages,
    ...locorda_gdrive.storages,
    ...locorda_dir.storages,
    ...personal_notes_app.storages,
  ],
```

#### 4.10 remotes List

```dart
buffer.writeln('  remotes: [');

for (final manifest in manifests) {
  // Same pattern as storages
  buffer.writeln('    ...locorda_drift.remotes,');
  buffer.writeln('    ...locorda_solid.remotes,');
  buffer.writeln('    ...locorda_gdrive.remotes,');
  buffer.writeln('    ...locorda_dir.remotes,');
  buffer.writeln('    ...personal_notes_app.remotes,');
}

buffer.writeln('  ],');

// OUTPUT
  remotes: [
    ...locorda_drift.remotes,
    ...locorda_solid.remotes,
    ...locorda_gdrive.remotes,
    ...locorda_dir.remotes,
    ...personal_notes_app.remotes,
  ],
```

#### 4.11 mappingBootstrapSources

```dart
if (hasMappingBootstrap) {  // ✅ TRUE
  buffer.writeln('  mappingBootstrapSources: bootstrapMappings,');
} else {
  // Not executed
  buffer.writeln('  mappingBootstrapSources: [],');
}

// OUTPUT
  mappingBootstrapSources: bootstrapMappings,
```

#### 4.12 Close WorkerParams

```dart
buffer.writeln(');');

// OUTPUT
);
```

### 5. Write Output File

```dart
final generatedCode = buffer.toString();  // Complete code as string

final outputId = AssetId('personal_notes_app', 'lib/worker.g.dart');

await buildStep.writeAsString(outputId, generatedCode);
// ↓ Writes file to: personal_notes_app/lib/worker.g.dart

log.info('Generated worker.g.dart with 5 manifest(s)');
```

---

## Complete Generated Output

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

## Critical Implementation Points

### Point 1: Manifest Path Includes "lib/"
The import statement uses the FULL path from the package root:
```dart
import 'package:locorda_drift/lib/locorda_worker.manifest.dart' as locorda_drift;
                          ↑
                    lib/ is included!
```

### Point 2: Bootstrap Path is Relative
The bootstrap file is imported as relative path from `lib/`:
```dart
import 'src/generated/mapping_bootstrap.g.dart';
        ↑ Relative to lib/ directory
```

This works because `worker.g.dart` is at `lib/worker.g.dart`, so:
- `lib/worker.g.dart` imports `src/generated/mapping_bootstrap.g.dart`
- Resolves to: `lib/src/generated/mapping_bootstrap.g.dart` ✅

### Point 3: Spread Operator Aggregation
The spread operators (`...`) in lists allow each manifest to contribute zero or more items:

```
locorda_drift manifest:
  storages = [DriftWorkerHandler(...)]
  remotes = []

Final WorkerParams storages after spread:
  [DriftWorkerHandler(...)]  // 1 item

Final WorkerParams remotes after spread:
  [SolidWorkerHandler(...), GDriveWorkerHandler(...), DirWorkerHandler(...) x2]
```

### Point 4: OnWorkerSpawn Callback Pattern
The callback requires BOTH import path AND function name:

```dart
// Configuration
on_worker_spawn_import: 'package:personal_notes_app/utils/logging_setup.dart'
on_worker_spawn_function: 'setupWorkerLogging'

// Generated import
import 'package:personal_notes_app/utils/logging_setup.dart' show setupWorkerLogging;

// Used in main()
workerMain(generatedWorkerSetup, onWorkerSpawn: setupWorkerLogging);
```

---

## Summary

The `WorkerGeneratorBuilder` successfully:

1. **Discovers** all manifest files across packages
2. **Checks** for optional bootstrap file
3. **Reads** onWorkerSpawn configuration
4. **Generates** imports with proper aliases
5. **Aggregates** storages and remotes via spread operators
6. **Includes** optional features (bootstrap, callback)
7. **Creates** complete executable worker with entry point

The generated code is ready to:
- Run on web (via `main()` called by JavaScript)
- Run in Dart VM (via `workerSetup` parameter for isolate spawning)
- Support optional logging setup via callback
- Provide all registered handlers to the worker runtime
