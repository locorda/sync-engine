## 0.5.2

 - **DOCS**: reposition packages as BYOB offline-first sync. ([9a03fd0a](https://github.com/locorda/sync-engine/commit/9a03fd0a170ace56bc9a372aae2effea1949aa19))

## 0.5.1

## 0.5.0

- Initial public release
- `SolidMainIntegration`: main-thread `RemoteIntegration` for Solid Pod backends; handles OIDC authentication, login UI and worker bridge
- `SolidWorkerHandler`: worker-thread handler for HTTP operations against Solid Pods
- `SolidConfig`: configuration for storage paths and Solid-specific options
- `SolidAuthLocalizations`: localisation support for login UI (English and German)
- Uses `FilePerResource` storage layout: each RDF resource maps to one Solid document, maintaining full linked-data interoperability
- Note: Solid's HTTP protocol has no batch-write primitive; each save requires an individual PUT/PATCH request