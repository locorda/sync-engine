# locorda_builder

Build-time transformations for Locorda applications - automates web worker compilation.

## Features

- **WorkerGeneratorBuilder**: Auto-generates `lib/worker_generated.g.dart` from discovered manifest files
- **WebWorkerBuilder**: Compiles workers to JavaScript:
  - Manual: `lib/worker.dart` → `web/worker.dart.js`
  - Generated: `lib/worker_generated.g.dart` → `web/worker_generated.dart.js`
- **Convention over Configuration**: Zero configuration needed for standard setup
- **Watch Mode Support**: Incremental rebuilds during development
- **Production Optimized**: Minified output with optional source maps

## Installation

**Recommended**: Add `locorda_dev` to your `dev_dependencies` - it aggregates all Locorda builders:

```yaml
dev_dependencies:
  locorda_dev: any       # Includes locorda_builder, RDF mapper generator, etc.
  build_runner: ^2.4.0   # Required to run the builders
```

> **Note**: `locorda_builder` is a low-level package that provides build_runner builders.
> It's automatically included when you depend on `locorda_dev`, which aggregates all
> builders typically needed for Locorda development (worker generation, RDF mapping, etc.).

## Usage

### Two Approaches

You can either:
1. **Manual worker**: Create custom `lib/worker.dart` with full control
2. **Generated worker**: Let builder auto-generate `lib/worker_generated.g.dart` from manifests

> **Why `worker_generated.g.dart`?** This naming avoids build conflicts with 
> `source_gen:combining_builder` which processes `worker.dart` → `worker.g.dart` 
> for other code generators.

### Basic Setup (Convention)

No configuration needed - the builder automatically discovers and processes your worker:

```bash
# One-time build
dart run build_runner build --delete-conflicting-outputs

# Watch mode (recommended for development)
dart run build_runner watch --delete-conflicting-outputs
```

This automatically:
1. Discovers manifest files across all packages (if using generated worker)
2. Generates `lib/worker_generated.g.dart` (only if no manual `lib/worker.dart` exists)
3. Compiles worker to JS:
   - Manual: `lib/worker.dart` → `web/worker.dart.js`
   - Generated: `lib/worker_generated.g.dart` → `web/worker_generated.dart.js`
4. Generates source maps for debugging
5. Rebuilds on changes

### Web Assets

For web deployment, you need to manually provide required assets:

```bash
# Download SQLite WASM and Drift worker
cd web
curl -L -o sqlite3.wasm https://github.com/simolus3/sqlite3.dart/releases/latest/download/sqlite3.wasm
curl -L -o drift_worker.js https://github.com/simolus3/drift/releases/latest/download/drift_worker.js
```

### Custom Configuration

Create `build.yaml` in your project root if you need custom settings:

```yaml
targets:
  $default:
    builders:
      locorda_builder|web_worker:
        enabled: true
```

### Integration with Locorda

After build completes, use the compiled worker:

```dart
import 'package:locorda/locorda.dart';

// For manual worker (lib/worker.dart)
final locorda = await Locorda.create(
  config: config,
  jsScript: 'worker.dart.js',  // Default
  // ...
);

// For generated worker (lib/worker_generated.g.dart)
final locorda = await Locorda.create(
  config: config,
  jsScript: 'worker_generated.dart.js',  // Generated worker output
  // ...
);
```

## Builder Details

### worker_generator

Auto-generates worker entry point by discovering manifest files across all packages.

**Input**: `pubspec.yaml` (triggers discovery)  
**Output**: `lib/worker_generated.g.dart` (only if no manual `lib/worker.dart` exists)

**Discovery process**:
1. Scans all package dependencies via `buildStep.packageConfig`
2. Finds `lib/locorda_worker.manifest.dart` in each package
3. Aggregates storage handlers, remote handlers, and mapping bootstrap
4. Generates complete worker with `main()` entry point

**Configuration** (optional in `build.yaml`):
```yaml
targets:
  $default:
    builders:
      locorda_builder|worker_generator:
        options:
          exclude_packages: []  # Skip specific packages
          on_worker_spawn_import: 'package:my_app/logging.dart'
          on_worker_spawn_function: 'setupLogging'
```

