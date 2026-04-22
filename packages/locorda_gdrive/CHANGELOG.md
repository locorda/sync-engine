## 0.5.1

## 0.5.0

- Initial public release
- Google Drive backend for Locorda CRDT synchronisation
- `GDriveMainIntegration`: main-thread `RemoteIntegration` with OAuth2 via `google_sign_in`
- `GDriveWorkerHandler`: worker-thread handler for Drive API operations
- App Data Folder mode (default): private, high-performance storage invisible to the user
- Visible Folder mode: optional named folder in My Drive for user-accessible files
- Automatic silent sign-in for returning users and token refresh
- `GDriveLoginScreen`, `GDriveStatusWidget`, `GDriveStatusDefaults` Flutter UI components
- Localisations: English and German
- Platform support: iOS, Android, Web, Desktop
