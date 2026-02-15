/// Scans Dart source files for Locorda config annotations.
library;

import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:logging/logging.dart';

import '../code_generation/analyzer_utils.dart';
import '../code_generation/code.dart';
import 'annotation_data.dart';

final _log = Logger('AnnotationScanner');

/// Scans Dart source files for Locorda config annotations.
///
/// Uses the Element model (via `buildStep.resolver.libraryFor()`) for
/// annotation detection and extraction. All constant values are accessed
/// through `DartObject` methods, avoiding the need for AST parsing.
class AnnotationScanner {
  /// Scans a resolved library for config-relevant annotations.
  ///
  /// [libraryElement] - resolved library from `buildStep.resolver`
  /// [importUri] - package URI for generated imports
  ScanResult scanLibrary(
    LibraryElement libraryElement,
    String importUri,
  ) {
    final rootResources = <RootResourceData>[];
    final groupKeys = <GroupKeyData>[];
    final indexItems = <IndexItemData>[];

    // Scan all classes in the library
    for (final element in libraryElement.classes) {
      // Check for @LcrdRootResource
      final rootResource = _scanRootResource(
        element,
        importUri,
      );
      if (rootResource != null) {
        rootResources.add(rootResource);
      }

      // Check for @LcrdGroupKey
      final groupKey = _scanGroupKey(element, importUri);
      if (groupKey != null) {
        groupKeys.add(groupKey);
      }

      // Check for @LcrdIndexItem
      final indexItem = _scanIndexItem(element, importUri);
      if (indexItem != null) {
        indexItems.add(indexItem);
      }
    }

    return ScanResult(
      rootResources: rootResources,
      groupKeys: groupKeys,
      indexItems: indexItems,
    );
  }

  RootResourceData? _scanRootResource(
    ClassElement element,
    String importUri,
  ) {
    // Find @LcrdRootResource annotation
    for (final annotation in element.metadata.annotations) {
      final annotationValue = annotation.computeConstantValue();
      if (annotationValue == null) continue;

      final annotationType = annotationValue.type?.element?.name;
      if (annotationType != 'LcrdRootResource') continue;

      // Extract classIri (first argument) as Code
      final classIriField = getField(annotationValue, 'classIri');
      Code? classIri;
      if (classIriField != null && !classIriField.isNull) {
        classIri = dartObjectToCode(classIriField);
      }

      // Extract crdt config
      final crdtField = getField(annotationValue, 'crdt');
      if (crdtField == null || crdtField.isNull) {
        _log.warning(
            'Could not extract crdt config for ${element.displayName}');
        continue;
      }

      // Extract crdt.mappingIri as Code
      final crdtMappingField = getField(crdtField, 'mappingIri');
      if (crdtMappingField == null) {
        _log.warning(
            'Could not extract crdt.mappingIri for ${element.displayName}');
        continue;
      }
      final mappingLiteral = crdtMappingField.toStringValue();
      final crdtMapping = mappingLiteral == null
          ? dartObjectToCode(crdtMappingField)
          : Code.value("'${mappingLiteral.replaceAll("'", "\\'")}'");

      // Extract crdt.generate
      final generateCrdtMapping =
          getField(crdtField, 'generate')?.toBoolValue() ?? true;

      // Extract fullIndex
      final fullIndexField = getField(annotationValue, 'fullIndex');
      final fullIndexData = _extractFullIndexData(fullIndexField);

      return RootResourceData(
        className: classToCode(element),
        classIri: classIri,
        crdtMapping: crdtMapping,
        generateCrdtMapping: generateCrdtMapping,
        fullIndex: fullIndexData,
      );
    }

    return null;
  }

  GroupKeyData? _scanGroupKey(
    ClassElement element,
    String importUri,
  ) {
    // Find @LcrdGroupKey annotation
    for (final annotation in element.metadata.annotations) {
      final annotationValue = annotation.computeConstantValue();
      if (annotationValue == null) continue;

      final annotationType = annotationValue.type?.element?.name;
      if (annotationType != 'LcrdGroupKey') continue;

      // Extract resourceType
      final resourceTypeField = getField(annotationValue, 'resourceType');
      final resourceTypeName = resourceTypeField?.toTypeValue()?.element;

      if (resourceTypeName is! ClassElement) {
        _log.warning(
            'Could not extract resourceType for GroupKey ${element.displayName}');
        continue;
      }

      // Extract localName
      final localName = getField(annotationValue, 'localName')?.toStringValue();

      // Extract groupingProperties
      final groupingPropertiesField =
          getField(annotationValue, 'groupingProperties');
      final groupingProperties =
          _extractGroupingProperties(groupingPropertiesField);

      return GroupKeyData(
        className: classToCode(element),
        resourceTypeName: classToCode(resourceTypeName),
        localName: localName,
        groupingProperties: groupingProperties,
      );
    }

    return null;
  }

