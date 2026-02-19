/// Index configuration classes for defining CRDT sync indices.
///
/// These classes define how data should be indexed for efficient sync and querying.
/// The framework uses these configurations to generate idx:GroupIndexTemplate
/// and idx:FullIndex RDF resources on the Solid Pod.
library;

import 'package:locorda_core/src/vocab/generated/_index.dart';
import 'package:locorda_core/src/rdf/xsd.dart';
import 'package:locorda_rdf_core/core.dart';

sealed class ItemFetchPolicy {
  /// Proactive item fetching - all items referenced in the index are automatically
  /// downloaded from the pod to local when they are updated remotely or not already present locally.
  static const prefetch = Prefetch._();

  /// Lazy item fetching - items are only downloaded from the pod to local
  /// when explicitly requested by the application. Once downloaded, items are
  /// automatically updated when remote changes occur.
  static const onRequest = OnRequest._();

  const ItemFetchPolicy._();

  /// Prefetch not all items, but only those that have a given predicate with one of the given object values
  static PrefetchFiltered prefetchFiltered(
          IriTerm predicate, Set<RdfObject> acceptedObjectValues) =>
      PrefetchFiltered._(predicate, acceptedObjectValues);

  /// Serialize to a JSON-compatible map for database storage
  Map<String, dynamic> toMap();

  /// Deserialize from a JSON-compatible map
  static ItemFetchPolicy fromMap(Map<String, dynamic> map) {
    final type = map['type'] as String;
    switch (type) {
      case 'prefetch':
        return ItemFetchPolicy.prefetch;
      case 'onRequest':
        return ItemFetchPolicy.onRequest;
      case 'prefetchFiltered':
        return PrefetchFiltered._(
          IriTerm(map['predicate'] as String),
          (map['acceptedObjectValues'] as List<dynamic>)
              .map((e) => _deserializeRdfObject(e as Map<String, dynamic>))
              .toSet(),
        );
      default:
        throw ArgumentError('Unknown ItemFetchPolicy type: $type');
    }
  }

  static RdfObject _deserializeRdfObject(Map<String, dynamic> map) {
    final objType = map['type'] as String;
    switch (objType) {
      case 'iri':
        return IriTerm(map['value'] as String);
      case 'literal':
        return LiteralTerm(
          map['value'] as String,
          datatype: map['datatype'] != null
              ? IriTerm(map['datatype'] as String)
              : null,
          language: map['language'] as String?,
        );
      case 'blank':
        throw UnsupportedError(
            'Blank nodes are not supported in ItemFetchPolicy serialization');
      default:
        throw ArgumentError('Unknown RdfObject type: $objType');
    }
  }

  static Map<String, dynamic> _serializeRdfObject(RdfObject obj) {
    if (obj is IriTerm) {
      return {'type': 'iri', 'value': obj.value};
    } else if (obj is LiteralTerm) {
      return {
        'type': 'literal',
        'value': obj.value,
        if (obj.datatype != Xsd.string && obj.datatype != Rdf.langString)
          'datatype': obj.datatype.value,
        if (obj.language != null) 'language': obj.language,
      };
    } else if (obj is BlankNodeTerm) {
      throw UnsupportedError(
          'Blank nodes are not supported in ItemFetchPolicy serialization');
    }
    throw ArgumentError('Unsupported RdfObject type: ${obj.runtimeType}');
  }
}

class Prefetch extends ItemFetchPolicy {
  const Prefetch._() : super._();

  @override
  Map<String, dynamic> toMap() => {'type': 'prefetch'};
}

class OnRequest extends ItemFetchPolicy {
  const OnRequest._() : super._();

  @override
  Map<String, dynamic> toMap() => {'type': 'onRequest'};
}

class PrefetchFiltered extends ItemFetchPolicy {
  final IriTerm filterPredicate;
  final Set<RdfObject> acceptedObjectValues;

  const PrefetchFiltered._(this.filterPredicate, this.acceptedObjectValues)
      : super._();

  @override
  Map<String, dynamic> toMap() => {
        'type': 'prefetchFiltered',
        'predicate': filterPredicate.value,
        'acceptedObjectValues': acceptedObjectValues
            .map((obj) => ItemFetchPolicy._serializeRdfObject(obj))
            .toList(),
      };
}

/// Defines how index items are structured and deserialized.
///
/// Specifies both the Dart type for deserialization and the RDF properties
/// to include in index items for efficient querying.
abstract class IndexItemConfigBase {
  /// RDF properties to include in index items
  final Set<IriTerm> properties;

  const IndexItemConfigBase(this.properties);
}

/// The Dart type being indexed (e.g., Note - the source data type) is inferred from the ResourceConfig
/// which contains this index configuration.
abstract class CrdtIndexConfigBase {
  IriTerm get shardingAlgorithmClass => IdxModuloHashSharding
      .classIri; // Always use the same sharding algorithm for full indices
  String get hashAlgorithmClass => 'md5'; // Always use the same hash algorithm

  /// Local name for referencing this index within the app (not used in Remote Storage structure).
  /// Must be unique per index item type
  /// across all resources (e.g., if multiple resources use NoteIndexEntry,
  /// they must have different local names).
  /// Used for referencing in indexUpdatesStream<T>(localName) calls.
  String get localName;

  /// Configuration for index items (type and properties) - if null then we
  /// do not have index properties and the index items cannot be queried, but
  /// the synchronization of the data still happens.
  IndexItemConfigBase? get item;

  const CrdtIndexConfigBase();
}

