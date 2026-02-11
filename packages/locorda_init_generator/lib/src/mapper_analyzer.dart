import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:build/build.dart';
import 'package:logging/logging.dart';

import 'parameter_info.dart';

final _log = Logger('MapperAnalyzer');

/// Analyzes initRdfMapper signature to extract custom parameters.
class MapperAnalyzer {
  final BuildStep buildStep;
  final String packageName;

  MapperAnalyzer(this.buildStep, this.packageName);

  /// Analyze initRdfMapper function and extract custom parameters.
  Future<MapperAnalysisResult> analyzeInitRdfMapper() async {
    final assetId = AssetId(packageName, 'lib/init_rdf_mapper.g.dart');
    
    if (!await buildStep.canRead(assetId)) {
      _log.fine('init_rdf_mapper.g.dart not found, returning empty result');
      return const MapperAnalysisResult(
        customParams: [],
        frameworkParams: {},
        imports: {},
      );
    }

    final content = await buildStep.readAsString(assetId);
    
    try {
      return _parseInitRdfMapper(content);
    } catch (e) {
      _log.warning('Failed to parse init_rdf_mapper.g.dart: $e');
      return const MapperAnalysisResult(
        customParams: [],
        frameworkParams: {},
        imports: {},
      );
    }
  }

  MapperAnalysisResult _parseInitRdfMapper(String content) {
    final parseResult = parseString(content: content);
    final unit = parseResult.unit;

    // Find initRdfMapper function
    FunctionDeclaration? initRdfMapperFunc;
    for (final declaration in unit.declarations) {
      if (declaration is FunctionDeclaration &&
          declaration.name.lexeme == 'initRdfMapper') {
        initRdfMapperFunc = declaration;
        break;
      }
    }

    if (initRdfMapperFunc == null) {
      _log.warning('initRdfMapper function not found in init_rdf_mapper.g.dart');
      return const MapperAnalysisResult(
        customParams: [],
        frameworkParams: {},
        imports: {},
      );
    }

    final customParams = <ParameterInfo>[];
    final frameworkParams = <String>{};
    final imports = <String>{};

    for (final directive in unit.directives) {
      if (directive is ImportDirective) {
        imports.add(directive.toSource());
      }
    }

    final parameters = initRdfMapperFunc.functionExpression.parameters;
    if (parameters != null) {
      for (final param in parameters.parameters) {
        if (param is DefaultFormalParameter) {
          final normalParam = param.parameter;
          if (normalParam is SimpleFormalParameter) {
            final paramName = normalParam.name?.lexeme ?? '';
            
            // Skip framework parameters
            if (paramName == 'rdfMapper' || paramName.startsWith(r'$')) {
              if (paramName.startsWith(r'$')) {
                frameworkParams.add(paramName);
              }
              continue;
            }
            
            // Extract custom parameter
            final paramType = normalParam.type?.toSource() ?? 'dynamic';
            final isRequired = param.isRequired;
            
            customParams.add(ParameterInfo(
              name: paramName,
              type: paramType,
              isRequired: isRequired,
              isNamed: true,
              defaultValue: param.defaultValue?.toSource(),
            ));
          }
        }
      }
    }

    return MapperAnalysisResult(
      customParams: customParams,
      frameworkParams: frameworkParams,
      imports: imports,
    );
  }
}
