/// Analyzer utilities for converting DartType and DartObject to Code.
///
/// Adapted from locorda_rdf_mapper_generator for use in locorda_init_generator.
library;

import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';

import 'code.dart';

DartObject? getField(DartObject obj, String fieldName) {
  final field = obj.getField(fieldName);
  if (field != null && !field.isNull) {
    return field;
  }
  final superInstance = obj.getField('(super)');
  if (superInstance == null) {
    return null;
  }
  return getField(superInstance, fieldName);
}

/// Converts a DartType to a Code instance with proper import tracking
Code typeToCode(DartType type,
    {bool enforceNonNull = false, bool raw = false}) {
  final typeAlias = type.alias;
  if (typeAlias != null) {
    final aliasElement = typeAlias.element;
    var result = Code.type(
      aliasElement.displayName,
      importUri: _getImportUriForType(aliasElement),
    );

    if (!raw && typeAlias.typeArguments.isNotEmpty) {
      result = result +
          Code.genericParamsList(
            typeAlias.typeArguments.map((arg) => typeToCode(arg)),
          );
    }

    return _applyNullability(
      result,
      type.nullabilitySuffix,
      enforceNonNull: enforceNonNull,
    );
  }

  if (type is FunctionType) {
    return _functionTypeToCode(type, enforceNonNull: enforceNonNull);
  }

  if (type is RecordType) {
    return _recordTypeToCode(type, enforceNonNull: enforceNonNull);
  }

  // Handle generics recursively to preserve import information for type arguments
  // Note: When raw=true, type arguments are omitted for raw type references
  if (!raw && type is InterfaceType && type.typeArguments.isNotEmpty) {
    final baseName = type.element.displayName;
    final baseImportUri = _getImportUriForType(type.element);

    // Recursively convert type arguments
    final typeArgCodes = type.typeArguments
        .map((arg) => typeToCode(arg, enforceNonNull: false, raw: false))
        .toList();

    // Build the complete generic type with Code.combine to preserve imports
    final baseCode = Code.type(baseName, importUri: baseImportUri);
    final genericParams = Code.genericParamsList(typeArgCodes);

    var result = Code.combine([baseCode, genericParams]);

    return _applyNullability(
      result,
      type.nullabilitySuffix,
      enforceNonNull: enforceNonNull,
    );
  }

  // Fallback for non-generic types or raw type references
  var typeName = raw ? type.element?.displayName : null;

  typeName ??= type.getDisplayString();

  // Normalize display name by removing trailing nullability marker.
  // Nullability is applied centrally via _applyNullability to avoid `??`.
  if (typeName.endsWith('?')) {
    typeName = typeName.substring(0, typeName.length - 1);
  }
  final importUri = _getImportUriForType(type.element);
  return _applyNullability(
    Code.type(typeName, importUri: importUri),
    type.nullabilitySuffix,
    enforceNonNull: enforceNonNull,
  );
}

Code _functionTypeToCode(FunctionType type, {required bool enforceNonNull}) {
  final returnTypeCode = typeToCode(type.returnType);

  final params = <Code>[];
  for (final parameter in type.formalParameters) {
    final paramTypeCode = typeToCode(parameter.type);
    final paramName = parameter.displayName;
    final withName = paramName.isEmpty
        ? paramTypeCode
        : Code.combine([paramTypeCode, Code.literal(' $paramName')]);

    if (parameter.isNamed && parameter.isRequiredNamed) {
      params.add(Code.literal('required ') + withName);
    } else {
      params.add(withName);
    }
  }

  final requiredPositionalCount =
      type.formalParameters.where((param) => param.isRequiredPositional).length;
  final optionalPositionalCount =
      type.formalParameters.where((param) => param.isOptionalPositional).length;
  final namedCount =
      type.formalParameters.where((param) => param.isNamed).length;

  final requiredPositional = params.take(requiredPositionalCount).toList();
  final optionalPositional = params
      .skip(requiredPositionalCount)
      .take(optionalPositionalCount)
      .toList();
  final named =
      params.skip(requiredPositionalCount + optionalPositionalCount).toList();

  final paramGroups = <Code>[];
  paramGroups.addAll(requiredPositional);
  if (optionalPositional.isNotEmpty) {
    paramGroups.add(
      Code.combine(optionalPositional, separator: ', ', pre: '[', post: ']'),
    );
  }
  if (named.isNotEmpty && namedCount > 0) {
    paramGroups.add(
      Code.combine(named, separator: ', ', pre: '{', post: '}'),
    );
  }

  final typeFormals = type.typeParameters;
  final typeFormalCode = typeFormals.isEmpty
      ? Code.literal('')
      : Code.genericParamsList(
          typeFormals.map((typeFormal) {
            final bound = typeFormal.bound;
            if (bound == null) {
              return Code.literal(typeFormal.displayName);
            }
            return Code.literal('${typeFormal.displayName} extends ') +
                typeToCode(bound);
          }),
        );

  var result = Code.combine([
    returnTypeCode,
    Code.literal(' Function'),
    typeFormalCode,
    Code.combine(paramGroups, separator: ', ', pre: '(', post: ')'),
  ]);

  return _applyNullability(
    result,
    type.nullabilitySuffix,
    enforceNonNull: enforceNonNull,
  );
}

