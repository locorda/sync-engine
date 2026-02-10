import 'dart:async';

import 'package:build/build.dart';
import 'package:path/path.dart' as p;

/// Generates worker.g.dart by discovering and aggregating manifest files.
///
/// This builder:
/// - Triggers on `pubspec.yaml` (like mapping_bootstrap)
/// - Discovers manifest files across all packages using `buildStep.packageConfig`
/// - Filters packages based on `exclude_packages` option
/// - Conditionally imports `mapping_bootstrap.g.dart` if it exists
/// - Supports optional `onWorkerSpawn` callback configuration
/// - Generates complete executable worker with `main()` entry point
///
/// ## Configuration
///
/// ```yaml
/// targets:
///   $default:
///     builders:
///       locorda_builder|worker_generator:
///         options:
///           # Packages to exclude from manifest discovery
///           exclude_packages: []
///           # Custom manifest file paths (for non-standard locations)
///           manifest_files: ['lib/locorda_worker.manifest.dart']
///           # Optional: Import path for onWorkerSpawn callback
///           on_worker_spawn_import: null
///           # Optional: Function name for onWorkerSpawn callback
///           on_worker_spawn_function: null
/// ```
class WorkerGeneratorBuilder implements Builder {
  final BuilderOptions options;

  WorkerGeneratorBuilder(this.options);

  @override
  Map<String, List<String>> get buildExtensions => {
        'pubspec.yaml': ['lib/worker.g.dart'],
      };

  @override
  Future<void> build(BuildStep buildStep) async {
    final inputId = buildStep.inputId;

    // Only process pubspec.yaml
    if (inputId.path != 'pubspec.yaml') {
      return;
    }

    log.info('Generating worker.g.dart for package: ${inputId.package}');

    // Read configuration options
    final excludePackages = (options.config['exclude_packages'] as List<dynamic>?)
            ?.cast<String>()
            .toSet() ??
        <String>{};
    final manifestFiles = (options.config['manifest_files'] as List<dynamic>?)
            ?.cast<String>() ??
        ['lib/locorda_worker.manifest.dart'];
    final onWorkerSpawnImport = options.config['on_worker_spawn_import'] as String?;
    final onWorkerSpawnFunction =
        options.config['on_worker_spawn_function'] as String?;

    // Discover manifests across all packages
    final manifests = await _discoverManifests(
      buildStep,
      manifestFiles,
      excludePackages,
    );

    // Check if mapping_bootstrap.g.dart exists
    final hasMappingBootstrap = await buildStep.canRead(
      AssetId(inputId.package, 'lib/src/generated/mapping_bootstrap.g.dart'),
    );

    // Generate the worker.g.dart file
    final generatedCode = _generateWorkerCode(
      manifests,
      hasMappingBootstrap,
      onWorkerSpawnImport,
      onWorkerSpawnFunction,
    );

    // Write the generated file
    final outputId = AssetId(inputId.package, 'lib/worker.g.dart');
    await buildStep.writeAsString(outputId, generatedCode);

    log.info('Generated worker.g.dart with ${manifests.length} manifest(s)');
  }

  /// Discovers manifest files across all packages.
  ///
  /// Uses `buildStep.packageConfig` to list all packages, then checks for
  /// manifest files in each package using `buildStep.canRead()`.
  Future<List<ManifestInfo>> _discoverManifests(
    BuildStep buildStep,
    List<String> manifestFiles,
    Set<String> excludePackages,
  ) async {
    final manifests = <ManifestInfo>[];
    final packageConfig = await buildStep.packageConfig;

    for (final package in packageConfig.packages) {
      // Skip excluded packages
      if (excludePackages.contains(package.name)) {
        log.fine('Skipping excluded package: ${package.name}');
        continue;
      }

      // Check each configured manifest file path
      for (final manifestPath in manifestFiles) {
        final assetId = AssetId(package.name, manifestPath);
        if (await buildStep.canRead(assetId)) {
          log.fine('Found manifest: ${package.name}/$manifestPath');
          manifests.add(ManifestInfo(
            packageName: package.name,
            manifestPath: manifestPath,
          ));
          break; // Only use the first found manifest per package
        }
      }
    }

    return manifests;
  }

