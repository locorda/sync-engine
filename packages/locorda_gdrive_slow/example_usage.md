# GDrive Configuration Examples

This document shows how to configure the Google Drive backend with different storage modes.

## Quick Start

### Main Thread

```dart
import 'package:locorda_gdrive_slow/locorda_gdrive_slow.dart';

// Create handler, defaults to appDataFolder
final gdriveHandler = await GDriveMainIntegration.create();

// Use in Locorda
final locorda = await Locorda.create(
  remotes: [gdriveHandler],
  // ... other config
);
```

### Worker Thread

```dart
import 'package:locorda_gdrive_slow/worker.dart';

Future<WorkerParams> setupWorkerEngine() async => WorkerParams(
  remotes: [
    GDriveWorkerHandler(), // Config received automatically
  ],
  // ... storage config
);
```

## Default: App Data Folder (Recommended)

Uses Google Drive's private app-specific folder. Files are invisible to users and stored in an isolated space.

### Main Thread Setup

```dart
// Defaults to appDataFolder mode
final gdriveHandler = await GDriveMainIntegration.create();
```

Or a bit more explicit:
```dart
final gdriveHandler = await GDriveMainIntegration.create(
  config: GDriveConfig(), // Defaults to appDataFolder mode
);
```

### What Happens Automatically

- ✅ **Scopes**: `drive.appdata` + `openid` set automatically
- ✅ **Worker Sync**: Config sent to worker automatically
- ✅ **Auth Management**: GDriveAuth created and managed internally

### Advantages

- ✅ **Private**: Invisible to user in Drive UI
- ✅ **Performance**: Faster due to smaller search space
- ✅ **Clean**: Doesn't clutter My Drive
- ✅ **Secure**: Only your app has access
- ✅ **Simple**: No manual scope management needed

## Visible Folder Mode

Creates a visible folder in user's My Drive. Users can see and manage files directly.

### Main Thread Setup

```dart
final gdriveHandler = await GDriveMainIntegration.create(
  config: GDriveConfig.visibleFolder(
    appFolderName: 'MyAppData', // Visible folder name
  ),
);
```

### What Happens Automatically

- ✅ **Scopes**: `drive.file` + `openid` set automatically
- ✅ **Worker Sync**: Config sent to worker automatically
- ✅ **Folder Creation**: App folder created in My Drive automatically

### Use Cases

- User needs direct file access
- Manual inspection/editing required
- Debugging or development

## Advanced: Custom Folder Names per Type

You can override folder names for specific resource types.

### App Data Folder with Custom Names

```dart
final gdriveHandler = await GDriveMainIntegration.create(
  config: GDriveConfig(
    typeFolderNames: {
      IriTerm('https://schema.org/Note'): 'notes',
      IriTerm('https://schema.org/Person'): 'contacts',
      // All index types automatically use 'indices' folder
    },
  ),
);
```

### Visible Folder with Custom Names

```dart
final gdriveHandler = await GDriveMainIntegration.create(
  config: GDriveConfig.visibleFolder(
    appFolderName: 'MyAppRoot',
    typeFolderNames: {
      IriTerm('https://schema.org/Note'): 'my-notes',
      IriTerm('https://schema.org/Task'): 'todos',
    },
  ),
);
```

### Folder Structure

**App Data Folder Mode:**
```
appDataFolder/           (invisible root)
  ├── notes/            (for schema:Note)
  ├── contacts/         (for schema:Person)
  └── indices/          (for all index types)
```

**Visible Folder Mode:**
```
My Drive/
  └── MyAppRoot/        (visible folder)
      ├── notes/
      ├── contacts/
      └── indices/
```


## Important Notes

### OAuth Scope Management

You **don't need to manage scopes manually**. The handler automatically sets the correct scopes based on your `GDriveConfig`:

- `GDriveConfig()` → `drive.appdata` + `openid`
- `GDriveConfig.visibleFolder(...)` → `drive.file` + `openid`

### Existing Data

Switching modes doesn't migrate existing data. Consider:

1. **New app**: Use app data folder (default)
2. **Existing app with visible folder**: Keep `GDriveConfig.visible()`
3. **Migration needed**: Implement custom data migration

### Performance

App Data Folder mode is significantly faster because:
- Smaller search space (only your app's files)
- No need to traverse user's entire Drive
- Optimized Google Drive API paths
