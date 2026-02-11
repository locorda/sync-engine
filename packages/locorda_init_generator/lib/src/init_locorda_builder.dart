import 'dart:async';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:build/build.dart';
import 'package:logging/logging.dart';

import 'code_generator.dart';
import 'locorda_params.dart';
import 'mapper_analyzer.dart';
import 'parameter_info.dart';

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

      // Step 3: Get Locorda.create parameters (hardcoded for now)
      final locordaParams = getLocordaCreateParameters();

      // Step 4: Analyze initRdfMapper signature (if exists)
      List<ParameterInfo> mapperParams = [];
      Set<String> detectedFrameworkParams = {};
      final additionalImports = <String>{};

      if (hasInitMapper) {
        final mapperAnalyzer = MapperAnalyzer(buildStep, inputId.package);
        final result = await mapperAnalyzer.analyzeInitRdfMapper();
        mapperParams = result.customParams;
        detectedFrameworkParams = result.frameworkParams;
        additionalImports.addAll(result.imports);
        _log.fine('Found ${mapperParams.length} custom mapper params');
        _log.fine('Found ${detectedFrameworkParams.length} framework params: $detectedFrameworkParams');
      }

      additionalImports.addAll(
        await _collectImportsFromLocordaSource(buildStep),
      );

      // Step 5: Generate code
      final generator = CodeGenerator(
        hasGeneratedWorker: hasGeneratedWorker,
        hasInitMapper: hasInitMapper,
        locordaParams: locordaParams,
        mapperParams: mapperParams,
        detectedFrameworkParams: detectedFrameworkParams,
        additionalImports: additionalImports,
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

Future<Set<String>> _collectImportsFromLocordaSource(BuildStep buildStep) async {
  final assetId = AssetId('locorda_flutter', 'lib/src/locorda.dart');
  if (!await buildStep.canRead(assetId)) {
    return {};
  }

  final content = await buildStep.readAsString(assetId);
  final parseResult = parseString(content: content);
  final unit = parseResult.unit;

  final imports = <String>{};
  for (final directive in unit.directives) {
    if (directive is ImportDirective) {
      imports.add(directive.toSource());
    }
  }

  return imports;
}

/// Builder factory for build_runner integration.
Builder initLocordaBuilder(BuilderOptions options) =>
    InitLocordaBuilder(options);
