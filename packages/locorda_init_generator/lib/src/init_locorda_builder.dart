import 'dart:async';

import 'package:analyzer/dart/element/element.dart';
import 'package:build/build.dart';
import 'package:logging/logging.dart';

import 'code_generator.dart';
import 'mapper_analyzer.dart';
import 'parameter_info.dart';
import 'parameter_parser.dart';

final _log = Logger('InitLocordaBuilder');

/// Builder that generates lib/init_locorda.g.dart
///
/// This builder:
/// - Triggers on pubspec.yaml (similar to worker_generator)
/// - Detects presence of worker_generated.g.dart
/// - Detects presence of init_rdf_mapper.g.dart
/// - Analyzes signatures and generates convenience wrapper
class InitLocordaBuilder implements Builder {
  final BuilderOptions options;

  InitLocordaBuilder(this.options);

  @override
  Map<String, List<String>> get buildExtensions => {
        'pubspec.yaml': ['lib/init_locorda.g.dart'],
      };

  @override
  Future<void> build(BuildStep buildStep) async {
    final inputId = buildStep.inputId;

    // Only process pubspec.yaml
    if (inputId.path != 'pubspec.yaml') {
      return;
    }

    _log.info('Generating init_locorda.g.dart for package: ${inputId.package}');

    try {
      // Step 1: Detect worker_generated.g.dart
      final hasGeneratedWorker = await buildStep.canRead(
        AssetId(inputId.package, 'lib/worker_generated.g.dart'),
      );
      _log.fine('Has worker_generated.g.dart: $hasGeneratedWorker');

      // Step 2: Detect init_rdf_mapper.g.dart
      final hasInitMapper = await buildStep.canRead(
        AssetId(inputId.package, 'lib/init_rdf_mapper.g.dart'),
      );
      _log.fine('Has init_rdf_mapper.g.dart: $hasInitMapper');

      // Step 2b: Detect locorda_config.g.dart
      final hasGeneratedConfig = await buildStep.canRead(
        AssetId(inputId.package, 'lib/locorda_config.g.dart'),
      );
      _log.fine('Has locorda_config.g.dart: $hasGeneratedConfig');

      // Step 3: Analyze Locorda.create parameters dynamically
      final locordaAnalysis = await _analyzeLocordaSource(buildStep);
      final locordaParams = locordaAnalysis.params;

      // Step 4: Analyze initRdfMapper signature (if exists)
      List<ParameterInfo> mapperParams = [];
      Set<String> detectedFrameworkParams = {};

      if (hasInitMapper) {
        final mapperAnalyzer = MapperAnalyzer(buildStep, inputId.package);
        final result = await mapperAnalyzer.analyzeInitRdfMapper();
        mapperParams = result.customParams;
        detectedFrameworkParams = result.frameworkParams;
        _log.fine('Found ${mapperParams.length} custom mapper params');
        _log.fine(
            'Found ${detectedFrameworkParams.length} framework params: $detectedFrameworkParams');
      }

      // Step 5: Generate code
      final generator = CodeGenerator(
        hasGeneratedWorker: hasGeneratedWorker,
        hasInitMapper: hasInitMapper,
        hasGeneratedConfig: hasGeneratedConfig,
        locordaParams: locordaParams,
        mapperParams: mapperParams,
        detectedFrameworkParams: detectedFrameworkParams,
      );

      final generatedCode = generator.generate();

      // Step 6: Write output
      final outputId = AssetId(inputId.package, 'lib/init_locorda.g.dart');
      await buildStep.writeAsString(outputId, generatedCode);

      _log.info('Generated init_locorda.g.dart successfully');
    } catch (e, stackTrace) {
      _log.severe('Failed to generate init_locorda.g.dart: $e', e, stackTrace);
      rethrow;
    }
  }
}

class _LocordaSourceAnalysis {
  final List<ParameterInfo> params;

  const _LocordaSourceAnalysis({
    required this.params,
  });
}

Future<_LocordaSourceAnalysis> _analyzeLocordaSource(
    BuildStep buildStep) async {
  final assetId = AssetId('locorda_flutter', 'lib/src/locorda.dart');
  if (!await buildStep.canRead(assetId)) {
    throw StateError('locorda_flutter/lib/src/locorda.dart not found');
  }

  final library = await buildStep.resolver.libraryFor(assetId);
  final params = _extractLocordaCreateParameters(library);

  return _LocordaSourceAnalysis(
    params: params,
  );
}

List<ParameterInfo> _extractLocordaCreateParameters(LibraryElement library) {
  final locordaClass = library.classes
      .where((element) => element.displayName == 'Locorda')
      .firstOrNull;

  if (locordaClass == null) {
    throw StateError('Locorda class not found in locorda.dart');
  }

  final createMethod = locordaClass.methods
      .where((method) => method.displayName == 'create' && method.isStatic)
      .firstOrNull;

  if (createMethod == null) {
    throw StateError('Locorda.create method not found in locorda.dart');
  }

  return parseParameterElements(createMethod.formalParameters);
}

/// Builder factory for build_runner integration.
Builder initLocordaBuilder(BuilderOptions options) =>
    InitLocordaBuilder(options);

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
