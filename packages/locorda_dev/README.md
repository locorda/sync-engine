# locorda_dev

Unified development tooling for Locorda applications. Add this single package as a `dev_dependency` to activate all Locorda build-time code generators and deployment tools.

## Features

- 🔧 **Automatic CRDT Mapping Generation** - Generate merge strategy documents from annotations
- 📦 **Bootstrap Aggregation** - Embed mappings for offline-first cold start
- 🌐 **Web Worker Compilation** - Build worker isolates for web platform
- 🗺️ **RDF Mapper Generation** - Dart ↔ RDF serialization code
- 🚀 **Deployment Tool** - Split and deploy CRDT mappings to CDN/server

## Installation

```bash
# For Dart projects
dart pub add dev:build_runner dev:locorda_dev

# For Flutter projects
flutter pub add dev:build_runner dev:locorda_dev
```

## Usage

### 1. Code Generation (build_runner)

The `locorda_dev` package automatically activates all Locorda builders when you run `build_runner`:

```bash
# Development mode with watch
dart run build_runner watch

# One-time build
dart run build_runner build

# Clean build (removes cached artifacts)
dart run build_runner build --delete-conflicting-outputs
```

**What gets generated:**

- `lib/**/*.crdt.cache.trig` - CRDT mapping documents (build cache)
- `lib/src/generated/mapping_bootstrap.g.dart` - Embedded mappings list
- `lib/**/*.rdf_mapper.g.dart` - RDF serialization code
- `lib/init_locorda.g.dart` - Convenience initialization
- `lib/locorda_config.g.dart` - Resource configuration
- `web/worker.dart.js` - Web worker bundle (for Flutter web apps)

### 2. Deploying CRDT Mappings

After code generation, deploy your CRDT mapping documents to make them accessible at their canonical URIs:

```bash
# Deploy to local directory
dart run locorda_dev:deploy_mappings dist/mappings/

# Then upload to your CDN/server
aws s3 sync dist/mappings/ s3://myapp.example.com/mappings/ --acl public-read
# or
rsync -av dist/mappings/ user@server.com:/var/www/mappings/
```

**Why deploy?**
- Makes mappings discoverable by other apps
- Enables cross-app collaboration with shared merge strategies
- Allows HTTP access for validation and debugging

**Output format:**
```
dist/mappings/
├── note-v1.ttl
├── category-v1.ttl
└── core-v1.ttl
```

Each file contains a single CRDT mapping document in Turtle format, ready to serve at its canonical IRI.

**Important:** Each mapping IRI must produce a unique filename. If two different IRIs would produce the same filename (e.g., `https://a.com/note-v1#` and `https://b.com/note-v1#` both produce `note-v1.ttl`), deployment will fail. This ensures the IRI→URL mapping remains valid.

### 3. Custom Bootstrap File Location

If your bootstrap file is not at the default location:

```bash
dart run locorda_dev:deploy_mappings dist/mappings/ lib/custom/bootstrap.g.dart
```

## Common Workflows

### Initial Setup

```bash
# 1. Add dev dependency
flutter pub add dev:locorda_dev dev:build_runner

# 2. Annotate your models
# (See locorda_annotations documentation)

# 3. Generate code
dart run build_runner build

# 4. Deploy mappings (production)
dart run locorda_dev:deploy_mappings dist/mappings/
```

### Development Cycle

```bash
# Keep watch running during development
dart run build_runner watch

# In another terminal, run your app
flutter run
```

### CI/CD Pipeline

```yaml
# .github/workflows/deploy.yml
- name: Generate code
  run: dart run build_runner build --delete-conflicting-outputs

- name: Deploy CRDT mappings
  run: |
    dart run locorda_dev:deploy_mappings dist/mappings/
    aws s3 sync dist/mappings/ s3://${{ secrets.BUCKET }}/mappings/
```

## Builders Included

`locorda_dev` applies these builders via `applies_builders`:

### crdt_mapping_generator
Generates CRDT mapping documents from `@LcrdRootResource` annotations with `@CrdtLwwRegister`, `@CrdtOrSet`, `@CrdtImmutable` on properties.

**Input:** `lib/**/*.dart` with annotated classes  
**Output:** `lib/**/*.crdt.cache.trig` (build cache)