### web_worker

Compiles Dart worker to JavaScript with production optimizations.

**Inputs & Outputs** (mutually exclusive):
- Manual: `lib/worker.dart` → `web/worker.dart.js` + `.map`
- Generated: `lib/worker_generated.g.dart` → `web/worker_generated.dart.js` + `.map`

**Note**: Manual worker takes priority - if `lib/worker.dart` exists, `worker_generated.g.dart` is not generated.

**Optimizations**:
- Minified output
- Source maps for debugging
- Sound null safety
- Fast execution (omit implicit checks)
- Automatic platform detection

The builder uses `dart compile js` with production flags and ensures proper
integration with build_runner by compiling to a temporary directory first.

It also materializes same-package `*.g.dart` imports to the filesystem before
invoking the compiler. This avoids cache timing issues with external tools.

## Development Workflow

### Option A: Generated Worker (Default)
1. Add `locorda_dev` to dev_dependencies
2. Run `dart run build_runner watch`
3. Builder auto-discovers manifests from dependencies and generates `lib/worker_generated.g.dart`
4. Builder compiles to `web/worker_generated.dart.js`
5. No manual setup needed - manifests are provided by locorda packages

**Advanced**: Create custom manifests in `lib/locorda_worker.manifest.dart` to add your own storage/remote handlers

### Option B: Manual Worker (Full Control)
1. Create custom `lib/worker.dart`
2. Add `locorda_dev` to dev_dependencies
3. Run `dart run build_runner watch`
4. Builder compiles to `web/worker.dart.js`
5. Edit code - builder automatically rebuilds
6. Full control over worker setup

## Build Output

**Option A - Manual Worker:**
```
lib/
  worker.dart              # Your manual worker
web/
  worker.dart.js           # Compiled worker
  worker.dart.js.map       # Source map
  sqlite3.wasm             # SQLite WASM (manual download)
  drift_worker.js          # Drift worker (manual download)
```

**Option B - Generated Worker:**
```
lib/
  worker_generated.g.dart  # Auto-generated worker
web/
  worker_generated.dart.js # Compiled worker
  worker_generated.dart.js.map # Source map
  sqlite3.wasm             # SQLite WASM (manual download)
  drift_worker.js          # Drift worker (manual download)
```

⚠️ **Don't commit javascript build artifacts** - add to `.gitignore`:

```gitignore
# Generated Dart files - DO commit these
# lib/worker_generated.g.dart should be committed!

# Compiled JavaScript - DON'T commit (regenerated on each build)
web/worker.dart.js
web/worker.dart.js.map
web/worker_generated.dart.js
web/worker_generated.dart.js.map

# WASM assets - commit or download in CI/deployment
# Uncomment to ignore (requires download during deployment):
# web/sqlite3.wasm
# web/drift_worker.js
```

**Best Practice**: Commit `*.g.dart` files (generated Dart code) but ignore `*.js` 
build outputs (compile artifacts). This follows standard Dart/Flutter conventions.

## Troubleshooting

### Build collision: "outputs collide: worker.g.dart"

You have a manual `lib/worker.dart` and build_runner tries to generate `worker.g.dart`.
This is expected - our builder generates `worker_generated.g.dart` instead to avoid this.
If you see this error, check if you have stale build configs.

### Build fails with "Cannot find worker"

Ensure either:
- Manifest files exist in your dependencies (for generated worker), OR
- Manual worker exists: `lib/worker.dart`

### Worker compilation slow

First compile takes 5-10 seconds. Use watch mode for incremental rebuilds
which are much faster (< 1 second).

### Old worker still running

Clear browser cache or use hard reload (Cmd+Shift+R / Ctrl+Shift+R).

### Missing sqlite3.wasm or drift_worker.js

These assets must be manually downloaded. See "Web Assets" section above.

## Future Builders

This package is designed to host additional Locorda builders:

- **crdt_mapper**: Generate CRDT mapping code (planned)
- **schema_validator**: Validate RDF schemas at build time (planned)

## License

Apache 2.0
