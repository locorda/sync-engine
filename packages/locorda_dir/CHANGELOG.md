## 0.5.1

## 0.5.0

- Initial public release
- Local directory backend for Locorda: syncs RDF Turtle files to a local folder (useful for development and desktop applications)
- `DirMainIntegration`: main-thread `RemoteIntegration` with platform-aware path detection via `path_provider`
- `DirWorkerHandler`: worker-thread handler for file I/O operations
- `DirLoginScreen`: Flutter UI for enabling the backend and displaying the sync directory path
- ETag support based on file modification time and size for efficient change detection
- Files organised by resource type (e.g. `Note/`, `Category/`)
- Default paths: `~/Library/Containers/<appBundleName>/Data/Documents/locorda/` (macOS), `~/Documents/<appName>/locorda-sync/` or  (Linux), `%USERPROFILE%\Documents\<appName>\locorda-sync\` (Windows)
- Platform support: macOS, Linux, Windows (full); iOS/Android (app sandbox only); Web (not supported)