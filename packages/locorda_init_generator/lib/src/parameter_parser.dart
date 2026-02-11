import 'package:analyzer/dart/ast/ast.dart';

import 'parameter_info.dart';

List<ParameterInfo> parseParameterList(FormalParameterList parameters) {
  final result = <ParameterInfo>[];

  for (final param in parameters.parameters) {
    final normalized = _normalizeParameter(param);
    if (normalized == null) {
      continue;
    }
    result.add(normalized);
  }

  return result;
}

ParameterInfo? _normalizeParameter(FormalParameter param) {
  if (param is DefaultFormalParameter) {
    final normalParam = param.parameter;
    final base = _normalizeParameter(normalParam);
    if (base == null) {
      return null;
    }
    return ParameterInfo(
      name: base.name,
      type: base.type,
      isRequired: param.isRequired,
      isNamed: param.isNamed,
      defaultValue: param.defaultValue?.toSource(),
      documentation: base.documentation,
    );
  }

  if (param is SimpleFormalParameter) {
    final name = param.name?.lexeme;
    if (name == null) {
      return null;
    }
    return ParameterInfo(
      name: name,
      type: param.type?.toSource() ?? 'dynamic',
      isRequired: param.isRequired,
      isNamed: param.isNamed,
      defaultValue: null,
    );
  }

  if (param is FunctionTypedFormalParameter) {
    return ParameterInfo(
      name: param.name.lexeme,
      type: _functionTypeToSource(param),
      isRequired: param.isRequired,
      isNamed: param.isNamed,
      defaultValue: null,
    );
  }

  return null;
}

String _functionTypeToSource(FunctionTypedFormalParameter param) {
  final returnType = param.returnType?.toSource() ?? 'dynamic';
  final paramList = param.parameters.toSource();
  final source = param.toSource().trim();
  final isNullable = source.endsWith('?');
  final suffix = isNullable ? '?' : '';
  return '$returnType Function$paramList$suffix';
}
