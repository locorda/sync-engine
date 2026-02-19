/// Generates locorda_config.g.dart from collected annotation data.
library;

import '../code_generation/dart_formatter.dart';
import '../code_generation/code.dart';
import 'annotation_data.dart';

const _locordaObjectsImport = 'package:locorda_objects/locorda_objects.dart';
const _locordaCoreImport = 'package:locorda_core/locorda_core.dart';

Code locordaObjects(String name) {
  return Code.type(name, importUri: _locordaObjectsImport);
}

Code locordaCore(String name) {
  return Code.type(name, importUri: _locordaCoreImport);
}

/// Generates locorda_config.g.dart from collected annotation data.
class ConfigCodeGenerator {
  final List<RootResourceData> rootResources;
  final List<GroupKeyData> groupKeys;
  final List<IndexItemData> indexItems;
  final CodeFormatter _formatter;

  ConfigCodeGenerator({
    required this.rootResources,
    required this.groupKeys,
    required this.indexItems,
    CodeFormatter? formatter,
  }) : _formatter = formatter ?? DartCodeFormatter();

  /// Generates the complete file content.
  String generate() => _formatter.formatCode(CodeResolver.toDartFileContent(
        '''
  // GENERATED CODE - DO NOT MODIFY BY HAND
  // ignore_for_file: unused_import, depend_on_referenced_packages, unnecessary_import, implementation_imports
  
  /// Generated LocordaConfig from annotations.
  ///
  /// All crdtMapping IRIs are static, app-owned, absolute IRIs
  /// fully determined at compile time from annotation values.
  library;
  ''',
        {
          _locordaObjectsImport: '',
          _locordaCoreImport: '',
        },
        locordaObjects('LocordaConfig') +
            ' generateLocordaConfig() => ' +
            locordaObjects('LocordaConfig').newInstance({
              'resources':
                  rootResources.map((r) => _newResourceConfig(r)).toList(),
            }) +
            ';',
      ));

  bool _isEqual(Code a, Code b) {
    // Simple equality check based on the generated code string
    return a.code == b.code;
  }

  Code _newResourceConfig(RootResourceData resource) {
    final resourceGroupKeys = groupKeys
        .where((gk) => _isEqual(gk.resourceTypeName, resource.className));
    final hasFullIndex = resource.fullIndex.isEnabled;

    return locordaObjects('ResourceConfig').newInstance(
      {
        "type": resource.className,
        "crdtMapping": core('Uri').call('parse', [
          resource.crdtMapping,
        ]),
        if (hasFullIndex || resourceGroupKeys.isNotEmpty)
          // Find indices for this resource
          'indices': [
            if (hasFullIndex) _newFullIndex(resource),
            ...resourceGroupKeys.map((gk) => _newGroupIndex(gk))
          ],
      },
    );
  }

  Code _newFullIndex(RootResourceData resource) {
    // Find FullIndex item
    final fullIndexItem = indexItems.firstWhere(
      (item) =>
          _isEqual(item.resourceTypeName, resource.className) &&
          item.isFullIndexItem,
      orElse: () => IndexItemData(
        className: null,
        resourceTypeName: resource.className,
        groupKeyTypeName: null,
        properties: const [],
      ),
    );
    return locordaObjects('FullIndexConfig').newInstance(
      {
        if (resource.fullIndex.localName != 'default')
          "localName": resource.fullIndex.localName,
        if (fullIndexItem.className != null &&
            fullIndexItem.properties.isNotEmpty)
          'item': locordaObjects('IndexItemConfig').newInstance([
            fullIndexItem.className!,
            fullIndexItem.properties.map((prop) => prop.code).toSet(),
          ]),
        if (resource.fullIndex.policy != 'prefetch')
          'itemFetchPolicy': locordaCore('ItemPrefetchPolicy')
              .field(resource.fullIndex.policy),
      },
    );
  }

  Code _newGroupIndex(GroupKeyData groupKey) {
    // Find GroupIndex item
    final groupIndexItem = indexItems.firstWhere(
      (item) => _isEqual(item.groupKeyTypeName!, groupKey.className),
      orElse: () => IndexItemData(
        className: null,
        resourceTypeName: groupKey.resourceTypeName,
        groupKeyTypeName: groupKey.className,
        properties: const [],
      ),
    );

    return locordaObjects('GroupIndexConfig').newInstance([
      groupKey.className
    ], {
      if (groupKey.localName != null && groupKey.localName != 'default')
        "localName": groupKey.localName,
      if (groupKey.groupingProperties.isNotEmpty)
        'groupingProperties': groupKey.groupingProperties.map((prop) {
          return locordaCore('GroupingProperty').newInstance([
            prop.property
          ], {
            if (prop.transforms.isNotEmpty)
              'transforms': prop.transforms.map((transform) {
                return locordaCore('RegexTransform').newInstance([
                  "r'${transform.pattern}'",
                  "r'${transform.replacement}'",
                ]);
              }).toList(),
          });
        }).toList(),
      if (groupIndexItem.className != null &&
          groupIndexItem.properties.isNotEmpty)
        'item': locordaObjects('IndexItemConfig').newInstance([
          groupIndexItem.className!,
          groupIndexItem.properties.map((prop) => prop.code).toSet(),
        ]),
    });
  }
}