  IndexItemData? _scanIndexItem(
    ClassElement element,
    String importUri,
  ) {
    // Find @LcrdIndexItem annotation
    for (final annotation in element.metadata.annotations) {
      final annotationValue = annotation.computeConstantValue();
      if (annotationValue == null) continue;

      final annotationType = annotationValue.type?.element?.name;
      if (annotationType != 'LcrdIndexItem') continue;

      // Extract groupKeyType (null for fullIndex)
      final groupKeyTypeField = getField(annotationValue, 'groupKeyType');
      final groupKeyTypeName =
          groupKeyTypeField?.toTypeValue()?.element as ClassElement?;

      // Extract resourceType from IndexItemIriStrategy
      // The `iri` field in RdfGlobalResource contains the IndexItemIriStrategy
      ClassElement? resourceTypeName;
      final iriField = getField(annotationValue, 'iri');

      if (iriField != null && !iriField.isNull) {
        // The iriField is an IndexItemIriStrategy, which extends IriStrategy
        // which extends BaseMapping. The resource Type is stored in
        // BaseMapping._factoryConfigInstance field
        final configField = getField(iriField, '_factoryConfigInstance');

        if (configField != null) {
          final typeValue = configField.toTypeValue();
          resourceTypeName = typeValue?.element as ClassElement?;
        }
      }

      if (resourceTypeName is! ClassElement) {
        _log.warning(
            'Could not extract resourceType for IndexItem ${element.displayName}');
        continue;
      }

      // Extract properties from fields
      final properties = <IndexPropertyData>[];
      for (final field in element.fields) {
        for (final fieldAnnotation in field.metadata.annotations) {
          final fieldAnnotationValue = fieldAnnotation.computeConstantValue();
          if (fieldAnnotationValue == null) continue;

          // Check if this is RdfProperty or a subclass
          if (_matchesAnnotationInHierarchy(
              fieldAnnotationValue.type, 'RdfProperty')) {
            // Extract property IRI as Code with proper import tracking
            final predicateField = getField(fieldAnnotationValue, 'predicate');
            if (predicateField != null) {
              final propertyCode = dartObjectToCode(predicateField);
              properties.add(IndexPropertyData(code: propertyCode));
            }
          }
        }
      }

      // Warn if no properties found
      if (properties.isEmpty) {
        _log.warning(
            'IndexItem ${element.displayName} has no @RdfProperty fields - generating empty property set');
      }

      return IndexItemData(
        className: classToCode(element),
        resourceTypeName: classToCode(resourceTypeName),
        groupKeyTypeName:
            groupKeyTypeName == null ? null : classToCode(groupKeyTypeName),
        properties: properties,
      );
    }

    return null;
  }

  /// Checks if the given type or any of its supertypes match the target annotation name.
  /// Supports annotation subclassing by walking up the inheritance hierarchy.
  bool _matchesAnnotationInHierarchy(
      DartType? type, String targetAnnotationName) {
    if (type == null) return false;
    final visitedTypes = <String>{};
    return _checkTypeHierarchy(type, targetAnnotationName, visitedTypes);
  }

  bool _checkTypeHierarchy(
      DartType type, String targetAnnotationName, Set<String> visitedTypes) {
    final typeName = type.element?.name;
    if (typeName == null || visitedTypes.contains(typeName)) return false;
    visitedTypes.add(typeName);
    if (typeName == targetAnnotationName) return true;
    if (type is InterfaceType) {
      for (final supertype in type.allSupertypes) {
        if (_checkTypeHierarchy(
            supertype, targetAnnotationName, visitedTypes)) {
          return true;
        }
      }
    }
    return false;
  }

  FullIndexData _extractFullIndexData(DartObject? fullIndexField) {
    if (fullIndexField == null) {
      return const FullIndexData(
        isEnabled: true,
        localName: 'default',
        policy: 'prefetch',
      );
    }

    final isEnabled =
        getField(fullIndexField, 'isEnabled')?.toBoolValue() ?? true;
    final localName =
        getField(fullIndexField, 'localName')?.toStringValue() ?? 'default';

    // Extract policy enum value
    final policyField = getField(fullIndexField, 'policy');
    String policyStr = 'prefetch';
    if (policyField != null) {
      // The policy field is an ItemFetchPolicy enum, extract its name
      final policyType = policyField.type;
      if (policyType is InterfaceType) {
        final policyTypeName = policyType.element.name;
        if (policyTypeName == 'Prefetch') {
          policyStr = 'prefetch';
        } else if (policyTypeName == 'OnRequest') {
          policyStr = 'onRequest';
        }
      }
    }

    return FullIndexData(
      isEnabled: isEnabled,
      localName: localName,
      policy: policyStr,
    );
  }

  List<GroupingPropertyData> _extractGroupingProperties(
      DartObject? groupingPropertiesField) {
    if (groupingPropertiesField == null) return [];

    final propertiesList = groupingPropertiesField.toListValue();
    if (propertiesList == null) return [];

    final result = <GroupingPropertyData>[];
    for (final propertyObj in propertiesList) {
      final propertyField = getField(propertyObj, 'property');
      if (propertyField == null) continue;

      // Extract property as Code with proper import tracking
      final property = dartObjectToCode(propertyField);

      // Extract transforms
      final transformsField = getField(propertyObj, 'transforms');
      final transforms = <RegexTransformData>[];
      if (transformsField != null) {
        final transformsList = transformsField.toListValue();
        if (transformsList != null) {
          for (final transformObj in transformsList) {
            final pattern =
                getField(transformObj, 'pattern')?.toStringValue() ?? '';
            final replacement =
                getField(transformObj, 'replacement')?.toStringValue() ?? '';
            transforms.add(RegexTransformData(
              pattern: pattern,
              replacement: replacement,
            ));
          }
        }
      }

      result.add(GroupingPropertyData(
        property: property,
        transforms: transforms,
      ));
    }

    return result;
  }
}

class ScanResult {
  final List<RootResourceData> rootResources;
  final List<GroupKeyData> groupKeys;
  final List<IndexItemData> indexItems;

  const ScanResult({
    required this.rootResources,
    required this.groupKeys,
    required this.indexItems,
  });
}
