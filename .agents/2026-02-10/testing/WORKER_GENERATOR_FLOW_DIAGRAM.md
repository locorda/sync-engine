# WorkerGeneratorBuilder - Flow Diagram

## Build Process Flow

```
┌─────────────────────────────────────────────────────────────┐
│ personal_notes_app/pubspec.yaml                             │
│ (triggers the build process)                                │
└──────────────────────┬──────────────────────────────────────┘
                       │
                       ▼
        ┌──────────────────────────────┐
        │ WorkerGeneratorBuilder.build()│
        └──────────────────┬───────────┘
                           │
                           ▼
        ┌──────────────────────────────────────┐
        │ Read Configuration from build.yaml   │
        │ ├─ exclude_packages: []              │
        │ ├─ manifest_files: [...]            │
        │ ├─ on_worker_spawn_import: pkg:...  │
        │ └─ on_worker_spawn_function: fn     │
        └──────────────────┬───────────────────┘
                           │
                           ▼
        ┌──────────────────────────────────────┐
        │ _discoverManifests()                 │
        │ (scan all packages for manifests)    │
        └──────────────────┬───────────────────┘
                           │
         ┌─────────────────┼─────────────────┐
         │                 │                 │
         ▼                 ▼                 ▼
    locorda_drift     locorda_solid    locorda_gdrive
    [✅ found]         [✅ found]        [✅ found]
         │                 │                 │
         └─────────────────┼─────────────────┘
                           │
         ┌─────────────────┼─────────────────────┐
         │                 │                     │
         ▼                 ▼                     ▼
    locorda_dir      personal_notes_app    other packages
    [✅ found]       [✅ found]             [skipped]
         │                 │
         └─────────────────┘
                   │
                   ▼
    List<ManifestInfo> manifests = [
      ManifestInfo('locorda_drift', 'lib/locorda_worker.manifest.dart'),
      ManifestInfo('locorda_solid', 'lib/locorda_worker.manifest.dart'),
      ManifestInfo('locorda_gdrive', 'lib/locorda_worker.manifest.dart'),
      ManifestInfo('locorda_dir', 'lib/locorda_worker.manifest.dart'),
      ManifestInfo('personal_notes_app', 'lib/locorda_worker.manifest.dart'),
    ]
                   │
                   ▼
        ┌──────────────────────────────────────┐
        │ Check Bootstrap File                 │
        │ lib/src/generated/...g.dart          │
        └──────────────────┬───────────────────┘
                           │
                    ✅ EXISTS (true)
                           │
                           ▼
        ┌──────────────────────────────────────┐
        │ _generateWorkerCode()                │
        │                                      │
        │ Parameters:                          │
        │ ├─ manifests: [5 items]             │
        │ ├─ hasMappingBootstrap: true        │
        │ ├─ onWorkerSpawnImport: pkg:...     │
        │ └─ onWorkerSpawnFunction: fn        │
        └──────────────────┬───────────────────┘
                           │
                           ▼
              ┌────────────────────────┐
              │ StringBuffer            │
              │ content building        │
              └────────────────────────┘
                    │         │         │
         ┌──────────┘         │         └──────────┐
         │                    │                    │
         ▼                    ▼                    ▼
    ┌────────────┐       ┌──────────┐       ┌────────────┐
    │ Generate   │       │ Generate │       │ Generate   │
    │ Imports    │       │ main()   │       │ setup()    │
    │ Section    │       │ Function │       │ Function   │
    └────────────┘       └──────────┘       └────────────┘
         │                    │                    │
         └────────────┬───────┴────────┬───────────┘
                      │                │
                      ▼                ▼
              Buffer.toString() → Complete Code
                      │
                      ▼
        ┌──────────────────────────────────────┐
        │ Write to File                        │
        │ personal_notes_app/lib/worker.g.dart │
        └──────────────────┬───────────────────┘
                           │
                           ▼
                      [Build Complete]
```

---

## Manifest Discovery Detail

