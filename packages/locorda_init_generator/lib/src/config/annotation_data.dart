/// Data classes for extracted annotation information.
library;

import '../code_generation/code.dart';

/// Immutable data extracted from @RootResource annotations.
class RootResourceData {
  final Code className;
  final Code? classIri;

  /// Code for the crdtMapping IRI with proper import tracking.
  /// Preserves const interpolation and handles imports automatically.
  final Code crdtMapping;
  final bool generateCrdtMapping;
  final FullIndexData fullIndex;

  const RootResourceData({
    required this.className,
    required this.classIri,
    required this.crdtMapping,
    required this.generateCrdtMapping,
    required this.fullIndex,
  });
}

class FullIndexData {
  final bool isEnabled;
  final String localName;
  final String policy; // 'prefetch' | 'onRequest'

  const FullIndexData({
    required this.isEnabled,
    required this.localName,
    required this.policy,
  });
}

/// Immutable data extracted from @GroupKey annotations.
class GroupKeyData {
  final Code className;
  final Code resourceTypeName;
  final String? localName;
  final List<GroupingPropertyData> groupingProperties;

  const GroupKeyData({
    required this.className,
    required this.resourceTypeName,
    required this.localName,
    required this.groupingProperties,
  });
}

class GroupingPropertyData {
  final Code property;
  final List<RegexTransformData> transforms;

  const GroupingPropertyData({
    required this.property,
    required this.transforms,
  });
}

class RegexTransformData {
  final String pattern;
  final String replacement;

  const RegexTransformData({required this.pattern, required this.replacement});
}

/// Immutable data extracted from @IndexItem annotations.
class IndexItemData {
  final Code? className;

  /// Resource type name from IndexItemIriStrategy
  final Code resourceTypeName;

  /// GroupKey type name — null for FullIndex items
  final Code? groupKeyTypeName;

  /// Set of property IRIs (extracted from @RdfProperty fields)
  final List<IndexPropertyData> properties;

  const IndexItemData({
    required this.className,
    required this.resourceTypeName,
    required this.groupKeyTypeName,
    required this.properties,
  });

  bool get isFullIndexItem => groupKeyTypeName == null;
  bool get isGroupIndexItem => groupKeyTypeName != null;
}

class IndexPropertyData {
  /// The Code for the IRI term with proper import tracking
  final Code code;

  const IndexPropertyData({required this.code});
}
