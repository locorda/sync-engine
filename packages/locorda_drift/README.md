# locorda_drift

[![pub package](https://img.shields.io/pub/v/locorda_drift.svg)](https://pub.dev/packages/locorda_drift)
[![license](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/locorda/sync-engine/blob/main/LICENSE)

Drift (SQLite) storage implementation for locorda_core.

## Overview

This package provides a concrete implementation of the `Storage` interface from `locorda_core` using Drift ORM for cross-platform SQLite storage.

## Features

- **Cross-platform SQLite storage** - Works on iOS, Android, Web, Windows, macOS, Linux
- **Document + Triple storage** - Stores RDF as both complete documents and queryable triples
- **CRDT metadata support** - Dedicated tables for Hybrid Logical Clocks and tombstones  
- **Index optimization** - Efficient storage for sync performance indices
- **Type-safe queries** - Generated Drift APIs for compile-time safety

## Database Schema

The schema is defined as Drift table classes in [`lib/src/sync_database.dart`](lib/src/sync_database.dart). Drift generates the corresponding SQL DDL at build time.

## Usage

### Main thread

```dart
import 'package:locorda/locorda.dart';

final locorda = await initLocorda(
  storage: DriftMainHandler(
    options: LocordaDriftNativeOptions(
      databaseName: 'my_app_sync',
    ),
  ),
  remotes: [...],
  config: myLocordaConfig,
);
```

### Worker thread

```dart
import 'package:locorda/worker.dart';

Future<WorkerParams> createEngineParams(
  SyncEngineConfig config,
  WorkerContext context,
) async {
  return WorkerParams(
    storage: DriftWorkerHandler(
      options: LocordaDriftNativeOptions(databaseName: 'my_app_sync'),
    ),
    backends: [...],
  );
}
```

See the [minimal example](https://github.com/locorda/sync-engine/tree/main/packages/locorda/example/minimal) for a complete working setup.