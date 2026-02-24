import 'package:locorda_core/locorda_core.dart';

export 'package:locorda_core/locorda_core.dart'
    show GroupingPropertyData, RegexTransformData, ItemFetchPolicy, defaultIndexLocalName;

class IndexItemConfig extends IndexItemConfigBase {
  final Type itemType;
  const IndexItemConfig(this.itemType, super.properties);
}

sealed class CrdtIndexConfig extends CrdtIndexConfigBase {
  @override
  IndexItemConfig? get item;
}

class FullIndexConfig extends FullIndexConfigBase implements CrdtIndexConfig {
  @override
  final IndexItemConfig? item;

  const FullIndexConfig({
    super.localName = defaultIndexLocalName,
    this.item,
    super.itemFetchPolicy = ItemFetchPolicy.prefetch,
  }) : super(item: item);
}

class GroupIndexConfig extends GroupIndexConfigBase implements CrdtIndexConfig {
  final Type groupKeyType;

  @override
  final IndexItemConfig? item;

  const GroupIndexConfig(
    this.groupKeyType, {
    super.localName = defaultIndexLocalName,
    this.item,
    super.groupingProperties = const [],
  }) : super(item: item);
}

class ResourceConfig extends ResourceConfigBase {
  final Type type;

  @override
  final List<CrdtIndexConfig> indices;

  ResourceConfig({
    required this.type,
    required super.crdtMapping,
    this.indices = const [FullIndexConfig()],
  }) : super(indices: indices);
}

class LocordaConfig extends ConfigBase {
  @override
  final List<ResourceConfig> resources;

  LocordaConfig({
    required this.resources,
    super.autoSyncConfig = const AutoSyncConfig.enabled(),
  }) : super(resources: resources);

  ResourceConfig? getResourceConfig(Type type) {
    return resources.where((r) => r.type == type).firstOrNull;
  }
}
