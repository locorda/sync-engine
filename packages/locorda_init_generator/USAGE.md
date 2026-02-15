# locorda_init_generator Usage Guide

## Overview

The `locorda_init_generator` package generates a convenience wrapper function `initLocorda()` that simplifies Locorda initialization by auto-detecting and configuring commonly-used parameters.

## What It Does

The generator analyzes your project and:

1. **Detects `worker_generated.g.dart`** → Auto-configures `workerSetup` and `jsScript`
2. **Detects `init_rdf_mapper.g.dart`** → Auto-generates `mapperInitializer` lambda
3. **Propagates custom parameters** → Passes through any custom dependencies from `initRdfMapper`
4. **Pass-through all other params** → All other `Locorda.create` parameters remain available

## Before and After

### Before (Manual Configuration)

```dart
import 'package:locorda/locorda.dart';
import 'worker_generated.g.dart';
import 'init_rdf_mapper.g.dart';

Future<Locorda> setupLocorda() async {
  return Locorda.create(
    // Must manually reference generated worker
    workerSetup: generatedWorkerSetup,
    jsScript: 'worker_generated.dart.js',
    
    // Must manually wire up mapper with framework params
    mapperInitializer: (context) => initRdfMapper(
      rdfMapper: context.baseRdfMapper,
      $indexItemIriFactory: context.indexItemIriFactory,
      $resourceIriFactory: context.resourceIriFactory,
      $resourceRefFactory: context.resourceRefFactory,
    ),
    
    // Application-specific configuration
    config: myConfig,
    storage: myStorage,
    remotes: myRemotes,
  );
}
```

### After (Generated Convenience Wrapper)

```dart
import 'package:your_app/init_locorda.g.dart';

Future<Locorda> setupLocorda() async {
  return initLocorda(
    // Auto-configured: workerSetup, jsScript, mapperInitializer
    config: myConfig,
    storage: myStorage,
    remotes: myRemotes,
  );
}
```

**Benefits:**
- ✅ Less boilerplate
- ✅ No manual import management
- ✅ Type-safe parameter handling
- ✅ Automatic detection of generated files

## Generated Code Example

For a project with `worker_generated.g.dart` and `init_rdf_mapper.g.dart`:

```dart
// lib/init_locorda.g.dart
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: unused_import, depend_on_referenced_packages

import 'package:locorda_flutter/locorda_flutter.dart';
import 'worker_generated.g.dart' show generatedWorkerSetup;
import 'init_rdf_mapper.g.dart' show initRdfMapper;

/// Convenience wrapper for Locorda.create with auto-detected settings.
///
/// Auto-configures:
/// - workerSetup: generatedWorkerSetup (from worker_generated.g.dart)
/// - jsScript: 'worker_generated.dart.js'
/// - mapperInitializer: Generated from initRdfMapper
Future<Locorda> initLocorda({
  required LocordaConfig config,
  required StorageMainHandler storage,
  void Function()? onWorkerSpawn,
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
    config: config,
    storage: storage,
    onWorkerSpawn: onWorkerSpawn,
    remotes: remotes,
    plugins: plugins,
    iriTermFactory: iriTermFactory,
    rdfCore: rdfCore,
    debugName: debugName,
  );
}
```

## Custom Parameters Propagation

If your `initRdfMapper` has custom parameters (beyond the framework-provided ones), they will be automatically propagated:

```dart
// Your generated init_rdf_mapper.g.dart with custom param
RdfMapper initRdfMapper({
  RdfMapper? rdfMapper,
  required CategoryService categoryService,  // Custom!
  required IriTermMapper<(String id,)> Function<T>(Type) $indexItemIriFactory,
  // ... other framework params
}) {
  // ...
}

// Generated init_locorda.g.dart will include it
Future<Locorda> initLocorda({
  required CategoryService categoryService,  // Propagated!
  required LocordaConfig config,
  // ... other params
}) async {
  return Locorda.create(
    mapperInitializer: (context) => initRdfMapper(
      rdfMapper: context.baseRdfMapper,
      categoryService: categoryService,  // Passed through!
      $indexItemIriFactory: context.indexItemIriFactory,
      // ...
    ),
    // ...
  );
}
```

## Installation

Add to your `pubspec.yaml`:

```yaml
dev_dependencies:
  locorda_dev: any
  build_runner: ^2.4.0
```

Then run:

```bash
dart run build_runner build
```

The generator runs automatically and produces `lib/init_locorda.g.dart`.

## Edge Cases

### No Generated Files

If neither `worker_generated.g.dart` nor `init_rdf_mapper.g.dart` exist, the generator creates a pass-through wrapper that just calls `Locorda.create` with all parameters.

### Manual Worker

If you have a manual `lib/worker.dart` instead of `worker_generated.g.dart`, the generator will still require `workerSetup` and `jsScript` as parameters.

### No RDF Mapper

If you don't use the RDF mapper generator, the generated function will require `mapperInitializer` as a parameter.

### CRDT Mapping IRI Validation

CRDT mapping IRIs provided via `@LcrdRootResource(crdt: LcrdCrdt(...))` are validated during CRDT mapping generation:

- The base IRI must be absolute.
- A non-empty fragment (e.g. `#v1`) is rejected.
- If the IRI has no fragment, a trailing `#` is added for the document mapping subject.

## Debugging

If generation fails or produces unexpected output:

1. Check build_runner output: `dart run build_runner build --verbose`
2. View generated file: `lib/init_locorda.g.dart`
3. Verify input files exist:
   - `lib/worker_generated.g.dart`
   - `lib/init_rdf_mapper.g.dart`

## Future Enhancements

The current implementation uses hardcoded `Locorda.create` parameters. Future versions may:
- Dynamically analyze `Locorda.create` signature using AST
- Support optional LocordaConfig generator
- Provide configuration options for customization
