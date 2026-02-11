import 'dart:async';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
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

      // Step 3: Analyze Locorda.create parameters dynamically
      final locordaAnalysis = await _analyzeLocordaSource(buildStep);
      final locordaParams = locordaAnalysis.params;

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
        _log.fine(
            'Found ${detectedFrameworkParams.length} framework params: $detectedFrameworkParams');
      }

      additionalImports.addAll(locordaAnalysis.imports);

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

class _LocordaSourceAnalysis {
  final List<ParameterInfo> params;
  final Set<String> imports;

  const _LocordaSourceAnalysis({
    required this.params,
    required this.imports,
  });
}

Future<_LocordaSourceAnalysis> _analyzeLocordaSource(
    BuildStep buildStep) async {
  final assetId = AssetId('locorda_flutter', 'lib/src/locorda.dart');
  if (!await buildStep.canRead(assetId)) {
    throw StateError('locorda_flutter/lib/src/locorda.dart not found');
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

  final params = _extractLocordaCreateParameters(unit);

  return _LocordaSourceAnalysis(
    params: params,
    imports: imports,
  );
}

List<ParameterInfo> _extractLocordaCreateParameters(CompilationUnit unit) {
  for (final declaration in unit.declarations) {
    if (declaration is ClassDeclaration &&
        declaration.name.lexeme == 'Locorda') {
      for (final member in declaration.members) {
        if (member is MethodDeclaration && member.name.lexeme == 'create') {
          final params = member.parameters;
          if (params == null) {
            throw StateError('Locorda.create has no parameters');
          }
          return parseParameterList(params);
        }
      }
    }
  }

  throw StateError('Locorda.create method not found in locorda.dart');
}

/// Builder factory for build_runner integration.
Builder initLocordaBuilder(BuilderOptions options) =>
    InitLocordaBuilder(options);
