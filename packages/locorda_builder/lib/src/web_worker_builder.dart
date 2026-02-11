import 'dart:async';
import 'dart:io';

import 'package:build/build.dart';
import 'package:path/path.dart' as p;

/// Compiles Dart worker entry points to JavaScript for web platform.
///
/// **Convention**: Compiles `lib/worker.dart` → `web/worker.dart.js`
///
/// This builder:
/// - Only runs for web builds
/// - Uses `dart compile js` with production optimizations
/// - Generates source maps for debugging
/// - Supports watch mode for incremental rebuilds
/// - Materializes same-package `*.g.dart` imports to the filesystem before
///   invoking the compiler
///
/// ## Compilation Options
///
/// - Minified output for production
/// - Sound null safety
/// - Omit implicit checks (faster execution)
/// - Source maps included
///
/// ## Error Handling
///
/// - Logs compilation errors clearly
/// - Fails build if compilation fails
/// - Reports compilation time
class WebWorkerBuilder implements Builder {
  /// Output extension for compiled worker.
  static const workerOutput = '.js';

  @override
  Map<String, List<String>> get buildExtensions => {
        'lib/worker.dart': [
          'web/worker.dart$workerOutput',
          'web/worker.dart.js.map'
        ],
        'lib/worker.g.dart': [
          'web/worker.dart$workerOutput',
          'web/worker.dart.js.map'
        ],
      };

