# locorda_flutter

Flutter integration layer for locorda — combines `ObjectSyncEngine` with worker
architecture and UI components to give Flutter apps a single `Locorda` entry point.

> For most Flutter applications, use the [`locorda`](../locorda) facade package
> instead. It re-exports everything from `locorda_flutter` plus backend-specific
> packages (Drift, Worker, UI widgets), so you rarely need to depend on
> `locorda_flutter` directly.

## Features

- ✅ **`Locorda` facade**: one-call setup for the complete sync system
- ✅ **Worker architecture**: heavy operations (CRDT merge, I/O) run in a Dart Isolate / Web Worker
- ✅ **Multi-backend UI**: `MultiBackendStatusWidget` and `SyncRefreshIndicator` work with any backend
- ✅ **Platform**: Flutter (iOS · Android · Web · Desktop)

## Installation

```sh
flutter pub add locorda_flutter
```

## Key types

| Type | Description |
|------|-------------|
| `Locorda` | Top-level facade — wraps `ObjectSyncEngine` + UI registry |
| `Locorda.create()` | Factory: spawns worker, wires backend handlers, returns ready instance |
| `syncManager` | Manual sync trigger, status stream, auto-sync control |
| `uiAdapterRegistry` | Query active backends for `MultiBackendStatusWidget` |

## Usage

```dart
import 'package:locorda_flutter/locorda_flutter.dart';

// Main thread (main.dart)
final locorda = await Locorda.create(
  workerSetup: setupWorkerEngine, // defined in worker.dart
  config: LocordaConfig(
    resources: [/* ResourceConfig per type */],
  ),
  remotes: [gdriveHandler], // one or more backend integrations
);

// Access the typed sync engine
await locorda.syncEngine.save(myNote);

// Monitor sync status
locorda.syncManager.statusStream.listen(print);
```

See the [Personal Notes App](../locorda/example/personal_notes_app) for a complete
production example including Solid and Google Drive backends.

## Further reading

- [locorda package](../locorda) — recommended top-level entry point
- [locorda_objects](../locorda_objects) — type-safe API layer
- [locorda_flutter_core](../locorda_flutter_core) — shared Flutter base types
