## 0.5.0

- Initial public release
- `SolidBackend`: `PipelineBackend` implementation for Solid Pods; handles HTTP read/write against LDP resources using DPoP-authenticated requests
- `SolidAuthProvider`: worker-side auth interface supplying DPoP access tokens and proof headers
- `SolidConfig`: configuration for storage container paths and Solid protocol options
