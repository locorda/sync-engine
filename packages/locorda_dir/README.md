# locorda_dir

Local directory backend for Locorda - sync your data to a local folder on disk.

## Overview

`locorda_dir` provides a file-based remote storage backend that syncs your Locorda data to a local directory. This is primarily designed for **desktop platforms** (macOS, Windows, Linux) where users have direct access to the file system.

## Features

- 🗂️ **File-Based Storage**: Sync data as Turtle (.ttl) files in a local directory
- 💻 **Desktop-Focused**: Optimized for platforms with direct file system access
- 🔍 **Direct Access**: View and backup your synced data directly from the file system
- 📦 **Type-Based Organization**: Files organized in subdirectories by resource type
- ⚡ **ETag Support**: Efficient sync using file modification times
- 🎛️ **Simple Auth**: Toggle sync on/off with a simple boolean switch

## Platform Support

| Platform | Support | Default Path |
|----------|---------|--------------|
| macOS    | ✅ Full | `~/Documents/<appName>/locorda-sync/` |
| Linux    | ✅ Full | `~/Documents/<appName>/locorda-sync/` |
| Windows  | ✅ Full | `%USERPROFILE%\Documents\<appName>\locorda-sync\` |
| iOS      | ⚠️ Limited | App sandbox (not user-accessible) |
| Android  | ⚠️ Limited | App sandbox (not user-accessible) |
| Web      | ❌ Not supported | N/A |

## Usage

### Main Thread Setup

```dart
import 'package:locorda_dir/locorda_dir.dart';

// Create the integration
final dirIntegration = await DirMainIntegration.create(
  appName: 'my-app', // Used for directory naming
  initiallyEnabled: false, // Sync disabled by default
);

// Use in your RemoteIntegrationRegistry
final registry = RemoteIntegrationRegistry([
  dirIntegration,
  // ... other backends
]);
```

### Worker Thread Setup

```dart
import 'package:locorda_dir/worker.dart' as worker;

// Register the worker handler
final workerHandlers = [
  worker.DirWorkerHandler(appName: 'my-app'),
  // ... other worker handlers
];
```

### Directory Structure

Files are organized by resource type:

```
~/Documents/my-app/locorda-sync/
├── Note/
│   ├── abc123.ttl
│   └── def456.ttl
├── Category/
│   └── xyz789.ttl
└── idx/
    └── note-index.ttl
```

## How It Works

1. **Authentication**: Simple boolean toggle - sync is either enabled or disabled
2. **File Format**: All data stored as RDF Turtle files
3. **ETag Generation**: Based on file modification time + size for efficient sync
4. **Conflict Resolution**: Uses Locorda's CRDT merge logic (same as cloud backends)

## UI Components

### Login Screen

Shows users:
- How the feature works
- The sync directory path
- Toggle to enable/disable sync
- Button to open directory in Finder/Explorer

```dart
// Automatically shown via RemoteIntegration.showLogin()
await dirIntegration.showLogin(context);
```

## Comparison with Cloud Backends

| Feature | Local Dir | Solid Pod | Google Drive |
|---------|-----------|-----------|--------------|
| Offline Access | ✅ Always | ⚠️ Cache | ⚠️ Cache |
| Multi-Device Sync | ❌ Manual | ✅ Automatic | ✅ Automatic |
| File Access | ✅ Direct | ⚠️ Via API | ⚠️ Via API |
| Backup | Manual copy | Pod provider | Google |
| Privacy | ✅ Fully local | ✅ Self-hosted | ⚠️ Google |

## Use Cases

- **Development & Testing**: Quick local storage without cloud setup
- **Local Backups**: Keep a local copy alongside cloud sync
- **Offline-First**: True offline operation without network dependency
- **File System Integration**: Use standard backup tools (Time Machine, rsync, etc.)
- **Data Inspection**: Easily inspect RDF data in text editor

## Limitations

- **No Multi-Device Sync**: Files are local to one machine
- **Manual Backup Required**: No automatic cloud backup
- **Desktop Only**: Mobile support is limited to app sandbox
- **No Collaboration**: Single user only

## Development

Run tests:
```bash
cd packages/locorda_dir
flutter test
```

Format code:
```bash
dart format .
```

Analyze:
```bash
dart analyze
```
