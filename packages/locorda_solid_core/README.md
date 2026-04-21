# locorda_solid_core

Shared types and backend implementation for Solid Pod synchronisation — used internally by [`locorda_solid`](../locorda_solid).

> Most applications should depend on [`locorda_solid`](../locorda_solid) rather than this package directly. Add `locorda_solid_core` only when building a custom integration that needs the Solid backend types without the full `locorda_solid` setup.

## What it contains

| Type | Purpose |
|------|---------|
| `SolidBackend` | Core Solid Pod backend; handles HTTP reads/writes, ETag-based conflict detection |
| `SolidAuthProvider` | Auth interface bridging the sync engine to `locorda_solid_auth` |
| `SolidConfig` | Configuration for the Solid backend (Pod base URL, storage prefix, etc.) |

## Dependency

```sh
flutter pub add locorda_solid_core
```

## Further reading

- [locorda_solid](../locorda_solid) — recommended entry point for Solid Pod sync
- [locorda](../locorda) — getting started guide
