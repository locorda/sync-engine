## 0.5.0

- Initial public release
- `WorkerGeneratorBuilder`: auto-generates `lib/worker_generated.g.dart` by discovering all `locorda_worker.manifest.dart` files across dependencies
- `WebWorkerBuilder`: compiles workers to JavaScript — manual `lib/worker.dart` → `web/worker.dart.js`, generated `lib/worker_generated.g.dart` → `web/worker_generated.dart.js`
- Convention-over-configuration: zero build config required for standard setups
- Applied automatically to packages that declare `locorda_dev` as a dev dependency
