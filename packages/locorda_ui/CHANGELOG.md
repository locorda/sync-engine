## 0.5.0

- Initial public release
- `MultiBackendStatusWidget`: Flutter widget showing authentication and sync status for all registered backends; integrates with `UiAdapterRegistry`
- `SyncRefreshIndicator`: pull-to-refresh widget that triggers a manual sync cycle
- `RemoteUiAdapter`: interface for backend packages to expose login screens and status widgets
- `UiAdapterRegistry`: runtime registry of active `RemoteUiAdapter` instances
- `LocordaStatusWidget` / `LocordaStatusDefaults`: generic status display components
- Localisation support (English and German)
