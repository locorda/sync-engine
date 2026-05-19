## 0.5.2

 - **FIX**(auth): do not await genDpopToken - it is a synchronous operation. ([f60ea06c](https://github.com/locorda/sync-engine/commit/f60ea06ceb642b596539266095295524824c3a5e))

## 0.5.1

## 0.5.0

- Initial public release
- `SolidAuthBridge`: bridges `SolidOidcAuth` to `locorda_core`'s `Auth` interface
- `SolidLoginPage` / `SolidStatusWidget` / `SolidStatusDefaults`: ready-to-use Flutter UI components for Solid OIDC authentication and status display
- `SolidProviderService` / `DefaultSolidProviderService`: fetches and caches the list of known Solid identity providers
- `SolidAuthLocalizations`: localisation support (English and German)
