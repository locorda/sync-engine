## 0.5.2

 - **FIX**(dependencies): adjust file_picker version constraint to allow specific range. ([fdeab3e1](https://github.com/locorda/sync-engine/commit/fdeab3e1d426198d1ef15b942d98ecb567ad8b2f))
 - **FIX**(dependencies): update dependencies. ([f4f32697](https://github.com/locorda/sync-engine/commit/f4f32697722ac968bd554e833baffd9d37aa75c9))
 - **DOCS**(dir_main_integration_io): format directory path examples for clarity. ([64cf99eb](https://github.com/locorda/sync-engine/commit/64cf99eba1d8d6650a64f0d7418bbb224f765b2d))
 - **DOCS**: reposition packages as BYOB offline-first sync. ([9a03fd0a](https://github.com/locorda/sync-engine/commit/9a03fd0a170ace56bc9a372aae2effea1949aa19))

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