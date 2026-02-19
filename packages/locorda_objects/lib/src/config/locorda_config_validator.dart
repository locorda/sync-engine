import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:locorda_rdf_mapper/mapper.dart';

import 'locorda_config.dart';
import 'locorda_config_util.dart';

class LocordaConfigValidator {
  final ConfigBaseValidator _baseValidator =
      ConfigBaseValidator((c) => (c as ResourceConfig).type.toString());

  LocordaConfigValidator();

  Map<Type, IriTerm> buildResourceTypeCache(
      RdfMapper mapper, LocordaConfig config) {
    final resourceTypeCache = <Type, IriTerm>{};
    for (final resource in config.resources) {
      if (!resourceTypeCache.containsKey(resource.type)) {
        final typeIri = _getTypeIri(mapper, resource);
        if (typeIri != null) {
          resourceTypeCache[resource.type] = typeIri;
        }
      }
    }
    return resourceTypeCache;
  }

  static IriTerm? _getTypeIri(RdfMapper mapper, ResourceConfig resource) {
    final registry = mapper.registry;
    try {
      return registry.getResourceSerializerByType(resource.type).typeIri;
    } on SerializerNotFoundException {
      return null;
    }
  }

  ValidationResult validate(
    LocordaConfig config,
    ResourceTypeCache resourceTypeCache, {
    required RdfMapper mapper,
  }) {
    final result = _baseValidator.validate(config);
    _validateMapperTypes(config, result, mapper);
    _validateResourceUniqueness(config, result, resourceTypeCache);
    _validateIndexConfigurations(config, result);

    return result;
  }

  void _validateMapperTypes(
      LocordaConfig config, ValidationResult result, RdfMapper mapper) {
    // Collect all types that need mappers
    final requiredTypes = <Type>{};
    final deserializerOnly = <Type>{};
    // Add all resource dart types
    for (final resource in config.resources) {
      requiredTypes.add(resource.type);
    }

    // Add all index item types and groupKeyTypes
    for (final resource in config.resources) {
      for (final index in resource.indices) {
        if (index.item != null) {
          requiredTypes.add(index.item!.itemType);
          deserializerOnly.add(index.item!.itemType);
        }

        // Add groupKeyType for GroupIndex
        if (index is GroupIndexConfig) {
          requiredTypes.add(index.groupKeyType);
        }
      }
    }

    // Check if mapper can handle each required type
    for (final type in requiredTypes) {
      // Skip primitive types like String - they're not mappable types
      if (type == String || type == int || type == double || type == bool) {
        result.addError(
            'Type $type is a primitive type and cannot be used as a mappable resource, groupKey, or itemType. '
            'Use proper RDF-mapped classes instead.',
            details: {'type': type});
        continue;
      }

      // Try to get a serializer for the type - this is the definitive test
      final needsSerializer = !deserializerOnly.contains(type);
      final hasSerializer = needsSerializer &&
          mapper.registry.hasResourceSerializerForDartType(type);
      var hasDeserializer =
          mapper.registry.hasGlobalResourceDeserializerForDartType(type) ||
              mapper.registry.hasLocalResourceDeserializerForDartType(type);
      if (!hasSerializer && !hasDeserializer) {
        result.addError(
            'Type $type is not registered in RdfMapper. '
            'Ensure the type is properly annotated with @RootResource, @SubResource or @LocalResource - or a mapper is implemented and registered manually.',
            details: {'type': type});
      } else {
        if (!hasDeserializer) {
          result.addError(
              'Type $type has ${hasSerializer ? 'a serializer but ' : ''}no deserializer registered in RdfMapper. '
              'Ensure the type is properly annotated with @RootResource, @SubResource or @LocalResource - or a mapper is implemented and registered manually.',
              details: {'type': type});
        } else if (!hasSerializer && needsSerializer) {
          result.addError(
              'Type $type has a deserializer but no serializer registered in RdfMapper. '
              'Ensure the type is properly annotated with @RootResource, @SubResource or @LocalResource - or a mapper is implemented and registered manually.',
              details: {'type': type});
        }
      }
    }
  }

