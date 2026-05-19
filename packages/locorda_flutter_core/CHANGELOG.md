## 0.5.2

 - **DOCS**: reposition packages as BYOB offline-first sync. ([9a03fd0a](https://github.com/locorda/sync-engine/commit/9a03fd0a170ace56bc9a372aae2effea1949aa19))

## 0.5.1

## 0.5.0

- Initial public release
- `RemoteIntegration`: combined `RemoteMainHandler` + `RemoteUiAdapter` interface; implement to create a backend plugin for Locorda
- `LocordaGraph`: lightweight wrapper around `RdfGraph` used as the unit of data transfer between the main thread and the worker