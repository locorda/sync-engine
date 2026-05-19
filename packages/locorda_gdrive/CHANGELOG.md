## 0.5.2

 - **REFACTOR**(gdrive): introduce GDriveFolderStrategy interface. ([6e57be4c](https://github.com/locorda/sync-engine/commit/6e57be4c85c4eb68f2ef268b779082d0178d2617))
 - **FIX**(sync): recover missing gdrive folder and surface upload failures. ([6bffaded](https://github.com/locorda/sync-engine/commit/6bffadedf127092a3b7bdfbdb6540f950c07e123))
 - **FIX**(gdrive): append file extension to remote paths and disable mirror for SingleFile. ([e21d85f8](https://github.com/locorda/sync-engine/commit/e21d85f874226fb9299b325891a13564f3cc3c18))
 - **DOCS**(locorda_gdrive): add example, strict analysis, fix type annotations. ([b1e18e90](https://github.com/locorda/sync-engine/commit/b1e18e90d86b0ec670299545e6d8afb1c707d66e))
 - **DOCS**: reposition packages as BYOB offline-first sync. ([9a03fd0a](https://github.com/locorda/sync-engine/commit/9a03fd0a170ace56bc9a372aae2effea1949aa19))

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
