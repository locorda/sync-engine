# locorda_builder

Build-time transformations for Locorda applications - automates web worker compilation.

## Features

- **WebWorkerBuilder**: Automatically compiles `lib/worker.dart` to `web/worker.dart.js` for web platform
- **Convention over Configuration**: Zero configuration needed for standard setup
- **Watch Mode Support**: Incremental rebuilds during development
- **Production Optimized**: Minified output with optional source maps

## Installation

Add to your `dev_dependencies`:

```yaml
dev_dependencies:
  locorda_builder: ^0.1.0
  build_runner: ^2.4.0
```

## Usage

### Basic Setup (Convention)

If your worker entry point is at `lib/worker.dart`, no configuration needed:

```bash
# One-time build
dart run build_runner build --delete-conflicting-outputs

# Watch mode (recommended for development)
dart run build_runner watch --delete-conflicting-outputs
```

This automatically:
1. Compiles `lib/worker.dart` → `web/worker.dart.js`
2. Generates source maps for debugging
3. Rebuilds on changes

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

final locorda = await Locorda.createWithWorker(
  config: config,
  // Defaults to 'worker.dart.js' - no need to specify
  jsScript: 'worker.dart.js',
);
```

## Builder Details

### web_worker

Compiles Dart worker to JavaScript with production optimizations:

- Minified output
- Source maps for debugging
- Sound null safety
- Fast execution (omit implicit checks)
- Automatic platform detection

**Input**: `lib/worker.dart`  
**Output**: `web/worker.dart.js`, `web/worker.dart.js.map`

The builder uses `dart compile js` with production flags and ensures proper
integration with build_runner by compiling to a temporary directory first.

It also materializes same-package `*.g.dart` imports referenced by
`lib/worker.dart` to the filesystem before invoking the compiler. This avoids
cache timing issues with external filesystem tools.

## Development Workflow

1. Create your worker entry point: `lib/worker.dart`
2. Add `locorda_builder` to dev_dependencies
3. Run `dart run build_runner watch`
4. Edit code - builder automatically rebuilds
5. No manual `dart compile js` needed!

## Build Output

```
web/
  worker.dart.js          # Compiled worker (auto-generated)
  worker.dart.js.map      # Source map for debugging
  sqlite3.wasm            # SQLite WASM (manual download)
  drift_worker.js         # Drift worker (manual download)
```

⚠️ **Don't commit generated files** - add to `.gitignore`:

```gitignore
# Build outputs
web/worker.dart.js
web/worker.dart.js.map

# Optional: Don't commit WASM assets (can be large)
# web/*.wasm
# web/drift_worker.js
```

## Troubleshooting

### Build fails with "Cannot find worker.dart"

Ensure `lib/worker.dart` exists in your project.

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
