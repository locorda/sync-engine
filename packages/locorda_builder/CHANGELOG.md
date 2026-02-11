## 0.1.0-dev

* Initial development release
* WorkerGeneratorBuilder: Auto-generates `lib/worker_generated.g.dart` from manifest discovery
* WebWorkerBuilder: Compiles workers to distinct JS outputs:
  - Manual: `lib/worker.dart` → `web/worker.dart.js`
  - Generated: `lib/worker_generated.g.dart` → `web/worker_generated.dart.js`
* **Breaking**: Generated worker uses different output name (`worker_generated.dart.js`) to
  allow coexistence with manual workers without build collisions
* Convention over configuration - zero config for standard setup  
* auto_apply: dependents - automatically runs for packages using locorda
