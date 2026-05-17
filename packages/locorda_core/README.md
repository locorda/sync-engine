# locorda_core

[![pub package](https://img.shields.io/pub/v/locorda_core.svg)](https://pub.dev/packages/locorda_core)
[![license](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/locorda/sync-engine/blob/main/LICENSE)

Platform-agnostic CRDT sync engine — the runtime that drives offline-first conflict resolution, sharded index management, and sync state across BYOB backends (Google Drive, Solid Pods, local directory, and more).

> This is an internal implementation package. Most applications should depend on [`locorda`](../locorda) or [`locorda_flutter`](../locorda_flutter), which re-export the public surface of this package. Add `locorda_core` directly only when building a custom integration (e.g. a new storage backend) without Flutter.

## What it contains

| Area | Key types |
|------|-----------|
| Sync engine | `SyncEngine`, `EngineParams` |
| CRDT merge | Property-level merge algorithms (LWW, OR-Set, Immutable, G-Register) |
| Hybrid Logical Clocks | Causality-aware timestamps combining logical and physical time |
| Index management | Full and Group index sync — sharded, with O(1) change detection |
| Vocabularies | Generated Dart constants for `algo:`, `crdt:`, `idx:`, `sync:` vocabularies |
| Layout types | `FilePerResource`, `ShardDataset`, `SingleFile`, `RemoteStorageLayout` |

## Dependency

```sh
dart pub add locorda_core
```

Only needed for **custom backend integrations**. For typical app development:

```sh
flutter pub add locorda          # Flutter app
dart pub add locorda             # Pure-Dart app
```

## Further reading

- [locorda](../locorda) — recommended entry point
- [Architecture overview](https://pub.dev/packages/locorda)
