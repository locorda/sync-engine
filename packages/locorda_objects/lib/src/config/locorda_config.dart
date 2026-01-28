import 'package:locorda_core/locorda_core.dart';

export 'package:locorda_core/locorda_core.dart'
    show GroupingProperty, RegexTransform, ItemFetchPolicy;

const defaultIndexLocalName = "default";

class IndexItem extends IndexItemConfigBase {
  final Type itemType;
  const IndexItem(this.itemType, super.properties);
}

sealed class CrdtIndex extends CrdtIndexConfigBase {
  @override
  IndexItem? get item;
}

class FullIndex extends FullIndexConfigBase implements CrdtIndex {
  @override
  final IndexItem? item;

  const FullIndex({
    super.localName = defaultIndexLocalName,
    this.item,
    super.itemFetchPolicy = ItemFetchPolicy.prefetch,
  }) : super(item: item);
}

class GroupIndex extends GroupIndexConfigBase implements CrdtIndex {
  final Type groupKeyType;

  @override
  final IndexItem? item;

  const GroupIndex(
    this.groupKeyType, {
    super.localName = defaultIndexLocalName,
    this.item,
    super.groupingProperties = const [],
  }) : super(item: item);
}

class ResourceConfig extends ResourceConfigBase {
  final Type type;

  @override
  final List<CrdtIndex> indices;

  ResourceConfig({
    required this.type,
    required super.crdtMapping,
    this.indices = const [FullIndex()],
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
