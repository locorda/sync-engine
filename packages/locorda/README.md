# locorda

[![pub package](https://img.shields.io/pub/v/locorda.svg)](https://pub.dev/packages/locorda)
[![license](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/locorda/sync-engine/blob/main/LICENSE)

**Sync offline-first Flutter apps using your user's own storage — no backend required.**

`locorda` is the main entry point for building apps with [Locorda](https://locorda.dev/sync-engine/).
It re-exports everything you need: the sync engine, annotations, storage handlers, UI widgets, and worker infrastructure — all from a single package.

> **Early Access (v0.5.0)** — Core API is stable. Backend implementation details may have breaking changes before 1.0.
> Google Drive is fully supported. Solid Pod support works but has higher latency due to a protocol-level limitation (no batch-write operation in Solid Protocol today).

## How it works

Annotate your domain classes, run code generation, wire up a backend — that's it.
Locorda handles CRDT conflict resolution, sync state, and worker isolation automatically.

```
UI ↔ Your Repository ↔ Locorda SyncEngine ↔ Worker Thread ↔ Remote Storage
                           (hydration callbacks)         (Google Drive / Solid Pod / ...)
```

Your app owns its local storage and queries. Locorda only participates on `save`, `deleteDocument`, and hydration callbacks.

## Quick start

### 1. Add dependencies

```sh
flutter pub add locorda locorda_gdrive  # or locorda_solid, locorda_dir
flutter pub add dev:build_runner dev:locorda_dev
```

### 2. Annotate your model

```dart
import 'package:locorda/annotations.dart';

@RootResource(AppVocab(appBaseUri: 'https://myapp.example.com'))
class Task {
  @RdfIriPart()
  final String id;

  @CrdtLwwRegister()   // last writer wins on conflict
  final String title;

  @CrdtLwwRegister()
  final bool completed;

  @CrdtImmutable()     // set once at creation, never changed
  final DateTime createdAt;

  Task({required this.id, required this.title, this.completed = false, DateTime? createdAt})
      : createdAt = createdAt ?? DateTime.now();
}
```

### 3. Run code generation

```bash
dart run build_runner build
```

This generates the RDF mapper, CRDT merge contracts, worker setup, and the `initLocorda()` convenience function.

### 4. Initialize Locorda

```dart
import 'package:locorda/locorda.dart';
import 'package:locorda_gdrive/locorda_gdrive.dart';
import 'init_locorda.g.dart';  // generated

final locorda = await initLocorda(
  storage: DriftMainHandler(),
  remotes: [await GDriveMainIntegration.create()],
);
```

> **GDrive**: platform-specific OAuth2 credentials must be configured before sign-in works.
> See [locorda_gdrive — OAuth2 Setup](https://pub.dev/packages/locorda_gdrive) for instructions.

### 5. Connect your repository

```dart
await locorda.syncEngine.hydrateWithCallbacks<Task>(
  getCurrentCursor: () => db.getSyncCursor(),
  onUpdate: (task) => db.upsert(task),
  onDelete: (id) => db.delete(id),
  onCursorUpdate: (cursor) => db.saveCursor(cursor),
);
```

### 6. Save and delete through Locorda

```dart
await locorda.syncEngine.save<Task>(task);
await locorda.syncEngine.deleteDocument<Task>(taskId);
```

All updates — whether from the local device or from sync — flow through the hydration callbacks. This keeps your UI consistent without double-writing.

## Storage layouts

| Layout | Best for |
|--------|----------|
| **File-per-resource** | Solid Pods, linked-data interoperability — each resource is its own file |
| **Packed (sharded)** | Large collections — parallel uploads, smaller per-file payloads |
| **Packed (single-file)** | Google Drive, small datasets — fewest requests (default for GDrive) |

Layout is configured per backend, inside the backend config passed to the integration:

```dart
// Solid — default: FilePerResource (one Turtle file per resource)
await SolidMainIntegration.create(
  oidcClientId: '...',
  appUrlScheme: '...',
  frontendRedirectUrl: Uri.parse('...'),
  config: SolidConfig(layout: FilePerResource()),  // default
);

// Google Drive — default: SingleFile (fewest requests)
await GDriveMainIntegration.create(
  config: GDriveConfig(layout: SingleFile()),  // default
);

// Google Drive — sharded dataset (parallel uploads)
await GDriveMainIntegration.create(
  config: GDriveConfig(layout: ShardDataset()),
);
```

The serialization format (Turtle, TriG, JSON-LD, Jelly) is configured independently via the `contentType` parameter on each layout class.

## Example apps

### Minimal task sync app ← start here

The simplest possible Locorda app: a task list that syncs across devices.
Shows all core patterns in under 150 lines: annotations, hydration callbacks, save/delete, and the built-in status widget.

→ [`example/minimal/`](example/minimal/) — [README](example/minimal/README.md)

### Personal notes app

A full production-grade Flutter app with:
- **Drift** for persistent local storage
- **Google Drive** and **Solid Pod** backends
- **GroupIndex** for paginated sync by month
- Production repository patterns with cursor tracking and error handling

→ [`example/personal_notes_app/`](example/personal_notes_app/) — [README](example/personal_notes_app/README.md) 
— [**Live demo**](https://locorda.dev/example/personal_notes_app/)

## What's included

`import 'package:locorda/locorda.dart'` gives you:

- `Locorda` — top-level façade (`syncEngine`, `syncManager`, `uiAdapterRegistry`)
- `ObjectSyncEngine` — typed `save<T>()`, `deleteDocument<T>()`, `hydrateWithCallbacks<T>()`
- `LocordaConfig`, `ResourceConfig`, `FullIndexConfig`, `GroupIndexConfig` — sync configuration
- `DriftMainHandler`, `LocordaDriftOptions` — SQLite storage for the main thread
- `InMemoryStorageMainHandler` — in-memory storage (useful for demos and testing)
- `MultiBackendStatusWidget`, `SyncRefreshIndicator`, `UiAdapterRegistry` — ready-made sync UI widgets
- `RemoteStorageLayout`, `FilePerResource`, `ShardDataset`, `SingleFile` — layout configuration
- `SyncManager`, `StandardSyncManager` — manual sync control

`import 'package:locorda/annotations.dart'` gives you:

- `@RootResource`, `@SubResource`, `@RootResourceRef` — class-level sync annotations
- `@CrdtLwwRegister`, `@CrdtImmutable`, `@CrdtOrSet` — field-level CRDT strategies
- `@RdfIriPart`, `@RdfProperty`, `@RdfUnmappedTriples` — RDF mapping annotations

`import 'package:locorda/worker.dart'` (worker thread only):

- `workerMain`, `WorkerParams` — worker entry point
- `DriftWorkerHandler` — Drift storage for the worker thread
- `RemoteWorkerHandler`, `StorageWorkerHandler` — worker handler interfaces

## Architecture

Locorda uses a **4-layer architecture**:

1. **Data Resource Layer** — clean RDF resources with standard vocabularies
2. **Merge Contract Layer** — per-field CRDT rules for conflict resolution
3. **Indexing Layer** — efficient change detection via sharded indices
4. **Sync Strategy Layer** — layout and fetch policy configuration

Heavy work (CRDT merging, HTTP, database I/O) runs in a background worker isolate (native) or web worker (web), keeping the UI thread responsive.

## Known limitations (Early Access)

- Solid backend: each sync cycle requires many HTTP requests — Solid Protocol currently has no batch-write operation. This is a protocol-level constraint, not something fixable on our side.
- `ensure` and `delete` operations not yet implemented
- Delta layout not yet available — the full packed file is uploaded/downloaded each cycle
- Limited CRDT types (LWW register, immutable, OR-Set; more planned)

## Further reading

- [Website & feature overview](https://locorda.dev/sync-engine/)
- [Architecture overview](https://locorda.dev/sync-engine/#architecture)
- [Package structure](../../IMPLEMENTATION.md)

