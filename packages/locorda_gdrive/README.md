# locorda_gdrive

[![pub package](https://img.shields.io/pub/v/locorda_gdrive.svg)](https://pub.dev/packages/locorda_gdrive)
[![license](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/locorda/sync-engine/blob/main/LICENSE)

Google Drive backend for Locorda — the recommended default BYOB backend. Stores app sync data in the App Data Folder or a visible Drive folder using Google Sign-In (OAuth2), with all Drive I/O running in a background worker isolate.

## Features

- **Flexible Storage Location** — Stores RDF sync data in the Google Drive App Data Folder or a visible Drive folder.
- **Full Platform Support** — Supports Android, iOS, macOS, Web, Windows, and Linux.
- **Worker Isolate Ready** — Drive I/O runs in a background isolate when used with `locorda_worker`; `locorda_dev` wires this up automatically.
- **Storage Layouts** — Configurable layouts: `SingleFile` (default), `ShardDataset`, `FilePerResource`.
- **Flutter UI Components** — Includes a login screen and sync status widgets, localised in English and German.

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

> [!NOTE]
> **Platform Requirements**
> * **Windows & Linux**: You **must** provide a `clientId` and `clientKey` using secure environment defines.
> * **Android, iOS, macOS, Web**: Credentials come from platform-specific native configuration files (see below). Passing `clientId` is optional and only useful if you want to override the native config — but it must be a credential of the correct platform type, **not** a Desktop-type client ID. `clientKey` is only used on Windows & Linux and is ignored on all other platforms.

### 1. Create a Google Cloud Project

1. Go to the [Google Cloud Console](https://console.cloud.google.com/).
2. Create or select a project.
3. Enable the **Google Drive API**.

---

### 2. Create OAuth2 Credentials

Go to **APIs & Services → Credentials → Create Credentials → OAuth 2.0 Client ID** and create separate credentials for each platform you support:

#### Android
- **Application type**: Android
- **Package name**: Your app's package name (e.g., `dev.locorda.example.personalNotesApp`)
- **SHA-1 certificate fingerprint**: Your development/production signing key fingerprint (obtain via `keytool -list -v -keystore ~/.android/debug.keystore`)

#### iOS / macOS
- **Application type**: iOS
- **Bundle ID**: Your app's bundle identifier (e.g., `dev.locorda.example.personalNotesApp`)

#### Web
- **Application type**: Web application
- **Authorized JavaScript origins**:
  - `http://localhost`
  - `http://localhost:3815` (or whichever port you use for development)
  - `https://your-production-domain.com`

#### Windows / Linux
- **Application type**: Desktop application
- *Note*: Google automatically configures standard local loopback redirect (`http://localhost`) for desktop clients.

---

### 3. Configure Scopes

Scopes are set automatically based on your config:

| Config | Scope |
|--------|-------|
| `GDriveConfig()` (App Data Folder) | `drive.appdata` |
| `GDriveConfig.visibleFolder(...)` | `drive.file` |

Always also includes `openid` for stable user identification. Add the relevant scope (`drive.appdata` or `drive.file`) and `openid` to the **OAuth consent screen** in Google Cloud Console.

---

### 4. Platform-Specific Setup

#### iOS
Add the following to `ios/Runner/Info.plist`:
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

#### macOS
Add the same keys as iOS to `macos/Runner/Info.plist`, plus add the following keychain access entitlement:
```xml
<key>keychain-access-groups</key>
<array>
  <string>$(AppIdentifierPrefix)com.google.GIDSignIn</string>
</array>
```

#### Android
No additional setup is needed with the default configuration. Android utilizes the client ID automatically verified by your SHA-1 signing key configured in Google Cloud Console.

#### Web
Add the Google Identity Services SDK to `web/index.html` before `</head>`:
```html
<meta name="google-signin-client_id" content="YOUR-WEB-CLIENT-ID.apps.googleusercontent.com">
<script src="https://accounts.google.com/gsi/client" async defer></script>
```

On web, the sign-in button must be rendered via the GIS SDK:
```dart
if (kIsWeb) {
  return renderButton();  // from google_sign_in_web
}
```

See the [google_sign_in documentation](https://pub.dev/packages/google_sign_in) for full platform setup details.

#### Windows & Linux (Desktop)
On Windows and Linux, native SDKs are not supported. Authentication is handled via a secure local loopback redirect server.

To prevent checking your private client credentials into a Git repository, use Dart compile-time environment defines:

1. Create a `secrets.json` file in your project root (and add it to your `.gitignore`):
   ```json
   {
     "GDRIVE_CLIENT_ID": "YOUR-DESKTOP-CLIENT-ID.apps.googleusercontent.com",
     "GDRIVE_CLIENT_KEY": "YOUR-DESKTOP-CLIENT-KEY"
   }
   ```

2. Initialize the remote in your Dart code reading the constants:
   ```dart
   const clientId = String.fromEnvironment('GDRIVE_CLIENT_ID');
   const clientKey = String.fromEnvironment('GDRIVE_CLIENT_KEY');

   final locorda = await initLocorda(
     storage: DriftMainHandler(),
     remotes: [
       await GDriveMainIntegration.create(
         clientId: clientId.isNotEmpty ? clientId : null,
         clientKey: clientKey.isNotEmpty ? clientKey : null,
       ),
     ],
   );
   ```

3. Run or compile your app using the secrets file:
   ```bash
   flutter run -d linux --dart-define-from-file=secrets.json
   ```

On first run, the app will automatically launch the user's default browser to request consent and spin up a temporary local loopback server to receive the authorization code. Subsequent runs will use secure local credentials persisted via `shared_preferences`.

## Binary Size Optimization

By default, both the loopback OAuth2 backend (Windows/Linux) and the native
Google Sign-In backend (Android/iOS/macOS/Web) are compiled into every build.
The correct backend is selected at runtime. This is safe for all targets but
prevents dead-code elimination of the unused backend.

If you target only one class of platform you can opt in to tree shaking by
setting `LOCORDA_GDRIVE_LOOPBACK_AUTH` at build time:

| Build flag | Effect |
|---|---|
| *(not set)* | Runtime detection — both backends included (default) |
| `--dart-define=LOCORDA_GDRIVE_LOOPBACK_AUTH=true` | Loopback only — Google Sign-In backend tree-shaken |
| `--dart-define=LOCORDA_GDRIVE_LOOPBACK_AUTH=false` | Google Sign-In only — loopback backend tree-shaken |

Example for a mobile-only build:
```bash
flutter build apk --dart-define=LOCORDA_GDRIVE_LOOPBACK_AUTH=false
```

Example for a Windows/Linux-only build:
```bash
flutter build windows --dart-define=LOCORDA_GDRIVE_LOOPBACK_AUTH=true
```

> [!NOTE]
> The loopback backend depends on `googleapis_auth/auth_io.dart` for the local
> redirect server. Setting `=false` removes this and its transitive dependencies
> from mobile/web builds. The size saving is modest but the option exists for
> teams with strict binary size budgets.

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
