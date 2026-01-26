import 'package:locorda_core/src/config/config_base.dart';
import 'package:locorda_core/src/vocab/generated/idx/index.dart';
import 'package:locorda_core/src/index/index_config_base.dart';
import 'package:locorda_core/src/sync/sync_manager.dart';
import 'package:locorda_rdf_core/core.dart';

class IndexItemData extends IndexItemConfigBase {
  const IndexItemData(super.properties);

  factory IndexItemData.fromJson(Map<String, dynamic> json) {
    final propertiesJson = json['properties'] as List<dynamic>;
    final properties = propertiesJson.map((p) => IriTerm(p as String)).toSet();

    return IndexItemData(properties);
  }

  Map<String, dynamic> toJson() {
    return {
      'properties': properties.map((p) => p.value).toList(),
    };
  }
}

sealed class CrdtIndexData extends CrdtIndexConfigBase {
  IndexItemData? get item;
}

class FullIndexData extends FullIndexConfigBase implements CrdtIndexData {
  final IndexItemData? item;

  const FullIndexData(
      {required super.localName, this.item, super.itemFetchPolicy})
      : super(item: item);

  factory FullIndexData.fromJson(Map<String, dynamic> json) {
    final localName = json['localName'] as String;
    final itemFetchPolicyStr = json['itemFetchPolicy'] as String?;
    final itemFetchPolicy = switch (itemFetchPolicyStr) {
      'prefetch' => ItemFetchPolicy.prefetch,
      'onRequest' => ItemFetchPolicy.onRequest,
      null => null,
      _ => throw ArgumentError('Unknown itemFetchPolicy: $itemFetchPolicyStr')
    };
    final itemJson = json['item'] as Map<String, dynamic>?;
    final item = itemJson != null ? IndexItemData.fromJson(itemJson) : null;

    return FullIndexData(
        localName: localName, itemFetchPolicy: itemFetchPolicy, item: item);
  }

  Map<String, dynamic> toJson() {
    return {
      'localName': localName,
      'itemFetchPolicy': itemFetchPolicy == ItemFetchPolicy.prefetch
          ? 'prefetch'
          : 'onRequest',
      if (item != null) 'item': item!.toJson(),
    };
  }
}

class GroupIndexData extends GroupIndexConfigBase implements CrdtIndexData {
  final IndexItemData? item;

  const GroupIndexData({
    required super.localName,
    this.item,
    super.groupingProperties = const [],
  }) : super(item: item);

  factory GroupIndexData.fromJson(Map<String, dynamic> json) {
    final localName = json['localName'] as String;
    final itemJson = json['item'] as Map<String, dynamic>?;
    final item = itemJson != null ? IndexItemData.fromJson(itemJson) : null;
    final groupingPropertiesJson =
        json['groupingProperties'] as List<dynamic>? ?? [];
    final groupingProperties = groupingPropertiesJson
        .map((gp) => GroupingProperty.fromJson(gp as Map<String, dynamic>))
        .toList(growable: false);

    return GroupIndexData(
        localName: localName,
        groupingProperties: groupingProperties,
        item: item);
  }

  Map<String, dynamic> toJson() {
    return {
      'localName': localName,
      if (item != null) 'item': item!.toJson(),
      'groupingProperties':
          groupingProperties.map((gp) => gp.toJson()).toList(),
    };
  }
}

class DocumentIriTemplate {
  final String template;
  final List<String> variables;

  /// The prefix before the first variable (everything before first '{')
  /// Used for efficient prefix matching when checking if an IRI matches this template
  late final String prefix;

  /// The suffix after the last variable (everything after last '}')
  /// Used for efficient suffix matching when checking if an IRI matches this template
  late final String suffix;

