# Locorda: Sync offline-first apps using your user's own storage

**Locorda** is a Dart/Flutter library for building **offline-first** apps that sync via the user's own backend — Google Drive, Solid Pod, or any file storage — without a central server. This **BYOB (Bring Your Own Backend)** approach, bringing the [unhosted](https://unhosted.org) philosophy to Flutter, means your users' data lives in their own storage — not on your servers.

> **Early Access — [![pub](https://img.shields.io/pub/v/locorda.svg)](https://pub.dev/packages/locorda)**
>
> Core API is stable; backend implementation details may have breaking changes before 1.0.
>
> - ✅ Google Drive — all features working; implementation improvements planned
> - ✅ Solid Pod — works; sync performance improvements (request parallelisation) planned
> - ✅ File-per-resource and packed layouts (sharded + single-file)
> - ✅ Offline-first with CRDT conflict resolution

## How it works

```
UI ↔ Your Repository ↔ Locorda SyncEngine ↔ Worker Isolate/WebWorker ↔ Remote Storage
                           (hydration callbacks)                      (Google Drive / Solid Pod / ...)
```

Annotate your domain classes with CRDT merge strategies, run code generation, wire up a backend — Locorda handles conflict resolution, sync state, and worker isolation automatically. Your app keeps full control of local storage and queries.

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

  // last writer wins is the default
  // conflict resolution strategy - it could be 
  // specified explicitly with @CrdtLwwRegister() 
  // annotation but we skip that here for simplicity.
  final String title;

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

### 4. Initialize

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

### 6. Save and delete

```dart
await locorda.syncEngine.save<Task>(task);
await locorda.syncEngine.deleteDocument<Task>(taskId);
```

All updates — local saves and incoming sync — flow through the hydration callbacks, keeping your UI consistent without double-writing.

For a complete runnable example see [packages/locorda/example/minimal/](packages/locorda/example/minimal/) and the full [packages/locorda/README.md](packages/locorda/README.md).

## Packages

### Entry-point packages

These are the packages you add to your `pubspec.yaml`:

| Package | pub.dev | Description |
|---------|---------|-------------|
| [`locorda`](packages/locorda/) | [![pub](https://img.shields.io/pub/v/locorda.svg)](https://pub.dev/packages/locorda) | Main Flutter entry point — re-exports the sync engine, UI widgets, storage, worker infrastructure, and annotations |
| [`locorda_gdrive`](packages/locorda_gdrive/) | [![pub](https://img.shields.io/pub/v/locorda_gdrive.svg)](https://pub.dev/packages/locorda_gdrive) | Google Drive backend |
| [`locorda_solid`](packages/locorda_solid/) | [![pub](https://img.shields.io/pub/v/locorda_solid.svg)](https://pub.dev/packages/locorda_solid) | Solid Pod backend + OIDC/DPoP authentication |
| [`locorda_dir`](packages/locorda_dir/) | [![pub](https://img.shields.io/pub/v/locorda_dir.svg)](https://pub.dev/packages/locorda_dir) | Local directory backend — useful for development and testing |
| [`locorda_dev`](packages/locorda_dev/) | [![pub](https://img.shields.io/pub/v/locorda_dev.svg)](https://pub.dev/packages/locorda_dev) | **Dev dependency**: aggregates all Locorda code generators — eliminates boilerplate by generating RDF mappers, CRDT merge contracts, worker setup, and the `initLocorda()` initializer |

### Implementation packages

The remaining packages (`locorda_core`, `locorda_flutter`, `locorda_drift`, `locorda_worker`, `locorda_annotations`, and others) are internal building blocks. Most applications never depend on them directly — they are pulled in transitively through the entry-point packages above.

See [PACKAGES.md](PACKAGES.md) for the full package list with descriptions.

## Architecture

Locorda uses a 4-layer architecture:

1. **Data Resource Layer** — clean RDF resources with standard vocabularies (`schema:`, `foaf:`, etc.)
2. **Merge Contract Layer** — per-field CRDT rules (`LWW-Register`, `OR-Set`, `Immutable`, …)
3. **Indexing Layer** — efficient change detection via sharded indices
4. **Sync Strategy Layer** — layout and fetch policy configuration per backend

Heavy work (CRDT merging, HTTP, database I/O) runs in a background isolate (native) or Web Worker (web), keeping the UI thread responsive.

## Standards alignment

- [Solid Protocol](https://solidproject.org/) (as one supported backend)
- [RDF](https://www.w3.org/RDF/) and Linked Data principles — all data stored as standard RDF

## Contributing

- Issues & discussions: [GitHub Issues](https://github.com/locorda/sync-engine/issues) / [GitHub Discussions](https://github.com/locorda/sync-engine/discussions)
- Development guide: [CLAUDE.md](CLAUDE.md)

## AI Policy

This project is proudly human-led and human-controlled, with all key decisions, design, and code reviews made by people. At the same time, it stands on the shoulders of LLM giants: generative AI tools are used throughout the development process to accelerate iteration, inspire new ideas, and improve documentation quality. We believe that combining human expertise with the best of AI leads to higher-quality, more innovative open source software.

## License

MIT — see [LICENSE](LICENSE).