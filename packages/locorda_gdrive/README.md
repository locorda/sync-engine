# locorda_gdrive

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
  locorda_gdrive:
    path: ../locorda_gdrive  # When using from monorepo
```

## Usage

### Main Thread Setup

```dart
import 'package:locorda_flutter/locorda_flutter.dart';
import 'package:locorda_ui/locorda_ui.dart';
import 'package:locorda_gdrive/locorda_gdrive.dart';

// 1. Initialize Google Drive authentication
final gdriveAuth = await GDriveAuth.create(
  // Optional: Platform-specific OAuth2 client ID
  // If omitted, reads from Info.plist (iOS), google-services.json (Android), or meta tag (Web)
  clientId: 'your-client-id.apps.googleusercontent.com',
  scopes: [
    'https://www.googleapis.com/auth/drive.file',
    'https://www.googleapis.com/auth/userinfo.email',
  ],
);
// Silent sign-in happens automatically during create()

// 2. Create Locorda with worker
final locorda = await Locorda.create(
  workerSetup: createEngineParams,
  jsScript: 'worker.dart.js',
  remotes: [
    GDriveMainHandler(gdriveAuth: gdriveAuth),
  ],
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
import 'package:locorda_gdrive/worker.dart';

void main() {
  workerMain(setupWorkerEngine);
}

Future<WorkerParams> setupWorkerEngine() async => WorkerParams(
      // in main, we configured GDrive as remote
      remotes: [
        GDriveWorkerHandler(
          config: GDriveConfig(
            appFolderName: 'LocordaPersonalNotes',
          ),
        )
      ],

      // ... storage needs to be configured as well
    );
```

## OAuth2 Setup

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
Authorized redirect URIs:
  - http://localhost:3000/redirect.html (development)
  - https://yourdomain.com/redirect.html (production)
```

**For Mobile/Desktop:**
```
Type: iOS / Android / Desktop app
(No redirect URI needed - uses custom URL scheme)
```

### 3. Configure Scopes

Required scopes:
- `https://www.googleapis.com/auth/drive.file` - Access app-created files
- `https://www.googleapis.com/auth/userinfo.email` - Get user email

### 4. Platform-Specific Setup

**iOS:**
Add to `ios/Runner/Info.plist`:
```xml
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
<key>GIDServerClientID</key>
<string>YOUR-SERVER-CLIENT-ID.apps.googleusercontent.com</string>
```

**Android:**
No additional setup needed if using default configuration.

**Web:**
Add to `web/index.html` before `</head>`:
```html
<meta name="google-signin-client_id" content="YOUR-CLIENT-ID.apps.googleusercontent.com">
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
