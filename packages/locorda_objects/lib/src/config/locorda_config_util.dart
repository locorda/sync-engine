import 'package:locorda_rdf_core/core.dart';
import 'package:locorda_rdf_mapper/mapper.dart';

import 'locorda_config.dart';

class ResourceTypeCache {
  final Map<Type, IriTerm> _resourceTypeCache;
  late final Map<IriTerm, Type> _iriToTypeCache = {
    for (final entry in _resourceTypeCache.entries) entry.value: entry.key
  };

  ResourceTypeCache(this._resourceTypeCache);

  /// Gets the IRI for the given resource type.
  /// Returns null if the type is not registered as a resource.
  bool hasIri(Type type) => _resourceTypeCache[type] != null;

  IriTerm getIri(Type type) =>
      _resourceTypeCache[type] ??
      (throw ArgumentError(
          'Type $type is not registered in resource type cache'));
  Type? getDartType(IriTerm iri) => _iriToTypeCache[iri];
}

ResourceTypeCache buildResourceTypeCache(
    RdfMapper _mapper, LocordaConfig config) {
  final resourceTypeCache = <Type, IriTerm>{};
  for (final resource in config.resources) {
    if (!resourceTypeCache.containsKey(resource.type)) {
      final typeIri = _getTypeIri(_mapper, resource);
      if (typeIri != null) {
        resourceTypeCache[resource.type] = typeIri;
      }
    }
  }
  return ResourceTypeCache(resourceTypeCache);
}

IriTerm? _getTypeIri(RdfMapper mapper, ResourceConfig resource) {
  final registry = mapper.registry;
  try {
    return registry.getResourceSerializerByType(resource.type).typeIri;
  } on SerializerNotFoundException {
    return null;
  }
}

/// Find the resource and index configuration for a given type and local name.
///
/// Searches through all resources and their indices to find a matching
/// configuration where the index item type matches T and localName matches.
/// Returns the resource configuration and index configuration as a record,
/// or null if no match is found.
///
/// This is used during hydration setup to determine how to convert
/// resources to index items for a specific stream.
(ResourceConfig, CrdtIndexConfig)? findIndexConfigForType<T>(
    LocordaConfig config, String localName) {
  // Search through all resources and their indices
  for (final resourceConfig in config.resources) {
    for (final index in resourceConfig.indices) {
      // Check if this index matches our type T and localName
      if (index.item != null &&
          index.item!.itemType == T &&
          index.localName == localName) {
        // Found matching index
        return (resourceConfig, index);
      }
    }
  }
  return null;
}

/**
 * For the combination of group key type G and localName, find the corresponding
 * index name which is used by the core implementation (SyncEngineConfig).
 */
String? getGroupIndexName<G>(LocordaConfig config, String localName) {
  for (final resource in config.resources) {
    for (final index in resource.indices) {
      if (index is GroupIndexConfig &&
          index.localName == localName &&
          index.groupKeyType == G) {
        return getIndexName(resource, index);
      }
    }
  }
  return null;
}

String getIndexName(ResourceConfig resource, CrdtIndexConfig index) =>
    switch (index) {
      FullIndexConfig _ =>
        '${resource.type.toString()}_${index.item?.itemType.toString() ?? ''}_${index.localName}',
      GroupIndexConfig _ =>
        '${resource.type.toString()}_${index.item?.itemType.toString() ?? ''}_${index.groupKeyType.toString()}_${index.localName}',
    };
