## 0.5.0

- Initial public release
- `SolidAuthBridge`: main-thread bridge that forwards DPoP credential updates to the worker via `WorkerChannel`
- `WorkerSolidAuthProvider`: worker-side `SolidAuthProvider` that receives credential updates from the main thread
- `UpdateAuthMessage`: typed message for transmitting authentication state across the isolate/worker boundary
- Enables DPoP token signing inside the worker without main-thread round-trips
