# Locorda — Package Reference

This document lists all packages in the monorepo. Most applications only need the [entry-point packages](#entry-point-packages); the rest are internal building blocks pulled in transitively.

## Entry-point packages

| Package | pub.dev | Description |
|---------|---------|-------------|
| [`locorda`](packages/locorda/) | [![pub](https://img.shields.io/pub/v/locorda.svg)](https://pub.dev/packages/locorda) | Main Flutter entry point — re-exports the sync engine, UI widgets, storage, worker infrastructure, and annotations from a single package |
| [`locorda_gdrive`](packages/locorda_gdrive/) | [![pub](https://img.shields.io/pub/v/locorda_gdrive.svg)](https://pub.dev/packages/locorda_gdrive) | Google Drive backend + OAuth2 authentication |
| [`locorda_solid`](packages/locorda_solid/) | [![pub](https://img.shields.io/pub/v/locorda_solid.svg)](https://pub.dev/packages/locorda_solid) | Solid Pod backend + OIDC/DPoP authentication; includes login UI |
| [`locorda_dir`](packages/locorda_dir/) | [![pub](https://img.shields.io/pub/v/locorda_dir.svg)](https://pub.dev/packages/locorda_dir) | Local directory backend — sync to a folder on disk; useful for development and testing |
| [`locorda_dev`](packages/locorda_dev/) | [![pub](https://img.shields.io/pub/v/locorda_dev.svg)](https://pub.dev/packages/locorda_dev) | **Dev dependency**: aggregates all Locorda code generators (`locorda_builder`, `locorda_init_generator`, `locorda_mapping_bootstrap_generator`) — eliminates boilerplate by generating RDF mappers, CRDT merge contracts, worker setup, and the `initLocorda()` initializer |

## Implementation packages

These packages are building blocks used internally. Direct dependencies are only needed for advanced use cases (custom backends, non-Flutter apps, custom tooling, direct usage of RdfGraph instead of dart domain classes).

### Core runtime

| Package | pub.dev | Description |
|---------|---------|-------------|
| [`locorda_core`](packages/locorda_core/) | [![pub](https://img.shields.io/pub/v/locorda_core.svg)](https://pub.dev/packages/locorda_core) | Platform-agnostic CRDT sync engine built around a streaming multi-stage pipeline with flexible backend storage layouts — pure Dart, no Flutter dependency |
| [`locorda_objects`](packages/locorda_objects/) | [![pub](https://img.shields.io/pub/v/locorda_objects.svg)](https://pub.dev/packages/locorda_objects) | Type-safe object-oriented API over the raw `SyncEngine` (`ObjectSyncEngine`). Useful for non-Flutter (server/CLI) contexts |
| [`locorda_annotations`](packages/locorda_annotations/) | [![pub](https://img.shields.io/pub/v/locorda_annotations.svg)](https://pub.dev/packages/locorda_annotations) | CRDT merge strategy and RDF resource annotations (`@RootResource`, `@CrdtLwwRegister`, etc.) consumed by code generators |
| [`locorda_drift`](packages/locorda_drift/) | [![pub](https://img.shields.io/pub/v/locorda_drift.svg)](https://pub.dev/packages/locorda_drift) | Drift (SQLite) storage backend for `locorda_core` |

### Flutter & worker layer

| Package | pub.dev | Description |
|---------|---------|-------------|
| [`locorda_flutter`](packages/locorda_flutter/) | [![pub](https://img.shields.io/pub/v/locorda_flutter.svg)](https://pub.dev/packages/locorda_flutter) | Flutter integration layer — combines `ObjectSyncEngine` with worker architecture and UI components (`MultiBackendStatusWidget`, `SyncRefreshIndicator`) |
| [`locorda_flutter_core`](packages/locorda_flutter_core/) | [![pub](https://img.shields.io/pub/v/locorda_flutter_core.svg)](https://pub.dev/packages/locorda_flutter_core) | Shared Flutter base types used by `locorda_flutter` and backend packages; defines `RemoteIntegration` contract |
| [`locorda_worker`](packages/locorda_worker/) | [![pub](https://img.shields.io/pub/v/locorda_worker.svg)](https://pub.dev/packages/locorda_worker) | Worker infrastructure — platform-agnostic architecture for running CRDT merging, database I/O, and HTTP in a separate isolate (native) or Web Worker (web) |

### Solid backend internals

| Package | pub.dev | Description |
|---------|---------|-------------|
| [`locorda_solid_core`](packages/locorda_solid_core/) | [![pub](https://img.shields.io/pub/v/locorda_solid_core.svg)](https://pub.dev/packages/locorda_solid_core) | Solid Pod backend implementation shared between `locorda_solid` and potential custom integrations |
| [`locorda_solid_auth`](packages/locorda_solid_auth/) | [![pub](https://img.shields.io/pub/v/locorda_solid_auth.svg)](https://pub.dev/packages/locorda_solid_auth) | Solid OIDC / DPoP authentication; used internally by `locorda_solid`. Add directly only when integrating Solid auth into a custom flow |

### Build-time generators

| Package | Description |
|---------|-------------|
| [`locorda_builder`](packages/locorda_builder/) | Build-time transforms — web worker compilation (`WorkerGeneratorBuilder`, `WebWorkerBuilder`) and RDF mapper generation |
| [`locorda_init_generator`](packages/locorda_init_generator/) | Generates the `initLocorda()` convenience wrapper (`init_locorda.g.dart`) |
| [`locorda_mapping_bootstrap_generator`](packages/locorda_mapping_bootstrap_generator/) | Embeds CRDT mapping documents (merge contracts) into the app bundle at compile time |

All three generators are bundled in [`locorda_dev`](packages/locorda_dev/) — add that single dev dependency instead of depending on them individually.
