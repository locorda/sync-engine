# locorda_gdrive_slow

Google Drive backend and authentication for locorda CRDT synchronization.

## Features

- ✅ **Google Drive Backend**: Store RDF data in Google Drive
- ✅ **Google Sign-In**: Uses official `google_sign_in` package
- ✅ **OAuth2 Authentication**: Secure authentication via Google
- ✅ **Worker Support**: Heavy operations run in isolate/web worker
- ✅ **Flutter UI Components**: Login screen and status widget
- ✅ **Localized**: English and German translations
- ✅ **Cross-Platform**: iOS, Android, Web, Desktop

## Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  locorda_gdrive_slow:
    path: ../locorda_gdrive_slow  # When using from monorepo
```

## Usage

### Main Thread Setup

```dart
import 'package:locorda_flutter/locorda_flutter.dart';
import 'package:locorda_ui/locorda_ui.dart';
import 'package:locorda_gdrive_slow/locorda_gdrive_slow.dart';

// 1. Create GDrive handler (uses recommended defaults)
final gdrive = await GDriveMainIntegration.create();
// This uses:
// - Private app data folder (invisible to user, better performance)
// - OAuth client ID from platform config (Info.plist/google-services.json/meta tag)

// 2. Create Locorda with handler
final locorda = await Locorda.create(
  workerSetup: createEngineParams,
  jsScript: 'worker.dart.js',
  remotes: [gdrive],
  config: LocordaConfig(
    resources: [/* your resources */],
  ),
);

// 3. Use in UI
AppBar(
  actions: [
    // we can use a generic widget, or a specific or custom one of course as well
    MultiBackendStatusWidget(
      registry: locorda.uiAdapterRegistry,
      syncManager: locorda.syncManager,
    ),
  ],
)
```

### Worker Thread Setup

```dart
// worker.dart
import 'package:locorda_worker/worker.dart';
import 'package:locorda_gdrive_slow/worker.dart';

void main() {
  workerMain(setupWorkerEngine);
}

Future<WorkerParams> setupWorkerEngine() async => WorkerParams(
      // Config is automatically received from main thread
      remotes: [
        GDriveWorkerHandler(),
      ],

      // ... storage needs to be configured as well
    );
```

### Storage Modes

The default configuration (no parameters) uses the **App Data Folder** - a private, high-performance storage area that's invisible to users.

#### App Data Folder (Default, Recommended)

```dart
// Simplest setup - uses all defaults
final gdriveHandler = await GDriveMainIntegration.create();

// Equivalent to:
// final gdriveHandler = await GDriveMainIntegration.create(
//   config: GDriveConfig(), 
// );
```

**Advantages:**
- ✅ **Private**: Invisible to user in Google Drive UI
- ✅ **Performance**: Faster search in smaller, isolated space
- ✅ **Clean**: Doesn't clutter user's My Drive
- ✅ **Secure**: Only your app can access
- ✅ **Automatic Scopes**: Uses `drive.appdata` automatically

#### Visible Folder Mode

```dart
final gdriveHandler = await GDriveMainIntegration.create(
  config: GDriveConfig.visibleFolder(
    appFolderName: 'MyAppFolder',
  ),
);
```

**Use when:**
- User needs direct access to files
- Manual file inspection/editing required
- Debugging or development

**Automatic Scopes**: Uses `drive.file` automatically

**Note**: OAuth client ID is read from platform-specific configuration files.
See [OAuth2 Setup](#oauth2-setup) below for configuration details.

### Advanced Configuration

```dart
final gdriveHandler = await GDriveMainIntegration.create(
  config: GDriveConfig(
    // Custom folder names for specific resource types
    typeFolderNames: {
      IriTerm('https://schema.org/Note'): 'notes',
      IriTerm('https://schema.org/Person'): 'contacts',
    },
  ),
);

// Or with visible folder:
final gdriveHandler = await GDriveMainIntegration.create(
  config: GDriveConfig.visibleFolder(
    appFolderName: 'MyApp',
    typeFolderNames: {
      IriTerm('https://schema.org/Note'): 'notes',
    },
  ),
);
```

## OAuth2 Setup

**Important**: OAuth client IDs are configured **per platform** in configuration files,
not in code. The `GDriveMainIntegration` automatically reads these platform-specific configurations.

### 1. Create Google Cloud Project

1. Go to [Google Cloud Console](https://console.cloud.google.com/)
2. Create a new project or select existing
3. Enable **Google Drive API**

### 2. Create OAuth2 Credentials

1. Go to **APIs & Services** → **Credentials**
2. Click **Create Credentials** → **OAuth 2.0 Client ID**

**For Web:**
```
Type: Web application
Authorized JavaScript origins:
  - http://localhost
  - http://localhost:7357 (replace with your dev port)
  - https://yourdomain.com