Code _recordTypeToCode(RecordType type, {required bool enforceNonNull}) {
  final positional =
      type.positionalFields.map((field) => typeToCode(field.type));
  final named = type.namedFields.map(
    (field) =>
        Code.combine([typeToCode(field.type), Code.literal(' ${field.name}')]),
  );

  final bodyParts = <Code>[...positional];
  if (named.isNotEmpty) {
    bodyParts.add(
      Code.combine(named, separator: ', ', pre: '{', post: '}'),
    );
  }

  var result = Code.combine(bodyParts, separator: ', ', pre: '(', post: ')');

  return _applyNullability(
    result,
    type.nullabilitySuffix,
    enforceNonNull: enforceNonNull,
  );
}

Code _applyNullability(
  Code code,
  NullabilitySuffix nullabilitySuffix, {
  required bool enforceNonNull,
}) {
  if (!enforceNonNull && nullabilitySuffix == NullabilitySuffix.question) {
    return code + '?';
  }
  return code;
}

/// Converts a ClassElement to a Code instance
Code classToCode(ClassElement type) {
  final typeName = type.displayName;
  final importUri = _getImportUriForType(type);
  return Code.type(typeName, importUri: importUri);
}

/// Converts a EnumElement to a Code instance
Code enumToCode(EnumElement type) {
  final typeName = type.displayName;
  final importUri = _getImportUriForType(type);
  return Code.type(typeName, importUri: importUri);
}