/// Defines a grouped index configuration that will generate an idx:GroupIndexTemplate.
///
/// Groups data by time periods or other criteria for efficient partial sync.
/// Example: Group notes by year-month for scalable historical data handling.
abstract class GroupIndexConfigBase extends CrdtIndexConfigBase {
  /// Local name for referencing this index within the app (not used in Remote Storage structure)
  @override
  final String localName;

  /// Configuration for index items (type and properties)
  @override
  final IndexItemConfigBase? item;

  /// Properties used for grouping resources, must be in sync with the groupKeyType
  final List<GroupingPropertyData> groupingProperties;

  const GroupIndexConfigBase({
    required this.localName,
    this.item,
    required this.groupingProperties,
  }) : assert(groupingProperties.length > 0,
            'GroupIndex requires at least one grouping property');
}

/// Defines a full index configuration that will generate an idx:FullIndex.
///
/// Creates a single index covering an entire dataset for bounded collections.
/// Example: All user contacts, recipe collection, document library.
abstract class FullIndexConfigBase extends CrdtIndexConfigBase {
  /// Local name for referencing this index within the app (not used in Pod structure), must be unique
  /// within the app.
  @override
  final String localName;

  /// Configuration for index items (type and properties)
  @override
  final IndexItemConfigBase? item;

  /// Policy for fetching index items from the Pod to local storage.
  ///
  /// **IMPORTANT:** Some backends (e.g. Google Drive) store all resources
  /// embedded in the shards document and thus do not support lazy fetching
  /// of individual resources. In such cases,
  /// the itemFetchPolicy will be automatically overridden here to `prefetch`
  /// regardless of the originally specified configuration.
  ///
  /// So, an application that originally specified `onRequest` fetching might
  /// actually get `prefetch` here when using such backends.
  ///
  final ItemFetchPolicy itemFetchPolicy;

  const FullIndexConfigBase({
    required this.localName,
    this.item,
    ItemFetchPolicy? itemFetchPolicy,
  }) : itemFetchPolicy = itemFetchPolicy ?? ItemFetchPolicy.prefetch;
}

/// Defines how a property should be used for grouping in a GroupIndex.
///
/// Extracts group identifiers from RDF property values using format patterns.
/// Example: Extract 'yyyy-MM' from schema:dateCreated to group by month.
/// A regex transform rule for extracting group keys from RDF literal values
/// Uses cross-platform compatible regex subset with deterministic list processing
class RegexTransformData {
  /// Cross-platform compatible regex pattern (no alternation, no named character classes)
  final String pattern;

  /// Replacement template with ${n} backreferences to capture groups
  final String replacement;

  const RegexTransformData(this.pattern, this.replacement);

  factory RegexTransformData.fromJson(Map<String, dynamic> json) {
    final pattern = json['pattern'] as String;
    final replacement = json['replacement'] as String;
    return RegexTransformData(pattern, replacement);
  }

  Map<String, dynamic> toJson() {
    return {
      'pattern': pattern,
      'replacement': replacement,
    };
  }

  @override
  String toString() => 'RegexTransform($pattern -> $replacement)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RegexTransformData &&
          runtimeType == other.runtimeType &&
          pattern == other.pattern &&
          replacement == other.replacement;

  @override
  int get hashCode => pattern.hashCode ^ replacement.hashCode;
}

class GroupingPropertyData {
  /// RDF predicate IRI for the source property (e.g., schema:dateCreated)
  final IriTerm predicate;

  final int hierarchyLevel;

  /// Optional regex transforms for extracting group values from the property
  /// Example: RegexTransform("^([0-9]{4})-([0-9]{2})-([0-9]{2})\$", "\${1}-\${2}")
  /// extracts "2025-08" from date values like "2025-08-15".
  ///
  /// Note that the transforms are applied in order, so multiple transforms can be
  /// chained together for more complex extraction logic - the first matching regex wins.
  ///
  /// Also note that the transforms operate on the RDF representation of the property value - not on the dart object.
  /// For literals, transforms operate on the lexical value (without language tag or datatype);
  /// for IRIs, transforms operate on the IRI string.
  ///
  /// If not specified, the RDF representation of the property value is used as-is.
  /// For literals, this is the lexical value (without language tag or datatype); for IRIs, the IRI string.
  ///
  final List<RegexTransformData>? transforms;

  /// Value to use when the source property is missing
  /// If null, resources missing the property are excluded from the index
  /// Example: 'unknown' to group all missing values together
  final String? missingValue;

  const GroupingPropertyData(
    this.predicate, {
    this.transforms,
    this.hierarchyLevel = 1,
    this.missingValue,
  });

  factory GroupingPropertyData.fromJson(Map<String, dynamic> json) {
    final predicate = IriTerm(json['predicate'] as String);
    final hierarchyLevel = (json['hierarchyLevel'] as int?) ?? 1;
    final missingValue = json['missingValue'] as String?;
    final transformsJson = json['transforms'] as List<dynamic>?;
    final transforms = transformsJson
        ?.map((t) => RegexTransformData.fromJson(t as Map<String, dynamic>))
        .toList(growable: false);

    return GroupingPropertyData(
      predicate,
      hierarchyLevel: hierarchyLevel,
      missingValue: missingValue,
      transforms: transforms,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'predicate': predicate.value,
      'hierarchyLevel': hierarchyLevel,
      if (missingValue != null) 'missingValue': missingValue,
      if (transforms != null)
        'transforms': transforms!.map((t) => t.toJson()).toList(),
    };
  }
}
