# locorda_gdrive Examples

This package provides Google Drive backend integration for [locorda](https://pub.dev/packages/locorda).

## Recommended: Code Generation with `locorda_dev`

The easiest way to integrate Google Drive is via the `locorda_dev` code generator,
which generates all worker boilerplate automatically.

### 1. Add dependencies

```yaml
# pubspec.yaml
dependencies:
  locorda: ^<version>
  locorda_gdrive: ^<version>
  # ... other locorda packages

dev_dependencies:
  build_runner: ^<version>
  locorda_dev: ^<version>
```

### 2. Run the code generator

```sh
dart run build_runner build
```

This generates:
- `init_locorda.g.dart` — `initLocorda()` convenience wrapper with auto-configured worker setup, mapper, and config
- `worker_generated.g.dart` — `generatedWorkerSetup()` worker entry point that assembles all package adapters

### 3. Use in `main.dart`

```dart
import 'package:locorda_gdrive/locorda_gdrive.dart';
import 'package:locorda_drift/locorda_drift.dart'; // example storage backend
import 'init_locorda.g.dart'; // generated

void main() async {
  final locorda = await initLocorda(
    storage: DriftMainHandler(),
    remotes: [
      // App Data Folder (private, recommended)
      await GDriveMainIntegration.create(
        // Required ONLY when targeting Windows/Linux (otherwise completely optional):
        clientId: const String.fromEnvironment('GDRIVE_CLIENT_ID').isNotEmpty
            ? const String.fromEnvironment('GDRIVE_CLIENT_ID')
            : null,
        clientKey: const String.fromEnvironment('GDRIVE_CLIENT_KEY').isNotEmpty
            ? const String.fromEnvironment('GDRIVE_CLIENT_KEY')
            : null,
      ),

      // Or: visible folder in user's My Drive
      // await GDriveMainIntegration.create(
      //   config: GDriveConfig.visibleFolder(appFolderName: 'MyApp'),
      // ),
    ],
  );
  // use locorda ...
}
```

No worker setup code is needed — the generator handles it.

---

## Manual Setup (without code generation)

Use this approach when you need full control over worker configuration or are not
using `locorda_dev`.

### Main thread (`lib/main.dart`)

```dart
import 'package:locorda/locorda.dart';
import 'package:locorda_gdrive/locorda_gdrive.dart';

final locorda = await Locorda.create(
  workerSetup: setupWorkerEngine, // your worker setup function
  storage: DriftMainHandler(),
  remotes: [await GDriveMainIntegration.create()],
  config: generateLocordaConfig(),      // from your locorda_config.g.dart
  mapperInitializer: initRdfMapper,     // from your init_rdf_mapper.g.dart
);
```

### Worker thread (`lib/worker.dart`)

```dart
import 'package:locorda_worker/worker.dart';
import 'package:locorda_gdrive/worker.dart';
import 'package:locorda_drift/worker.dart'; // example storage backend

Future<WorkerParams> setupWorkerEngine() async => WorkerParams(
  storages: [DriftWorkerHandler()], // required
  remotes: [
    GDriveWorkerHandler(), // receives GDriveConfig automatically from main thread
  ],
);
```

---

For a complete working example, see the
[Personal Notes App](https://github.com/locorda/sync-engine/tree/main/packages/locorda/example/personal_notes_app).

For storage modes (App Data Folder vs. visible folder), layouts, and OAuth2 setup,
see the [package README](../README.md).
