# locorda_init_generator

Code generator for Locorda convenience wrapper (`initLocorda`).

## Purpose

Generates `lib/init_locorda.g.dart` which provides a simplified initialization function that:
- Auto-detects and configures `workerSetup` when `worker_generated.g.dart` exists
- Auto-generates `mapperInitializer` when `init_rdf_mapper.g.dart` exists
- Propagates all other `Locorda.create` parameters
- Propagates custom parameters from `initRdfMapper` (excluding framework params)

## Installation

This package is automatically applied when you depend on `locorda_dev`:

```yaml
dev_dependencies:
  locorda_dev: any
  build_runner: ^2.4.0
```

## Usage

After running `dart run build_runner build`, use the generated function:

```dart
import 'package:your_app/init_locorda.g.dart';

final locorda = await initLocorda(
  config: myConfig,
  storage: myStorage,
  remotes: myRemotes,
);
```

The generator automatically handles:
- Setting `workerSetup: generatedWorkerSetup` if `worker_generated.g.dart` exists
- Setting `jsScript: 'worker_generated.dart.js'` appropriately
- Generating `mapperInitializer` lambda if `init_rdf_mapper.g.dart` exists

## Requirements

- Requires `analyzer >=8.1.0 <11.0.0` for code analysis
- Compatible with Flutter stable and latest versions

## Architecture

This is a separate package (not part of `locorda_builder`) because:
- Heavy analyzer dependency (~20MB)
- Advanced code analysis features
- Should not burden apps that don't use this feature