### mapping_bootstrap
Aggregates generated CRDT mappings and manual assets into a single `List<String>` constant for offline-first bootstrap.

**Input:** Cache files + `assets/contracts/mappings/**/*.ttl`  
**Output:** `lib/src/generated/mapping_bootstrap.g.dart`

### rdf_mapper_generator
Generates Dart ↔ RDF serialization code from RDF mapping annotations.

**Input:** `lib/**/*.dart` with `@RdfProperty` annotations  
**Output:** `lib/**/*.rdf_mapper.g.dart`, `lib/init_rdf_mapper.g.dart`

### web_worker
Compiles worker isolate to JavaScript for web platform.

**Input:** `lib/worker.dart`  
**Output:** `web/worker.dart.js`

### init_locorda_generator
Generates convenience initialization wrapper with discovered resources.

**Input:** `pubspec.yaml`  
**Output:** `lib/init_locorda.g.dart`

### locorda_config_generator
Extracts resource configuration from annotations for sync setup.

**Input:** `pubspec.yaml` + annotated classes  
**Output:** `lib/locorda_config.g.dart`

## Configuration

### Custom Mapping Asset Locations

Add `build.yaml` to your project root:

```yaml
targets:
  $default:
    builders:
      locorda_mapping_bootstrap_generator:mapping_bootstrap:
        options:
          mapping_roots:
            - assets/contracts/mappings  # Default
            - assets/custom/rdf          # Additional location
```

### Disable Specific Builders

```yaml
targets:
  $default:
    builders:
      locorda_dev:locorda_dev:
        enabled: false  # Disables all locorda_dev builders
```

## Troubleshooting

### Build Fails with "No suitable constructor found"

Clean build cache and regenerate:
```bash
dart run build_runner clean
dart run build_runner build --delete-conflicting-outputs
```

### Generated Files Not Updating

Ensure watch mode is running or force full rebuild:
```bash
dart run build_runner build --delete-conflicting-outputs
```

### Empty bootstrapMappings List

1. Check that `@LcrdRootResource` has `crdt.generate == true` (default)
2. Verify CRDT annotations exist on properties
3. Clean and rebuild
4. Check `lib/**/*.crdt.cache.trig` files exist in `.dart_tool/build/`

### Deploy Tool Shows "Bootstrap file not found"

Ensure you've run `build_runner` first:
```bash
dart run build_runner build
dart run locorda_dev:deploy_mappings dist/mappings/
```

### Filename Collision Error

If deployment fails with "Filename collision detected":

1. Two different mapping IRIs are producing the same filename
2. This breaks the IRI→URL principle - fix your mapping IRIs
3. Use more specific path segments:
   ```dart
   // Bad: Both produce note-v1.ttl
   LcrdCrdt('https://app-a.com/mappings/note-v1#')
   LcrdCrdt('https://app-b.com/mappings/note-v1#')
   
   // Good: Unique filenames
   LcrdCrdt('https://app-a.com/mappings/app-a-note-v1#')  // app-a-note-v1.ttl
   LcrdCrdt('https://app-b.com/mappings/app-b-note-v1#')  // app-b-note-v1.ttl
   ```

### CRDT Mappings Not Generating

Check your annotations:
```dart
@LcrdRootResource(
  IriTerm('https://schema.org/Note'),
  LcrdCrdt('https://myapp.example.com/mappings/note-v1#'),  // Must have this
)
class Note {
  @RdfProperty(Schema.name)
  @CrdtLwwRegister()  // CRDT annotation required
  String? title;
}
```

## Package Structure

```
locorda_dev/
├── bin/
│   └── deploy_mappings.dart    # CLI tool for deployment
├── lib/
│   ├── builder.dart             # Meta-builder (applies other builders)
│   └── locorda_dev.dart         # Package documentation
└── test/
    └── deploy_mappings_test.dart
```

## See Also

- [locorda_annotations](../locorda_annotations/README.md) - Annotation reference
- [locorda_init_generator](../locorda_init_generator/README.md) - Generator implementation
- [Concept: CRDT Mapping Generation](../../proposed-changes/020-crdt-mapping-generation.md)
- [Example: personal_notes_app](../locorda/example/personal_notes_app/) - Complete example

## License

See [LICENSE](../../LICENSE) in the repository root.