```
PackageConfig Iterator
├─ locorda_drift
│  └─ Check: lib/locorda_worker.manifest.dart → ✅ FOUND
│     └─ Add to manifests list, break
│
├─ locorda_solid
│  └─ Check: lib/locorda_worker.manifest.dart → ✅ FOUND
│     └─ Add to manifests list, break
│
├─ locorda_gdrive
│  └─ Check: lib/locorda_worker.manifest.dart → ✅ FOUND
│     └─ Add to manifests list, break
│
├─ locorda_dir
│  └─ Check: lib/locorda_worker.manifest.dart → ✅ FOUND
│     └─ Add to manifests list, break
│
├─ personal_notes_app
│  └─ Check: lib/locorda_worker.manifest.dart → ✅ FOUND
│     └─ Add to manifests list, break
│
├─ locorda_worker
│  └─ Check: lib/locorda_worker.manifest.dart → ✅ FOUND (but may not be included)
│
└─ ... (other packages)
   └─ Check: lib/locorda_worker.manifest.dart → ❌ NOT FOUND
      └─ Skip
```

---

## Generated Code Structure

```
worker.g.dart
│
├─ HEADER
│  └─ // GENERATED CODE - DO NOT MODIFY BY HAND
│
├─ IMPORTS (all manifest files)
│  ├─ import 'package:locorda_drift/lib/locorda_worker.manifest.dart' as locorda_drift;
│  ├─ import 'package:locorda_solid/lib/locorda_worker.manifest.dart' as locorda_solid;
│  ├─ import 'package:locorda_gdrive/lib/locorda_worker.manifest.dart' as locorda_gdrive;
│  ├─ import 'package:locorda_dir/lib/locorda_worker.manifest.dart' as locorda_dir;
│  └─ import 'package:personal_notes_app/lib/locorda_worker.manifest.dart' as personal_notes_app;
│
├─ IMPORTS (dependencies)
│  ├─ import 'package:locorda_worker/worker.dart';
│  ├─ import 'src/generated/mapping_bootstrap.g.dart';
│  └─ import 'package:personal_notes_app/utils/logging_setup.dart' show setupWorkerLogging;
│
├─ main() FUNCTION
│  ├─ Documentation
│  └─ workerMain(generatedWorkerSetup, onWorkerSpawn: setupWorkerLogging);
│
└─ generatedWorkerSetup() FUNCTION
   ├─ Documentation
   ├─ Future<WorkerParams> generatedWorkerSetup() async => WorkerParams(
   ├─ storages: [
   │  ├─ ...locorda_drift.storages,
   │  ├─ ...locorda_solid.storages,
   │  ├─ ...locorda_gdrive.storages,
   │  ├─ ...locorda_dir.storages,
   │  └─ ...personal_notes_app.storages,
   ├─ remotes: [
   │  ├─ ...locorda_drift.remotes,
   │  ├─ ...locorda_solid.remotes,
   │  ├─ ...locorda_gdrive.remotes,
   │  ├─ ...locorda_dir.remotes,
   │  └─ ...personal_notes_app.remotes,
   ├─ mappingBootstrapSources: bootstrapMappings,
   └─ );
```

---

## Handler Aggregation

```
STORAGE HANDLERS
┌─────────────────────────────────────┐
│ generatedWorkerSetup() - storages   │
├─────────────────────────────────────┤
│ ...locorda_drift.storages           │
│  └─ DriftWorkerHandler(...)         │ ← 1 handler
│                                     │
│ ...locorda_solid.storages           │
│  └─ (empty list)                    │ ← 0 handlers
│                                     │
│ ...locorda_gdrive.storages          │
│  └─ (empty list)                    │ ← 0 handlers
│                                     │
│ ...locorda_dir.storages             │
│  └─ (empty list)                    │ ← 0 handlers
│                                     │
│ ...personal_notes_app.storages      │
│  └─ (empty list)                    │ ← 0 handlers
└─────────────────────────────────────┘
       Final Result: 1 handler


REMOTE HANDLERS
┌──────────────────────────────────────┐
│ generatedWorkerSetup() - remotes     │
├──────────────────────────────────────┤
│ ...locorda_drift.remotes             │
│  └─ (empty list)                     │ ← 0 handlers
│                                      │
│ ...locorda_solid.remotes             │
│  └─ SolidWorkerHandler(...)          │ ← 1 handler
│                                      │
│ ...locorda_gdrive.remotes            │
│  └─ GDriveWorkerHandler(...)         │ ← 1 handler
│                                      │
│ ...locorda_dir.remotes               │
│  └─ DirWorkerHandler(...) if ...     │ ← 0-1 handler (platform-dependent)
│                                      │
│ ...personal_notes_app.remotes        │
│  └─ DirWorkerHandler(...) if ...     │ ← 0-1 handler (platform-dependent)
└──────────────────────────────────────┘
       Final Result: 2-4 handlers
```