  /// Generates the worker.g.dart file content.
  String _generateWorkerCode(
    List<ManifestInfo> manifests,
    bool hasMappingBootstrap,
    String? onWorkerSpawnImport,
    String? onWorkerSpawnFunction,
  ) {
    final buffer = StringBuffer();

    // Header
    buffer.writeln('// GENERATED CODE - DO NOT MODIFY BY HAND');
    buffer.writeln();

    // Generate imports for manifests
    for (final manifest in manifests) {
      final alias = _sanitizePackageName(manifest.packageName);
      final importPath = manifest.manifestPath;
      buffer.writeln(
          "import 'package:${manifest.packageName}/$importPath' as $alias;");
    }

    // Import locorda_worker
    buffer.writeln("import 'package:locorda_worker/worker.dart';");

    // Conditionally import mapping_bootstrap
    if (hasMappingBootstrap) {
      buffer.writeln("import 'src/generated/mapping_bootstrap.g.dart';");
    }

    // Conditionally import onWorkerSpawn callback
    if (onWorkerSpawnImport != null && onWorkerSpawnFunction != null) {
      buffer.writeln("import '$onWorkerSpawnImport' show $onWorkerSpawnFunction;");
    }

    buffer.writeln();

    // Generate main() function
    buffer.writeln('/// Worker entry point for web workers.');
    buffer.writeln('///');
    buffer.writeln(
        '/// On web, the compiled JS is loaded and main() is called automatically.');
    buffer.writeln('void main() {');
    if (onWorkerSpawnFunction != null) {
      buffer.writeln(
          '  workerMain(generatedWorkerSetup, onWorkerSpawn: $onWorkerSpawnFunction);');
    } else {
      buffer.writeln('  workerMain(generatedWorkerSetup);');
    }
    buffer.writeln('}');
    buffer.writeln();

    // Generate generatedWorkerSetup() function
    buffer.writeln('/// Generated worker setup that registers all discovered adapters.');
    buffer.writeln('///');
    buffer.writeln(
        '/// Active handlers are selected at runtime based on IDs received from main.');
    buffer.writeln('///');
    buffer.writeln(
        '/// This function is public so main-side code can import and pass it to');
    buffer.writeln(
        '/// Locorda.create(workerSetup: generatedWorkerSetup) for isolate spawning.');
    buffer.writeln('Future<WorkerParams> generatedWorkerSetup() async => WorkerParams(');

    // Generate storages list
    buffer.writeln('  storages: [');
    for (final manifest in manifests) {
      final alias = _sanitizePackageName(manifest.packageName);
      buffer.writeln('    ...$alias.storages,');
    }
    buffer.writeln('  ],');

    // Generate remotes list
    buffer.writeln('  remotes: [');
    for (final manifest in manifests) {
      final alias = _sanitizePackageName(manifest.packageName);
      buffer.writeln('    ...$alias.remotes,');
    }
    buffer.writeln('  ],');

    // Generate mappingBootstrapSources
    if (hasMappingBootstrap) {
      buffer.writeln('  mappingBootstrapSources: bootstrapMappings,');
    } else {
      buffer.writeln('  mappingBootstrapSources: [],');
    }

    buffer.writeln(');');

    return buffer.toString();
  }

  /// Sanitizes package names for use as Dart identifiers.
  ///
  /// Replaces hyphens with underscores to create valid Dart identifiers.
  String _sanitizePackageName(String packageName) {
    return packageName.replaceAll('-', '_');
  }
}

/// Information about a discovered manifest file.
class ManifestInfo {
  final String packageName;
  final String manifestPath;

  ManifestInfo({
    required this.packageName,
    required this.manifestPath,
  });
}

/// Builder factory for build_runner integration.
Builder workerGeneratorBuilder(BuilderOptions options) =>
    WorkerGeneratorBuilder(options);