  DocumentIriTemplate._(this.template, this.variables) {
    final firstBraceIndex = template.indexOf('{');
    final lastBraceIndex = template.lastIndexOf('}');

    prefix = firstBraceIndex >= 0
        ? template.substring(0, firstBraceIndex)
        : template;
    suffix = lastBraceIndex >= 0 && lastBraceIndex < template.length - 1
        ? template.substring(lastBraceIndex + 1)
        : '';
  }

  factory DocumentIriTemplate.fromJson(String json) {
    final template = json;
    final variableRegex = RegExp(r'\{([^}]+)\}');
    final variables = variableRegex
        .allMatches(template)
        .map((match) => match.group(1)!)
        .toList(growable: false);

    // Validation: must have exactly one variable and it must be called "id"
    if (variables.length != 1) {
      throw ArgumentError(
          'Document IRI template must have exactly one variable. '
          'Got ${variables.length} variables: $variables in template: $template');
    }

    if (variables.single != 'id') {
      throw ArgumentError('Document IRI template variable must be named "id". '
          'Got: ${variables.single} in template: $template');
    }

    return DocumentIriTemplate._(template, variables);
  }

  String toJson() => template;

  /// Efficiently checks if a given IRI matches this template pattern
  ///
  /// First does a quick prefix/suffix check, then extracts the ID if it matches
  /// Returns the extracted URL-decoded ID if the IRI matches, null otherwise
  String? extractId(String iriValue) {
    // Quick prefix check
    if (!iriValue.startsWith(prefix)) {
      return null;
    }

    // Quick suffix check
    if (suffix.isNotEmpty && !iriValue.endsWith(suffix)) {
      return null;
    }

    // Extract the ID value between prefix and suffix
    final startIndex = prefix.length;
    final endIndex =
        suffix.isEmpty ? iriValue.length : iriValue.length - suffix.length;

    if (startIndex >= endIndex) {
      return null;
    }

    final encodedId = iriValue.substring(startIndex, endIndex);

    // URL decode the extracted ID
    return Uri.decodeComponent(encodedId);
  }

  /// Creates an IRI from this template by substituting the URL-encoded ID
  String toIri(String id) {
    // URL encode the ID before substituting
    final encodedId = Uri.encodeComponent(id);
    return template.replaceAll('{id}', encodedId);
  }
}

class ResourceConfigData extends ResourceConfigBase {
  final List<CrdtIndexData> indices;
  late final List<CrdtIndexData> indicesInOrder = indices.toList()
    ..sort((a, b) => a.localName.compareTo(b.localName));

  final IriTerm typeIri;
  final DocumentIriTemplate? documentIriTemplate;

  ResourceConfigData({
    required this.typeIri,
    required super.crdtMapping,
    required this.indices,
    String? documentIriTemplate,
  })  : documentIriTemplate = documentIriTemplate != null
            ? DocumentIriTemplate.fromJson(documentIriTemplate)
            : null,
        super(indices: indices);

  CrdtIndexData getIndexByName(String localName) {
    return indices.firstWhere((i) => i.localName == localName,
        orElse: () =>
            throw ArgumentError('No index found with localName: $localName'));
  }

  factory ResourceConfigData.fromJson(Map<String, dynamic> json) {
    final typeIri = IriTerm(json['typeIri'] as String);
    final crdtMappingStr = json['crdtMapping'] as String;
    final crdtMapping = Uri.parse(crdtMappingStr);
    final documentIriTemplate = json['documentIriTemplate'] as String?;

    final indicesJson = json['indices'] as List<dynamic>;
    final indices = <CrdtIndexData>[];

    for (final indexJson in indicesJson) {
      final indexType = indexJson['type'] as String;

      switch (indexType) {
        case 'FullIndex':
          indices
              .add(FullIndexData.fromJson(indexJson as Map<String, dynamic>));
          break;
        case 'GroupIndex':
          indices
              .add(GroupIndexData.fromJson(indexJson as Map<String, dynamic>));
          break;
        default:
          throw ArgumentError('Unknown index type: $indexType');
      }
    }

    return ResourceConfigData(
      typeIri: typeIri,
      crdtMapping: crdtMapping,
      indices: indices,
      documentIriTemplate: documentIriTemplate,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'typeIri': typeIri.value,
      'crdtMapping': crdtMapping.toString(),
      if (documentIriTemplate != null)
        'documentIriTemplate': documentIriTemplate!.toJson(),
      'indices': indices.map((index) {
        final baseJson = index is FullIndexData
            ? index.toJson()
            : (index as GroupIndexData).toJson();
        return {
          ...baseJson,
          'type': index is FullIndexData ? 'FullIndex' : 'GroupIndex',
        };
      }).toList(),
    };
  }
}

