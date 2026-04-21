# locorda_ui

Flutter UI components for displaying Locorda sync status — re-exported by [`locorda`](../locorda).

> Most applications access these widgets via `import 'package:locorda/locorda.dart'`. Add `locorda_ui` directly only when you need the UI layer without the full Locorda runtime (e.g. a custom shell app).

## Widgets

| Type | Purpose |
|------|---------|
| `MultiBackendStatusWidget` | Shows aggregated sync state across all configured backends |
| `LocordaStatusWidget` | Single-backend sync status indicator |
| `LocordaStatusDefaults` | Default icon/colour presets for sync states |
| `SyncRefreshIndicator` | Pull-to-refresh wrapper that triggers a sync cycle |
| `RemoteUiAdapter` | Interface for backend-specific status UI contributions |
| `UiAdapterRegistry` | Registry that maps backend instances to their `RemoteUiAdapter` |
| `LocordaUILocalizations` | Localisation delegates for built-in widget strings |

## Dependency

```sh
flutter pub add locorda_ui
```

## Further reading

- [locorda](../locorda) — recommended entry point (includes this package)
