import 'code_generation/code.dart';
import 'code_generation/dart_formatter.dart';
import 'parameter_info.dart';

const _locordaFlutterImport = 'package:locorda_flutter/locorda_flutter.dart';
const _workerGeneratedImport = 'worker_generated.g.dart';
const _initRdfMapperImport = 'init_rdf_mapper.g.dart';
const _locordaConfigImport = 'locorda_config.g.dart';

Code locordaFlutter(String name) => imported(name, _locordaFlutterImport);

Code imported(String name, String importUri) =>
    Code.type(name, importUri: importUri);

/// Generates the initLocorda.g.dart file.
class CodeGenerator {
  final bool hasGeneratedWorker;
  final bool hasInitMapper;
  final bool hasGeneratedConfig;
  final List<ParameterInfo> locordaParams;
  final List<ParameterInfo> mapperParams;
  final Set<String> detectedFrameworkParams;

  final CodeFormatter _formatter;

  CodeGenerator({
    required this.hasGeneratedWorker,
    required this.hasInitMapper,
    required this.hasGeneratedConfig,
    required this.locordaParams,
    required this.mapperParams,
    required this.detectedFrameworkParams,
    CodeFormatter? formatter,
  }) : _formatter = formatter ?? DartCodeFormatter();

  /// Generate the complete initLocorda.g.dart content.
  String generate() => _formatter.formatCode(
        CodeResolver.toDartFileContent(
          '''
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: unused_import, depend_on_referenced_packages, unnecessary_import, implementation_imports

/// Convenience wrapper for Locorda.create with auto-detected settings.
///
/// Auto-configures:
${[
            if (hasGeneratedWorker) ...[
              '/// - workerSetup: generatedWorkerSetup (from worker_generated.g.dart)',
              "/// - jsScript: 'worker_generated.dart.js'"
            ],
            if (hasInitMapper)
              '/// - mapperInitializer: Generated from initRdfMapper',
            if (hasGeneratedConfig)
              '/// - config: Generated from annotations via generateLocordaConfig()',
          ].join('\n')}

library;
''',
          {
            _locordaFlutterImport: '',
            if (hasGeneratedWorker) _workerGeneratedImport: 'wrk',
            if (hasInitMapper) _initRdfMapperImport: 'mpr',
            if (hasGeneratedConfig) _locordaConfigImport: 'cfg',
          },
          _newInitLocordaFunction(),
        ),
      );

  Code _newInitLocordaFunction() =>
      core('Future').withGenericParams([locordaFlutter('Locorda')]) +
      Code.combine(
        pre: 'initLocorda ({',
        [...mapperParams, ..._filterLocordaParams()].map(_parameterInfoToCode),
        separator: ',',
        post: '}) async => ',
      ) +
      locordaFlutter('Locorda').call('create', {
        if (hasGeneratedWorker) ...{
          'workerSetup':
              imported('generatedWorkerSetup', _workerGeneratedImport),
          'jsScript': Code.value("'worker_generated.dart.js'"),
        },
        if (hasInitMapper)
          'mapperInitializer': Code.literal('(context) => ') +
              imported('initRdfMapper', _initRdfMapperImport).newInstance({
                'rdfMapper': Code.value('context.baseRdfMapper'),
                for (final frameworkParam in detectedFrameworkParams)
                  frameworkParam:
                      Code.value('context.${frameworkParam.substring(1)}'),
                for (final param in mapperParams)
                  param.name: Code.value(param.name),
              }),
        if (hasGeneratedConfig)
          'config': imported('generateLocordaConfig', _locordaConfigImport)
              .newInstance(),
        for (final param in _filterLocordaParams())
          param.name: Code.value(param.name),
      }) +
      ';';

  List<ParameterInfo> _filterLocordaParams() {
    return locordaParams.where((param) {
      // Remove auto-configured params
      if (hasGeneratedWorker &&
          (param.name == 'workerSetup' || param.name == 'jsScript')) {
        return false;
      }
      if (hasInitMapper && param.name == 'mapperInitializer') {
        return false;
      }
      if (hasGeneratedConfig && param.name == 'config') {
        return false;
      }
      return true;
    }).toList();
  }

  Code _parameterInfoToCode(ParameterInfo param) => Code.combine(
        [
          if (param.isRequired) Code.literal('required '),
          param.type,
          Code.literal(' '),
          Code.literal(param.name),
          if (param.defaultValue != null) ...[
            Code.literal(' = '),
            param.defaultValue!
          ],
        ],
      );
}