---

## Import Path Resolution

### Manifest Imports
```
Source: package:locorda_drift/lib/locorda_worker.manifest.dart
                ↓
Resolved from: locorda_drift/
                ├─ lib/
                └─ locorda_worker.manifest.dart
```

### Bootstrap Import (Relative)
```
File Location: personal_notes_app/lib/worker.g.dart
Relative Import: src/generated/mapping_bootstrap.g.dart
                ↓
Resolves To: personal_notes_app/lib/src/generated/mapping_bootstrap.g.dart ✅
```

### Logging Setup Import
```
Source: package:personal_notes_app/utils/logging_setup.dart
Show: setupWorkerLogging
                ↓
Imports only: setupWorkerLogging function from logging_setup.dart
Used in: workerMain(generatedWorkerSetup, onWorkerSpawn: setupWorkerLogging)
```

---

## Conditional Feature Decision Tree

```
START: _generateWorkerCode()
│
├─ hasMappingBootstrap?
│  ├─ YES → Include: import 'src/generated/mapping_bootstrap.g.dart';
│  │        Include: mappingBootstrapSources: bootstrapMappings,
│  └─ NO  → Include: mappingBootstrapSources: [],
│
├─ onWorkerSpawnFunction != null?
│  ├─ YES → Include: import '{import}' show '{function}';
│  │        Include: workerMain(generatedWorkerSetup, onWorkerSpawn: setupWorkerLogging);
│  └─ NO  → Include: workerMain(generatedWorkerSetup);
│
└─ DONE
```

---

## Package Name Sanitization

```
Input: locorda-worker
           ↓
Replace hyphens with underscores
           ↓
Output: locorda_worker

Input: locorda_drift
           ↓
No hyphens present
           ↓
Output: locorda_drift
```

---

## Runtime Execution Paths

### Path 1: Web Worker
```
┌──────────────────────────┐
│ JavaScript Web Worker    │
│ Loads compiled .js       │
└──────────┬───────────────┘
           │
           ▼ Calls main()
┌──────────────────────────┐
│ void main() {            │
│   workerMain(            │
│     generatedWorkerSetup,│
│     onWorkerSpawn:       │
│       setupWorkerLogging │
│   );                     │
│ }                        │
└──────────┬───────────────┘
           │
           ▼ Calls generatedWorkerSetup()
┌──────────────────────────┐
│ Future<WorkerParams>     │
│ ├─ storages: [...]       │
│ ├─ remotes: [...]        │
│ └─ mappings: [...]       │
└──────────┬───────────────┘
           │
           ▼ Invokes setupWorkerLogging
┌──────────────────────────┐
│ setupWorkerLogging()     │
│ (configure logging)      │
└──────────┬───────────────┘
           │
           ▼
    Worker ready
```

### Path 2: Dart VM Isolate
```
┌──────────────────────────┐
│ Main Isolate             │
│ Imports generatedWorkerSetup
└──────────┬───────────────┘
           │
           ▼
┌──────────────────────────┐
│ Locorda.create(          │
│   workerSetup:           │
│     generatedWorkerSetup │
│ )                        │
└──────────┬───────────────┘
           │
           ▼ Spawns isolate
┌──────────────────────────┐
│ Worker Isolate           │
│ Calls generatedWorkerSetup()
└──────────┬───────────────┘
           │
           ▼
┌──────────────────────────┐
│ Future<WorkerParams>     │
│ ├─ storages: [...]       │
│ ├─ remotes: [...]        │
│ └─ mappings: [...]       │
└──────────┬───────────────┘
           │
           ▼
    Workers connected
```

---

## Summary: What Gets Generated

| Component | Source | Include | Count |
|-----------|--------|---------|-------|
| Manifest Imports | Discovery | Always | 5 |
| Worker Import | Fixed | Always | 1 |
| Bootstrap Import | File check | Conditional | 0-1 |
| OnWorkerSpawn Import | Config | Conditional | 0-1 |
| main() Function | Fixed | Always | 1 |
| generatedWorkerSetup() | Fixed | Always | 1 |
| Storage Handlers | Manifests | Spread | Variable |
| Remote Handlers | Manifests | Spread | Variable |
| Bootstrap Mappings | Bootstrap file | Conditional | 0+ |
| OnWorkerSpawn Callback | Config | Conditional | 0-1 |

