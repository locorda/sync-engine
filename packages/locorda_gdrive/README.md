# locorda_gdrive

Google Drive backend for Locorda CRDT synchronization.

## Features

- **Google Drive backend** — stores RDF sync data in the App Data Folder or a visible Drive folder
- **Google Sign-In** — uses the official `google_sign_in` package
- **Worker isolate support** — all Drive I/O runs in a background isolate/web worker
- **Storage layouts** — `SingleFile` (default), `ShardDataset`, `FilePerResource`
- **Flutter UI** — login screen and status widget included
- **Localised** — English and German

## Installation

```sh
flutter pub add locorda locorda_gdrive
flutter pub add dev:build_runner dev:locorda_dev
```

> **OAuth2 setup required** — you must configure platform-specific OAuth2 credentials before
> GDrive sync will work. See [OAuth2 Setup](#oauth2-setup) below.

## Quick start

### 1. Run code generation

```bash
dart run build_runner build
```

`locorda_dev` discovers `locorda_gdrive` via its worker manifest and automatically includes
`GDriveWorkerHandler` in the generated `worker_generated.g.dart` — no manual worker code needed.

### 2. Initialize on the main thread

```dart
import 'package:locorda/locorda.dart';
import 'package:locorda_gdrive/locorda_gdrive.dart';
import 'init_locorda.g.dart';  // generated

final locorda = await initLocorda(
  storage: DriftMainHandler(),
  remotes: [await GDriveMainIntegration.create()],
);
```

`GDriveMainIntegration.create()` uses the App Data Folder by default —
private storage that is invisible to the user in Google Drive UI.
See [Storage Modes](#storage-modes) for alternatives.

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
```

## Storage Modes

### App Data Folder (default, recommended)

Private, isolated storage invisible to users. Uses `drive.appdata` scope automatically.

```dart
// Simplest — uses all defaults
await GDriveMainIntegration.create()

// Equivalent explicit form
await GDriveMainIntegration.create(config: GDriveConfig())
```

**Advantages over a visible folder:**
- Invisible to the user — no folder clutter in My Drive
- Faster search (smaller, isolated namespace)
- Only your app can access it

### Visible Folder

```dart
await GDriveMainIntegration.create(
  config: GDriveConfig.visibleFolder(appFolderName: 'MyApp'),
)
```

Use when users need direct access to the files (e.g. debugging, manual migration).
Uses `drive.file` scope automatically.

## Storage Layouts

Layout controls how RDF resources are packed into Drive files. Configure it inside `GDriveConfig`:

```dart
// SingleFile — everything in one TriG file (default — fewest requests)
GDriveConfig(layout: SingleFile())

// ShardDataset — one TriG file per shard (better for large collections)
GDriveConfig(layout: ShardDataset())

// FilePerResource — one Turtle file per resource (Solid-style interop)
GDriveConfig(layout: FilePerResource())
```

## Advanced Configuration

```dart
await GDriveMainIntegration.create(
  config: GDriveConfig(
    typeFolderNames: {
      IriTerm('https://schema.org/Note'): 'notes',
      IriTerm('https://schema.org/Person'): 'contacts',
    },
  ),
)

// Combining visible folder with custom type folders
await GDriveMainIntegration.create(
  config: GDriveConfig.visibleFolder(
    appFolderName: 'MyApp',
    typeFolderNames: {
      IriTerm('https://schema.org/Note'): 'notes',
    },
  ),
)
```

## OAuth2 Setup

> **Note**: OAuth client IDs are configured **per platform** in native config files,
> not in Dart code. `GDriveMainIntegration` reads them automatically.

### 1. Create a Google Cloud Project

1. Go to [Google Cloud Console](https://console.cloud.google.com/)
2. Create or select a project
3. Enable **Google Drive API**

### 2. Create OAuth2 Credentials

Go to **APIs & Services → Credentials → Create Credentials → OAuth 2.0 Client ID**.

**Web:**
```
Type: Web application
Authorized JavaScript origins:
  - http://localhost
  - http://localhost:7357  (replace with your dev port)
  - https://yourdomain.com
```

**Mobile/Desktop:**
```
Type: iOS / Android / Desktop app
(No redirect URI — uses custom URL scheme)
```

### 3. Configure Scopes

Scopes are set automatically based on your config:

| Config | Scope |
|--------|-------|
| `GDriveConfig()` (App Data Folder) | `drive.appdata` |
| `GDriveConfig.visibleFolder(...)` | `drive.file` |

Always also includes `openid` for stable user identification.

Enable these scopes on the OAuth consent screen in Google Cloud Console.

### 4. Platform-Specific Setup

**iOS** — `ios/Runner/Info.plist`:
```xml
<key>GIDClientID</key>
<string>YOUR-IOS-CLIENT-ID.apps.googleusercontent.com</string>
<key>GIDServerClientID</key>
<string>YOUR-SERVER-CLIENT-ID.apps.googleusercontent.com</string>
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleTypeRole</key><string>Editor</string>
    <key>CFBundleURLSchemes</key>
    <array>
      <string>com.googleusercontent.apps.YOUR-CLIENT-ID</string>
    </array>
  </dict>
</array>
```

**macOS** — `macos/Runner/Info.plist` with the same keys as iOS, plus entitlements:
```xml
<key>keychain-access-groups</key>
<array>
  <string>$(AppIdentifierPrefix)com.google.GIDSignIn</string>
</array>
```

**Android** — no additional setup needed with default configuration.

**Web** — `web/index.html` before `</head>`:
```html
<meta name="google-signin-client_id" content="YOUR-CLIENT-ID.apps.googleusercontent.com">
<script src="https://accounts.google.com/gsi/client" async defer></script>
```

On web the sign-in button must be rendered via the GIS SDK:
```dart
if (kIsWeb) {
  return renderButton();  // from google_sign_in_web
}
```

See [google_sign_in documentation](https://pub.dev/packages/google_sign_in) for full platform setup.

## Architecture

```
┌─────────────────────┐
│   Main Thread       │
│  ┌──────────────┐   │
│  │ GDriveAuth   │───┼──── OAuth2 Flow
│  └──────┬───────┘   │
│         │ credentials via channel
└─────────┼───────────┘
┌─────────▼───────────┐
│   Worker Thread     │
│  ┌──────────────┐   │
│  │ GDriveWorker │───┼──── Drive API
│  │ Handler      │   │     (RDF files)
│  └──────────────┘   │
└─────────────────────┘
```

All Drive I/O happens in the worker thread. The main thread only handles the OAuth2 sign-in flow and forwards credentials via a typed channel.

## License

See LICENSE file in repository root.
