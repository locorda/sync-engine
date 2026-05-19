## 0.5.2

 - **FIX**(dependencies): update analyzer version constraint to support Dart SDK range. ([f738f93b](https://github.com/locorda/sync-engine/commit/f738f93b94560dd96b94d86238ae2603f0437a41))
 - **DOCS**: reposition packages as BYOB offline-first sync. ([9a03fd0a](https://github.com/locorda/sync-engine/commit/9a03fd0a170ace56bc9a372aae2effea1949aa19))

## 0.5.1

## 0.5.0

- Initial public release
- `WorkerGeneratorBuilder`: auto-generates `lib/worker_generated.g.dart` by discovering all `locorda_worker.manifest.dart` files across dependencies
- `WebWorkerBuilder`: compiles workers to JavaScript — manual `lib/worker.dart` → `web/worker.dart.js`, generated `lib/worker_generated.g.dart` → `web/worker_generated.dart.js`
- Convention-over-configuration: zero build config required for standard setups
- Applied automatically to packages that declare `locorda_dev` as a dev dependency
