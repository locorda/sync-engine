import 'package:locorda_init_generator/src/code_generation/code.dart';

/// Information about a function parameter.
class ParameterInfo {
  final String name;
  final Code type;
  final bool isRequired;
  final bool isNamed;
  final Code? defaultValue;
  final String? documentation;

  const ParameterInfo({
    required this.name,
    required this.type,
    required this.isRequired,
    required this.isNamed,
    this.defaultValue,
    this.documentation,
  });

  @override
  String toString() => 'ParameterInfo('
      'name: $name, '
      'type: $type, '
      'required: $isRequired, '
      'named: $isNamed, '
      'default: $defaultValue)';
}

/// Result of analyzing initRdfMapper signature.
class MapperAnalysisResult {
  final List<ParameterInfo> customParams;
  final Set<String> frameworkParams;

  const MapperAnalysisResult({
    required this.customParams,
    required this.frameworkParams,
  });
}
