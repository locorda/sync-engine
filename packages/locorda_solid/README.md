# locorda_solid

[![pub package](https://img.shields.io/pub/v/locorda_solid.svg)](https://pub.dev/packages/locorda_solid)
[![license](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/locorda/sync-engine/blob/main/LICENSE)

Solid Pod backend and authentication for locorda CRDT synchronization.

## Features

- ✅ **Solid Pod Backend**: Store RDF resources in any Solid-compliant Pod
- ✅ **OIDC Authentication**: DPoP-secured access via `solid_oidc_auth`
- ✅ **Login UI**: Provider selection and login screens out of the box
- ✅ **Worker Support**: Network I/O and DPoP signing run in isolate/web worker
- ✅ **File-Per-Resource Layout**: Each RDF resource maps to a Solid document — fully linked-data interoperable
- ⚠️ **Platform**: Flutter only (requires `flutter: '>=3.24.0'`)

### Known limitation

Solid's HTTP protocol has no batch-write primitive. Every save requires an individual `PUT`/`PATCH` request.
For high-throughput use cases, prefer [locorda_gdrive](../locorda_gdrive) with the `SingleFile` or `ShardDataset` layout.
Technically, you can use both `SingleFile` and `ShardDataset` with Solid Pods as well, but you will not take part in Solids 
linked data concept then and the RDF Dataset TriG files stored will be a BLOB as far as Solid is concerned.

## Installation

```sh
flutter pub add locorda locorda_solid
flutter pub add dev:build_runner dev:locorda_dev
```

## Usage

### 1. Run code generation

```bash
dart run build_runner build
```

`locorda_dev` discovers `locorda_solid` via its worker manifest and automatically includes
`SolidWorkerHandler` in the generated `worker_generated.g.dart` — no manual worker code needed.

### 2. Initialize on the main thread

```dart
import 'package:locorda/locorda.dart';
import 'package:locorda_solid/locorda_solid.dart';
import 'init_locorda.g.dart';  // generated

final locorda = await initLocorda(
  storage: DriftMainHandler(),
  remotes: [
    await SolidMainIntegration.create(
      oidcClientId: 'https://your-app.example/auth/client-config.json',
      appUrlScheme: 'com.example.yourapp',
      frontendRedirectUrl: Uri.parse('https://your-app.example/redirect.html'),
    ),
  ],
);
```

`SolidConfig()` is optional — pass it to customise storage layout or paths.

### 3. Add the status widget

```dart
AppBar(
  actions: [
    MultiBackendStatusWidget(
      registry: locorda.uiAdapterRegistry,
      syncManager: locorda.syncManager,
    ),
  ],
)

## Further reading

- [locorda package](../locorda) — high-level API and getting started guide
- [locorda_gdrive](../locorda_gdrive) — alternative backend with better write throughput
