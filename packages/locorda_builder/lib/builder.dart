/// Build-time transformations for Locorda applications.
///
/// Provides builders for:
/// - **WorkerGeneratorBuilder**: Auto-generates `lib/worker_generated.g.dart` from manifest files
/// - **WebWorkerBuilder**: Compiles workers to JS with distinct outputs:
///   - `lib/worker.dart` → `web/worker.dart.js` (manual)
///   - `lib/worker_generated.g.dart` → `web/worker_generated.dart.js` (generated)
///
/// ## Usage
///
/// Add to your `pubspec.yaml`:
///
/// ```yaml
/// dev_dependencies:
///   locorda_builder: ^0.1.0
///   build_runner: ^2.4.0
/// ```
///
/// The builders are automatically applied to projects that depend on `locorda_builder`.
///
/// Run `dart run build_runner build` or use watch mode during development:
/// `dart run build_runner watch`
///
/// ## Convention over Configuration
///
/// - Worker generator discovers manifests automatically and generates `lib/worker_generated.g.dart`
/// - Worker source: `lib/worker.dart` (manual) or `lib/worker_generated.g.dart` (generated)
/// - Output: `web/worker.dart.js`
/// - No additional configuration needed for basic usage
///
/// **Note**: The generated file is named `worker_generated.g.dart` (not `worker.g.dart`)
/// to avoid build conflicts with source_gen:combining_builder when using manual `worker.dart`.
///
/// ## Web Assets
///
/// For web platform, you need to manually provide:
/// - `web/sqlite3.wasm` - SQLite WebAssembly module
/// - `web/drift_worker.js` - Drift's web worker
///
/// Download from:
/// - https://github.com/simolus3/sqlite3.dart/releases/latest
/// - https://github.com/simolus3/drift/releases/latest
library;

export 'src/web_worker_builder.dart';
export 'src/worker_generator_builder.dart';
