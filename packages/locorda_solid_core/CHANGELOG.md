## 0.5.2

 - **DOCS**: reposition packages as BYOB offline-first sync. ([9a03fd0a](https://github.com/locorda/sync-engine/commit/9a03fd0a170ace56bc9a372aae2effea1949aa19))

## 0.5.1

## 0.5.0

- Initial public release
- `SolidBackend`: `PipelineBackend` implementation for Solid Pods; handles HTTP read/write against LDP resources using DPoP-authenticated requests
- `SolidAuthProvider`: worker-side auth interface supplying DPoP access tokens and proof headers
- `SolidConfig`: configuration for storage container paths and Solid protocol options