```

**For Mobile/Desktop:**
```
Type: iOS / Android / Desktop app
(No redirect URI needed - uses custom URL scheme)
```

### 3. Configure Scopes

The required scopes are **automatically set** based on your configuration:
- `GDriveConfig()` → Uses `drive.appdata` (app data folder)
- `GDriveConfig.visibleFolder(...)` → Uses `drive.file` (visible files)
- Always includes `openid` for stable user identification

Enable these scopes in your Google Cloud Console OAuth consent screen.

### 4. Platform-Specific Setup

**iOS:**
Add to `ios/Runner/Info.plist`:
```xml
<key>GIDClientID</key>
<string>YOUR-IOS-CLIENT-ID.apps.googleusercontent.com</string>
<key>GIDServerClientID</key>
<string>YOUR-SERVER-CLIENT-ID.apps.googleusercontent.com</string>
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleTypeRole</key>
    <string>Editor</string>
    <key>CFBundleURLSchemes</key>
    <array>
      <string>com.googleusercontent.apps.YOUR-CLIENT-ID</string>
    </array>
  </dict>
</array>
```

**macOS:**
Use `macos/Runner/Info.plist` with the same keys as iOS and ensure the
entitlements include keychain sharing:
```xml
<key>keychain-access-groups</key>
<array>
  <string>$(AppIdentifierPrefix)com.google.GIDSignIn</string>
</array>
```

**Android:**
No additional setup needed if using default configuration.

**Web:**
Add to `web/index.html` before `</head>`:
```html
<meta name="google-signin-client_id" content="YOUR-CLIENT-ID.apps.googleusercontent.com">
<script src="https://accounts.google.com/gsi/client" async defer></script>
```

On web, the sign-in UI must be provided by the GIS SDK. Use
`google_sign_in_web`'s `renderButton()` and listen to `authenticationEvents`
instead of calling `authenticate()` from a custom button.

Recommended pattern (web):
```dart
// Render the official GIS button and handle auth via the stream.
if (kIsWeb) {
  return renderButton();
}

// Use authenticationEvents to track sign-in state on all platforms.
GoogleSignIn.instance.authenticationEvents.listen((event) {
  // Update UI state based on sign-in/sign-out events.
});
```

See [google_sign_in documentation](https://pub.dev/packages/google_sign_in) for detailed platform setup.

## Architecture

```
┌─────────────────────┐
│   Main Thread       │
│  ┌──────────────┐   │
│  │ GDriveAuth   │───┼──── OAuth2 Flow
│  └──────┬───────┘   │
│         │           │
│  ┌──────▼───────┐   │
│  │ Auth         │   │
│  │ Sender       │   │
│  └──────┬───────┘   │
└─────────┼───────────┘
          │ Credentials
          │ via Channel
┌─────────▼───────────┐
│   Worker Thread     │
│  ┌──────────────┐   │
│  │ Worker       │   │
│  │ GDriveAuth   │   │
│  │ Provider     │   │
│  └──────┬───────┘   │
│         │           │
│  ┌──────▼───────┐   │
│  │ GDrive       │───┼──── Drive API
│  │ Backend      │   │     (RDF files)
│  └──────────────┘   │
└─────────────────────┘
```

## Implementation Status

### ✅ Completed
- Package structure and dependencies
- Authentication interfaces and worker protocol
- Backend structure (GDriveClient, GDriveBackend)
- Worker sender/receiver/connector pattern
- UI components (login screen, status widget)
- Localizations (EN, DE)

### 🚧 TODO
- [x] OAuth2 authentication using `google_sign_in`
- [x] Token refresh via `clearAuthCache()` + re-authentication
- [x] Silent sign-in for returning users
- [x] Drive API HTTP operations (upload/download/delete)
- [ ] File ID mapping strategy
- [x] App folder support
- [ ] Tests
- [x] Example app integration

## Comparison with Solid Backend

| Feature | Solid | Google Drive |
|---------|-------|--------------|
| Auth | DPoP tokens | OAuth2 Bearer |
| Token generation | Per-request (worker) | Reused (refreshed) |
| Storage model | Solid Pods | Drive files |
| File structure | User-controlled | App folder |
| Multi-user | Native | Future |

## License

See LICENSE file in repository root.
