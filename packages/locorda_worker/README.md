# locorda_worker

[![pub package](https://img.shields.io/pub/v/locorda_worker.svg)](https://pub.dev/packages/locorda_worker)
[![license](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/locorda/sync-engine/blob/main/LICENSE)

Worker infrastructure for Locorda — platform-agnostic architecture for running heavy operations in a separate Dart Isolate or Web Worker thread.

## Overview

This package provides the core worker infrastructure used by Locorda to offload CPU and I/O-intensive operations (CRDT merging, database access, HTTP requests) to a separate thread, keeping the main thread responsive for UI.

**Key Features:**
- **Platform-agnostic**: Dart Isolates on native, Web Workers on web — same API both ways
- **Type-safe messaging**: Structured request/response protocol with request correlation
- **Plugin system**: Extensible via `WorkerChannel` for cross-thread concerns such as authentication bridges (e.g. Google Drive token refresh, Solid DPoP signing)
- **Worker manifest system**: packages expose `locorda_worker.manifest.dart`; `locorda_builder` assembles them automatically

## Architecture

### Main Thread
- Lightweight `ProxySyncEngine` — serialises calls to jelly-encoded messages and routes responses by correlation ID
- `SyncManager` proxy — sync triggering, auto-sync scheduling and status stream forwarded from the worker
- Plugin bridges (e.g. `GDriveAuthBridge`, `SolidAuthBridge`) push credential updates into the worker via `WorkerChannel`

### Worker Thread
- Full `SyncEngine` instance
- **CRDT merge logic** — all conflict resolution runs here
- **Database (Drift/SQLite)** — all storage I/O
- **HTTP backends** (Google Drive, Solid Pod, …) — all network requests
- **Auth token handling** — Google OAuth2 token refresh, Solid DPoP proof generation, and other credential operations stay off the main thread

### Communication
- **Framework messages**: save/delete documents, hydration streams, sync triggers
- **Worker channel**: app-specific bidirectional pub/sub (e.g. auth credential updates)

## Usage

### Recommended: generated worker (zero boilerplate)

When `locorda_dev` is added as a dev dependency, `build_runner` generates
`lib/worker_generated.g.dart` by discovering every `locorda_worker.manifest.dart`
in the dependency graph. The companion `lib/init_locorda.g.dart` wires it up
automatically:

```dart
// lib/worker_generated.g.dart  — GENERATED, do not edit
void main() {
  workerMain(generatedWorkerSetup, onWorkerSpawn: setupWorkerLogging);
}

Future<WorkerParams> generatedWorkerSetup() async => WorkerParams(
  storages: [...locorda_drift.storages, ...locorda_solid.storages, ...],
  remotes:  [...locorda_drift.remotes,  ...locorda_solid.remotes,  ...],
  mappingBootstrapSources: bootstrapMappings,
);
```

```dart
// lib/init_locorda.g.dart  — GENERATED, do not edit
Future<Locorda> initLocorda({
  required StorageMainHandler storage,
  List<RemoteIntegration> remotes = const [],
  ...
}) => Locorda.create(
  workerSetup: generatedWorkerSetup,   // ← generated worker
  jsScript: 'worker_generated.dart.js',
  ...
);
```

Your app calls `initLocorda(storage: myDriftHandler, remotes: [solidPlugin])` and is done.

### Advanced: manual worker

If you need fine-grained control, write a top-level factory function yourself.
The function **must be top-level** — this is required for cross-isolate function
passing on native platforms.

```dart
// lib/worker.dart
import 'package:locorda_worker/worker.dart';

void main() => workerMain(setupWorkerEngine);

Future<WorkerParams> setupWorkerEngine() async => WorkerParams(
  storages: [DriftWorkerHandler()],
  remotes:  [SolidWorkerHandler()],
  mappingBootstrapSources: bootstrapMappings,
);
```

For web, the generated or manual worker is compiled to JS automatically by
`locorda_builder` when `locorda_dev` is present. To compile manually:

```bash
dart compile js lib/worker.dart -o web/worker.dart.js
```

## See Also

- [`locorda`](../locorda) — high-level API (recommended entry point)
- [`locorda_dev`](../locorda_dev) — single dev dependency that activates all builders
- [`locorda_builder`](../locorda_builder) — worker generator and web compiler
- [`locorda_solid_auth_worker`](../locorda_solid_auth_worker) — Solid authentication bridge plugin
- [`locorda_core`](../locorda_core) — core sync engine (runs inside the worker)