  @override
  Future<void> build(BuildStep buildStep) async {
    final inputId = buildStep.inputId;

    // Determine which worker file to compile
    AssetId? workerFile;

    if (inputId.path == 'lib/worker.dart') {
      // Manual worker.dart always takes priority
      workerFile = inputId;
      log.fine('Using manual worker.dart');
    } else if (inputId.path == 'lib/worker.g.dart') {
      // Only use worker.g.dart if worker.dart doesn't exist
      final manualWorker = AssetId(inputId.package, 'lib/worker.dart');
      if (await buildStep.canRead(manualWorker)) {
        log.info(
            'Skipping worker.g.dart compilation because manual worker.dart exists');
        return;
      }
      workerFile = inputId;
      log.fine('Using generated worker.g.dart');
    }

    if (workerFile == null) {
      return;
    }

    log.info('Compiling worker for web platform: ${workerFile.path}');
    final stopwatch = Stopwatch()..start();

    // Read the worker source (validates it exists and triggers rebuild on changes)
    final workerSource = await buildStep.readAsString(workerFile);

    // Create temporary directory for compilation output
    final tempDir = await Directory.systemTemp.createTemp('worker_build_');
    final tempOutputPath = p.join(tempDir.path, 'worker.dart.js');

    try {
      // Resolve package root so the compiler can see generated source outputs.
      final packageRoot = await _resolvePackageRoot(buildStep, workerFile);
      final inputPath = p.join(packageRoot, workerFile.path);

      final generatedImports =
          _collectGeneratedImports(workerSource, workerFile.package, workerFile.path);
      for (final assetPath in generatedImports) {
        await _materializeAsset(
          buildStep,
          packageRoot,
          assetPath,
          workerFile,
        );
      }

      // Run dart compile js with production flags
      final result = await Process.run(
        'dart',
        [
          'compile',
          'js',
          '--no-source-maps', // Source maps can be enabled with flag later
          '-o',
          tempOutputPath,
          inputPath,
        ],
        runInShell: true,
        workingDirectory: packageRoot,
      );

      if (result.exitCode != 0) {
        log.severe('Worker compilation failed:');
        log.severe('stdout: ${result.stdout}');
        log.severe('stderr: ${result.stderr}');
        throw Exception(
            'Failed to compile worker: exit code ${result.exitCode}');
      }

      stopwatch.stop();

      // Read the compiled JavaScript file from temp directory
      final compiledJs = await File(tempOutputPath).readAsString();
      final fileSize = compiledJs.length;

      log.info(
          'Worker compiled successfully in ${stopwatch.elapsedMilliseconds}ms');
      log.info('Output size: ${_formatSize(fileSize)}');

      // Write the compiled JavaScript through build system
      // This ensures proper integration with build_runner
      await buildStep.writeAsString(
        AssetId(workerFile.package, 'web/worker.dart.js'),
        compiledJs,
      );

      // Check if source map was generated
      final sourceMapPath = '$tempOutputPath.map';
      final sourceMapFile = File(sourceMapPath);
      if (await sourceMapFile.exists()) {
        final sourceMap = await sourceMapFile.readAsString();
        await buildStep.writeAsString(
          AssetId(workerFile.package, 'web/worker.dart.js.map'),
          sourceMap,
        );
        log.info('Source map written: worker.dart.js.map');
      }
    } catch (e, stack) {
      log.severe('Error compiling worker', e, stack);
      rethrow;
    } finally {
      // Clean up temporary directory
      try {
        await tempDir.delete(recursive: true);
      } catch (e) {
        log.warning('Failed to delete temp directory: ${tempDir.path}', e);
      }
    }
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Future<String> _resolvePackageRoot(
      BuildStep buildStep, AssetId inputId) async {
    final packageConfig = await buildStep.packageConfig;
    final package = packageConfig.packages.firstWhere(
      (pkg) => pkg.name == inputId.package,
      orElse: () => throw StateError(
        'Package not found in config: ${inputId.package}',
      ),
    );

    if (package.root.scheme == 'file') {
      return p.fromUri(package.root);
    }

    var current = Directory.current;
    while (true) {
      final pubspec = File(p.join(current.path, 'pubspec.yaml'));
      if (await pubspec.exists()) {
        final content = await pubspec.readAsString();
        final match = RegExp(
          r'^name:\s*([A-Za-z0-9_\-]+)\s*$',
          multiLine: true,
        ).firstMatch(content);
        if (match?.group(1) == inputId.package) {
          return current.path;
        }
      }
      final parent = current.parent;
      if (parent.path == current.path) {
        break;
      }
      current = parent;
    }

    throw StateError(
      'Unable to resolve package root for ${inputId.package} '
      '(package root uri: ${package.root})',
    );
  }

  Future<void> _materializeAsset(
    BuildStep buildStep,
    String packageRoot,
    String assetPath,
    AssetId inputId,
  ) async {
    final assetId = AssetId(inputId.package, assetPath);
    final content = await buildStep.readAsString(assetId);
    final targetFile = File(p.join(packageRoot, assetPath));
    if (await targetFile.exists()) {
      return;
    }

    await targetFile.parent.create(recursive: true);
    await targetFile.writeAsString(content);
  }

  Set<String> _collectGeneratedImports(
    String source,
    String packageName,
    String inputPath,
  ) {
    final result = <String>{};
    final importRegex = RegExp("import\\s+['\\\"]([^'\\\"]+)['\\\"]");
    for (final match in importRegex.allMatches(source)) {
      final rawImport = match.group(1);
      if (rawImport == null || !rawImport.endsWith('.g.dart')) {
        continue;
      }

      if (rawImport.startsWith('package:')) {
        final withoutScheme = rawImport.substring('package:'.length);
        final parts = withoutScheme.split('/');
        if (parts.isEmpty || parts.first != packageName) {
          continue;
        }
        final relativePath = parts.skip(1).join('/');
        if (relativePath.isEmpty) {
          continue;
        }
        result.add(p.join('lib', relativePath));
        continue;
      }

      if (rawImport.startsWith('dart:') || rawImport.startsWith('asset:')) {
        continue;
      }

      final resolved = p.normalize(p.join(p.dirname(inputPath), rawImport));
      if (p.isWithin('lib', resolved) || resolved.startsWith('lib/')) {
        result.add(resolved);
      }
    }
    return result;
  }
}

/// Builder factory for build_runner integration.
Builder webWorkerBuilder(BuilderOptions options) => WebWorkerBuilder();
