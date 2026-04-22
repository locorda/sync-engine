# locorda_solid_auth

[![pub package](https://img.shields.io/pub/v/locorda_solid_auth.svg)](https://pub.dev/packages/locorda_solid_auth)
[![license](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/locorda/sync-engine/blob/main/LICENSE)

Solid OIDC / DPoP authentication implementation for Locorda, used internally by [`locorda_solid`](../locorda_solid).

> Most applications should depend on [`locorda_solid`](../locorda_solid) rather than this package directly. Add `locorda_solid_auth` only when you need to integrate Solid authentication into a custom UI or auth flow without the full Solid backend.

## What it contains

| Type | Purpose |
|------|---------|
| `SolidAuthBridge` | Wraps the `solid_auth` library; handles OIDC token exchange and DPoP proof generation |
| `SolidLoginPage` | Ready-to-use Flutter login screen for Solid Pods |
| `SolidStatusWidget` / `SolidStatusDefaults` | Sync-status widget for Solid backends |
| `SolidProviderService` | Discovers and lists known Solid identity providers |
| `SolidAuthLocalizations` | Localisation delegates for the login UI |

## Dependency

```sh
flutter pub add locorda_solid_auth
```

## Further reading

- [locorda_solid](../locorda_solid) — recommended entry point for Solid Pod sync
- [locorda](../locorda) — getting started guide