  void _validateResourceUniqueness(LocordaConfig config,
      ValidationResult result, ResourceTypeCache resourceTypeCache) {
    // Check for duplicate Dart types
    final dartTypes = <Type>{};
    final rdfTypeIris = <String, Type>{};

    for (final resource in config.resources) {
      // Check for duplicate Dart types
      if (dartTypes.contains(resource.type)) {
        result.addError(
            'Duplicate resource type: ${resource.type}. Each Dart type can only be configured once.',
            details: {'type': resource.type});
        continue; // Skip further processing for this resource
      }
      dartTypes.add(resource.type);

      // Check for RDF type IRI collisions
      try {
        if (resourceTypeCache.hasIri(resource.type)) {
          final rdfTypeIri = resourceTypeCache.getIri(resource.type);
          final rdfTypeIriString = rdfTypeIri.value;
          if (rdfTypeIris.containsKey(rdfTypeIriString)) {
            result.addError(
                'RDF type IRI collision: ${resource.type} and ${rdfTypeIris[rdfTypeIriString]} '
                'both use $rdfTypeIriString. Each Dart type must have a unique RDF type IRI.',
                details: {
                  'conflicting_types': [
                    resource.type,
                    rdfTypeIris[rdfTypeIriString]
                  ],
                  'rdf_iri': rdfTypeIriString
                });
          }
          rdfTypeIris[rdfTypeIriString] = resource.type;
        } else {
          result.addError(
              'No RDF type IRI found for ${resource.type}. Resource types must be annotated with @PodResource.',
              details: {'type': resource.type});
        }
      } catch (e) {
        result.addError(
            'Could not resolve RDF type IRI for ${resource.type}: $e',
            details: {'type': resource.type, 'error': e.toString()});
      }
    }
  }

  void _validateIndexConfigurations(
      LocordaConfig config, ValidationResult result) {
    // Track local names per index item type across all resources
    final localNamesByItemType = <Type, Map<String, List<Type>>>{};
    // Track groupKeyType and localName combinations for GroupIndex uniqueness
    final groupKeyLocalNameCombinations = <String, List<(Type, String)>>{};

    for (final resource in config.resources) {
      for (final index in resource.indices) {
        // Track local names by index item type (if index has an item type)
        if (index.item != null) {
          final itemType = index.item!.itemType;
          final localNamesForType = localNamesByItemType.putIfAbsent(
              itemType, () => <String, List<Type>>{});

          localNamesForType
              .putIfAbsent(index.localName, () => [])
              .add(resource.type);
        }

        // Validate GroupIndex specific requirements
        if (index is GroupIndexConfig) {
          if (index.groupingProperties.isEmpty) {
            result.addError(
                'GroupIndex must have at least one grouping property for ${resource.type}',
                details: {'type': resource.type, 'index': index});
          }

          // Track groupKeyType + localName combination for uniqueness
          final groupKeyTypeName = index.groupKeyType.toString();
          final combinationKey = '$groupKeyTypeName:${index.localName}';
          groupKeyLocalNameCombinations
              .putIfAbsent(combinationKey, () => [])
              .add((resource.type, index.localName));
        }
      }
    }

    // Check for duplicate local names within the same index item type
    localNamesByItemType.forEach((itemType, localNames) {
      localNames.forEach((localName, resourceTypes) {
        if (resourceTypes.length > 1) {
          result.addError(
              'Duplicate index local name "$localName" for index item type $itemType. '
              'Used by resources: ${resourceTypes.join(', ')}. '
              'Local names must be unique per index item type.',
              details: {
                'localName': localName,
                'itemType': itemType,
                'conflictingResources': resourceTypes
              });
        }
      });
    });

    // Check for duplicate groupKeyType + localName combinations
    groupKeyLocalNameCombinations.forEach((combinationKey, entries) {
      if (entries.length > 1) {
        final resourceTypes = entries.map((e) => e.$1).toList();
        final localName = entries.first.$2;
        result.addError(
            'Duplicate groupKeyType and localName combination: $combinationKey. '
            'Used by resources: ${resourceTypes.join(', ')}. '
            'GroupIndex groupKeyType and localName combinations must be unique.',
            details: {
              'combinationKey': combinationKey,
              'localName': localName,
              'conflictingResources': resourceTypes
            });
      }
    });
  }
}