/// Converts a DartObject to a Code instance with proper import tracking
///
/// This function analyzes a compile-time constant value and generates the
/// corresponding Dart code along with any necessary import dependencies.
Code dartObjectToCode(DartObject? value) {
  if (value == null || value.isNull) {
    return Code.value('null');
  }

  if (value.type?.isDartCoreType == true) {
    return typeToCode(value.toTypeValue()!);
  }

  // Handle primitive types (no imports needed)
  if (value.type?.isDartCoreBool == true) {
    return Code.value(value.toBoolValue().toString());
  }
  if (value.type?.isDartCoreInt == true) {
    return Code.value(value.toIntValue().toString());
  }
  if (value.type?.isDartCoreDouble == true) {
    return Code.value(value.toDoubleValue().toString());
  }
  if (value.type?.isDartCoreString == true) {
    final str = value.toStringValue() ?? '';
    // Escape single quotes and wrap in single quotes
    return Code.value("'${str.replaceAll("'", "\\'")}'");
  }

  final functionValue = value.toFunctionValue();
  if (functionValue != null) {
    return _executableToCode(functionValue);
  }

  // Handle enums - these need import tracking
  final enumValue = value.getField('_name')?.toStringValue();
  if (enumValue != null && value.type?.element is EnumElement) {
    final enumType = value.type!.getDisplayString();
    final importUri = _getImportUriForType(value.type!.element);
    return Code.type('$enumType.$enumValue', importUri: importUri);
  }

  // Handle lists
  if (value.type?.isDartCoreList == true) {
    final items = value.toListValue() ?? [];
    final itemCodes = items.map((item) => dartObjectToCode(item)).toList();
    final combinedCode = Code.combine(itemCodes, separator: ', ');
    return Code.combine([Code.value('['), combinedCode, Code.value(']')]);
  }

  // Handle maps
  if (value.type?.isDartCoreMap == true) {
    final map = value.toMapValue() ?? {};
    final entryCodes = map.entries.map((entry) {
      final keyCode = dartObjectToCode(entry.key);
      final valueCode = dartObjectToCode(entry.value);
      return Code.combine([keyCode, Code.value(': '), valueCode]);
    }).toList();
    final combinedEntries = Code.combine(entryCodes, separator: ', ');
    return Code.combine([Code.value('{'), combinedEntries, Code.value('}')]);
  }

  // Handle sets
  if (value.type?.isDartCoreSet == true) {
    final set = value.toSetValue() ?? {};
    final itemCodes = set.map((item) => dartObjectToCode(item)).toList();
    final combinedItems = Code.combine(itemCodes, separator: ', ');
    return Code.combine([Code.value('{'), combinedItems, Code.value('}')]);
  }

  // Handle records
  final recordValue = value.toRecordValue();
  if (recordValue != null) {
    final positional =
        recordValue.positional.map((item) => dartObjectToCode(item)).toList();
    final named = recordValue.named.entries
        .map((entry) =>
            Code.value('${entry.key}: ') + dartObjectToCode(entry.value))
        .toList();

    final parts = <Code>[...positional];
    if (named.isNotEmpty) {
      parts.add(Code.combine(named, separator: ', ', pre: '{', post: '}'));
    }
    return Code.combine(parts, separator: ', ', pre: '(', post: ')');
  }

  // Handle const constructors
  var typeElement = value.type?.element;
  if (typeElement is ClassElement) {
    for (final constructor in typeElement.constructors) {
      final fields = constructor.formalParameters;

      if (constructor.isConst) {
        final constructorName = constructor.displayName;
        final positionalArgCodes = <Code>[];
        final namedArgCodes = <Code>[];

        // Separate positional and named parameters
        for (final field in fields) {
          final fieldName = field.name;
          if (fieldName == null) continue;

          final fieldValue = value.getField(fieldName);
          if (fieldValue != null) {
            final fieldCode = dartObjectToCode(fieldValue);
            if (field.isNamed) {
              // Named parameter: paramName: value
              namedArgCodes
                  .add(Code.combine([Code.value('$fieldName: '), fieldCode]));
            } else {
              // Positional parameter: just the value
              positionalArgCodes.add(fieldCode);
            }
          }
        }

        // Combine positional and named arguments
        final allArgCodes = <Code>[];
        allArgCodes.addAll(positionalArgCodes);
        allArgCodes.addAll(namedArgCodes);

        final importUri = _getImportUriForType(typeElement);

        return Code.combine([
          Code.literal('const '),
          Code.type(constructorName, importUri: importUri),
          Code.paramsList(allArgCodes),
        ]);
      }
    }
  }

  // Fallback to string representation if type is not recognized
  return Code.value(value.toStringValue() ?? value.toString());
}

Code _executableToCode(ExecutableElement executable) {
  final importUri = _getImportUriForType(executable);

  if (executable is ConstructorElement) {
    final className = executable.enclosingElement.displayName;
    final constructorName = executable.displayName;
    final qualifiedName =
        constructorName.isEmpty ? className : '$className.$constructorName';
    return Code.type(qualifiedName, importUri: importUri);
  }

  final enclosingElement = executable.enclosingElement;
  if (enclosingElement is InterfaceElement) {
    return Code.type(
      '${enclosingElement.displayName}.${executable.displayName}',
      importUri: importUri,
    );
  }

  return Code.type(executable.displayName, importUri: importUri);
}

/// Determines the import URI for a given type element
String? _getImportUriForType(Element? element) {
  if (element == null) return null;

  final source = element.library?.identifier;
  if (source == null) return null;

  return source.toString();
}