class SyncEngineConfig extends ConfigBase {
  final List<ResourceConfigData> resources;
  late final Iterable<ResourceConfigData> resourcesInSyncOrder =
      resources.toList()
        ..sort((a, b) {
          // Index-of-indices (root indices) first
          // Note: It is important that FullIndex comes before GroupIndex here
          // because GroupIndex must be indexed by FullIndex itself.
          final aIsRootFullIndex = a.typeIri == IdxFullIndex.classIri;
          final bIsRootFullIndex = b.typeIri == IdxFullIndex.classIri;
          if (aIsRootFullIndex && !bIsRootFullIndex) return -1;
          if (!aIsRootFullIndex && bIsRootFullIndex) return 1;

          final aIsRootGroupIndex = a.typeIri == IdxGroupIndexTemplate.classIri;
          final bIsRootGroupIndex = b.typeIri == IdxGroupIndexTemplate.classIri;
          if (aIsRootGroupIndex && !bIsRootGroupIndex) return -1;
          if (!aIsRootGroupIndex && bIsRootGroupIndex) return 1;

          // Within each group, sort by IRI value for determinism
          return a.typeIri.value.compareTo(b.typeIri.value);
        });
  late final Iterable<(CrdtIndexData indexConfig, IriTerm indexedTypeIri)>
      allIndicesInOrder = resourcesInSyncOrder
          .expand((r) => r.indicesInOrder.map((i) => (i, r.typeIri)))
          .toList();

  SyncEngineConfig({
    required this.resources,
    super.autoSyncConfig = const AutoSyncConfig.disabled(),
  }) : super(resources: resources);

  factory SyncEngineConfig.fromJson(Map<String, dynamic> json) {
    final resourcesJson = json['resources'] as List<dynamic>;
    final resources = resourcesJson
        .map((r) => ResourceConfigData.fromJson(r as Map<String, dynamic>))
        .toList();

    // Parse auto sync config if present
    final autoSyncJson = json['autoSync'] as Map<String, dynamic>?;
    final autoSyncConfig = autoSyncJson != null
        ? AutoSyncConfig.fromJson(autoSyncJson)
        : const AutoSyncConfig.disabled();

    return SyncEngineConfig(
      resources: resources,
      autoSyncConfig: autoSyncConfig,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'resources': resources.map((r) => r.toJson()).toList(),
      'autoSync': autoSyncConfig.toJson(),
    };
  }

  ResourceConfigData getResourceConfig(IriTerm type) =>
      resources.firstWhere((r) => r.typeIri == type,
          orElse: () =>
              throw ArgumentError('No resource config found for type: $type'));

  SyncEngineConfig withResourcesAdded(List<ResourceConfigData> newResources) {
    final updatedResources = List<ResourceConfigData>.from(resources)
      ..addAll(newResources);
    return SyncEngineConfig(
      resources: updatedResources,
      autoSyncConfig: autoSyncConfig,
    );
  }

  /// Find the GroupIndex configuration for the given indexName.
  (ResourceConfigData, GroupIndexData)? findGroupIndexConfig(String indexName) {
    for (final resource in resources) {
      for (final index in resource.indices) {
        if (index is GroupIndexData && index.localName == indexName) {
          return (resource, index);
        }
      }
    }
    return null;
  }
}
