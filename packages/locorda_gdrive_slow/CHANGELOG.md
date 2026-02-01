## 0.1.0-dev

Initial development version.

### Features

- Google Drive backend for locorda CRDT synchronization
- OAuth2 authentication using official `google_sign_in` package
- Worker isolate/thread support for heavy operations
- Credential synchronization main thread ↔ worker thread
- Flutter UI components:
  - GDriveLoginScreen - Full-screen OAuth2 login
  - GDriveStatusWidget - AppBar status indicator
  - GDriveStatusDefaults - Default UI implementations
- Localizations: English and German
- Cross-platform: iOS, Android, Web, Desktop

### Implementation Status

**Completed:**
- ✅ Package structure and dependencies
- ✅ OAuth2 authentication with `google_sign_in`
- ✅ Silent sign-in for returning users
- ✅ Token refresh mechanism
- Authentication interfaces (GDriveAuthProvider)
- Worker protocol (messages, sender, receiver, connector)
- Backend structure (GDriveBackend, GDriveClient, GDriveRemoteStorage)
- UI scaffolding

**TODO:**
- Actual OAuth2 flow implementation (platform-specific)
- Token refresh implementation
- Drive API operations (upload, download, delete)
- File ID mapping strategy
- Tests and example app
