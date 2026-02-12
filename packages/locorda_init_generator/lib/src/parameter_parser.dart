import 'package:analyzer/dart/element/element.dart';

import 'code_generation/analyzer_utils.dart';
import 'code_generation/code.dart';
import 'parameter_info.dart';

List<ParameterInfo> parseParameterElements(
    Iterable<FormalParameterElement> parameters) {
  final result = <ParameterInfo>[];

  for (final param in parameters) {
    final normalized = _normalizeParameter(param);
    if (normalized == null) {
      continue;
    }
    result.add(normalized);
  }

  return result;
}

ParameterInfo? _normalizeParameter(FormalParameterElement param) {
  final name = param.displayName;
  if (name.isEmpty) {
    return null;
  }

  final isNamed = param.isNamed;
  final isRequired =
      param.isRequiredNamed || (!isNamed && param.isRequiredPositional);

  final defaultValue = param.defaultValueCode == null
      ? null
      : Code.value(param.defaultValueCode!);

  return ParameterInfo(
    name: name,
    type: typeToCode(param.type),
    isRequired: isRequired,
    isNamed: isNamed,
    defaultValue: defaultValue,
    documentation: param.documentationComment,
  );
}
