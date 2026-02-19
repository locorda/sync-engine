/// Parses index RDF documents (FullIndex and GroupIndexTemplate) into configuration objects.
///
/// Enables reading existing index documents from storage and
/// reconstructing the configuration used to generate them.
/// This supports dynamic index discovery for both own and foreign application indices.
library;

import 'package:locorda_core/src/config/sync_engine_config.dart';
import 'package:locorda_core/src/vocab/generated/_index.dart';
import 'package:locorda_core/src/index/index_config_base.dart';
import 'package:locorda_core/src/index/index_rdf_generator.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/util/structure_validation_logger.dart';
import 'package:locorda_rdf_core/core.dart';

/// Result of parsing a FullIndex document.
///
/// Contains the configuration and the indexed class IRI.
class ParsedFullIndex {
  final FullIndexData config;
  final IriTerm indexedClass;

  const ParsedFullIndex({
    required this.config,
    required this.indexedClass,
  });
}

/// Result of parsing a GroupIndexTemplate document.
///
/// Contains the configuration and the indexed class IRI.
class ParsedGroupIndexTemplate {
  final GroupIndexData config;
  final IriTerm indexedClass;

  const ParsedGroupIndexTemplate({
    required this.config,
    required this.indexedClass,
  });
}

/// Parses index RDF documents into complete configuration objects.
///
/// Supports both FullIndex and GroupIndexTemplate documents,
/// enabling storage-based index discovery for multi-application scenarios.
class IndexParser {
  /// Maps index IRIs to their configured local names.
  ///
  /// Built during construction from known config + IndexRdfGenerator.
  final Map<String, String> _iriToLocalName;

  /// Creates an IndexParser.
  ///
  /// If [knownConfig] and [rdfGenerator] are provided, the parser will use
  /// known local names for recognized indices by pre-computing their IRIs.
  /// For unknown indices, a name will be derived from the IRI.
  IndexParser({
    required SyncEngineConfig knownConfig,
    required IndexRdfGenerator rdfGenerator,
  }) : _iriToLocalName = _buildIriToLocalNameMap(knownConfig, rdfGenerator);

  /// Builds a map from index IRIs to local names for all known indices.
  ///
  /// Uses IndexRdfGenerator to compute the canonical IRI for each configured index.
  static Map<String, String> _buildIriToLocalNameMap(
    SyncEngineConfig knownConfig,
    IndexRdfGenerator rdfGenerator,
  ) {
    final map = <String, String>{};

    for (final resourceConfig in knownConfig.resources) {
      for (final indexConfig in resourceConfig.indices) {
        final iri = rdfGenerator.generateIndexOrTemplateIri(
            indexConfig, resourceConfig.typeIri);
        map[iri.value] = indexConfig.localName;
      }
    }

    return map;
  }

  /// Parses a FullIndex document into a complete configuration with indexed class.
  ///
  /// Returns null if the graph doesn't contain a valid FullIndex structure.
  /// Throws ArgumentError if the structure is invalid.
  ParsedFullIndex? parseFullIndex(
    RdfGraph graph,
    IriTerm indexResourceIri,
  ) {
    // Verify it's a FullIndex
    final types =
        graph.getMultiValueObjectList<IriTerm>(indexResourceIri, Rdf.type);
    if (!types.contains(IdxFullIndex.classIri)) {
      return null; // Not a FullIndex
    }

    // Parse common index properties
    final indexedClass = _parseIndexedClass(graph, indexResourceIri);
    if (indexedClass == null) {
      return null; // Invalid without indexed class
    }

    final indexedProperties = _parseIndexedProperties(graph, indexResourceIri);

    // Extract or generate localName
    final localName = _extractLocalName(indexResourceIri);

    // Create config with indexed properties if present
    final config = FullIndexData(
      localName: localName,
      item: indexedProperties.isNotEmpty
          ? IndexItemData(indexedProperties)
          : null,
    );

    return ParsedFullIndex(config: config, indexedClass: indexedClass);
  }

  /// Parses a GroupIndexTemplate document into a complete configuration with indexed class.
  ///
  /// Returns null if the graph doesn't contain a valid GroupIndexTemplate structure.
  /// Throws ArgumentError if the structure is invalid.
  ParsedGroupIndexTemplate? parseGroupIndexTemplate(
    RdfGraph graph,
    IriTerm templateResourceIri,
  ) {
    // Verify it's a GroupIndexTemplate
    final types =
        graph.getMultiValueObjectList<IriTerm>(templateResourceIri, Rdf.type);
    if (!types.contains(IdxGroupIndexTemplate.classIri)) {
      return null; // Not a GroupIndexTemplate
    }

    // Parse common index properties
    final indexedClass = _parseIndexedClass(graph, templateResourceIri);
    if (indexedClass == null) {
      return null; // Invalid without indexed class
    }

    final indexedProperties =
        _parseIndexedProperties(graph, templateResourceIri);

    // Parse grouping properties
    final groupingProperties =
        _parseGroupingProperties(graph, templateResourceIri);
    if (groupingProperties == null) {
      return null; // Invalid GroupIndexTemplate without grouping
    }

    // Extract or generate localName with grouping context
    final localName = _extractLocalName(templateResourceIri);

    // Create config with indexed properties and grouping
    final config = GroupIndexData(
      localName: localName,
      groupingProperties: groupingProperties,
      item: indexedProperties.isNotEmpty
          ? IndexItemData(indexedProperties)
          : null,
    );

    return ParsedGroupIndexTemplate(config: config, indexedClass: indexedClass);
  }

  /// Extracts or generates a local name for an index resource.
  ///
  /// Strategy:
  /// 1. Look up the IRI in the pre-computed map of known indices
  /// 2. If not found, derive a name from the IRI fragment
  /// 3. Last resort: Generate a unique name from the IRI hash
  ///
  /// This enables:
  /// - Consistent naming for own indices (via map lookup)
  /// - Reasonable names for foreign application indices (via IRI)
  String _extractLocalName(IriTerm indexIri) {
    // Try map lookup for known indices
    final knownLocalName = _iriToLocalName[indexIri.value];
    if (knownLocalName != null) {
      return knownLocalName;
    }
    return indexIri.value;
  }

  /// Extracts the indexed class from an index document.
  IriTerm? _parseIndexedClass(RdfGraph graph, IriTerm indexResourceIri) {
    return graph.expectSingleObject<IriTerm>(
      indexResourceIri,
      IdxFullIndex.indexesClass, // Same property for both types
      severity: ExpectationSeverity.critical,
    );
  }

  /// Extracts indexed properties from an index document.
  ///
  /// Returns a set of property IRIs that are indexed.
  /// Returns empty set if no indexed properties are configured.
  Set<IriTerm> _parseIndexedProperties(
      RdfGraph graph, IriTerm indexResourceIri) {
    // Get all IndexedProperty nodes
    final indexedPropertyNodes = graph.getMultiValueObjectList<RdfSubject>(
      indexResourceIri,
      IdxFullIndex.indexedProperty, // Same property for both types
    );

    // Extract the trackedProperty from each IndexedProperty
    final properties = <IriTerm>{};
    for (final node in indexedPropertyNodes) {
      final trackedProperty = graph.findSingleObject<IriTerm>(
        node,
        IdxIndexedProperty.trackedProperty,
      );
      if (trackedProperty != null) {
        properties.add(trackedProperty);
      }
    }

    return properties;
  }

  /// Extracts GroupingProperty list from a GroupIndexTemplate RDF graph.
  ///
  /// Returns null if the graph doesn't contain a valid GroupingRule.
  /// Throws ArgumentError if the structure is invalid.
  List<GroupingPropertyData>? _parseGroupingProperties(
    RdfGraph graph,
    IriTerm templateResourceIri,
  ) {
    // Find the GroupingRule
    final groupingRule = graph.findSingleObject<RdfSubject>(
        templateResourceIri, IdxGroupIndexTemplate.groupedBy);

    if (groupingRule == null) {
      return null; // Not a GroupIndexTemplate
    }

    // Extract all GroupingRuleProperty nodes
    final propertyNodes = graph.getMultiValueObjectList<RdfSubject>(
        groupingRule, IdxGroupingRule.property);

    // Parse each property
    final properties = propertyNodes
        .map((propNode) => _parseGroupingProperty(graph, propNode))
        .nonNulls
        .toList();

    // Sort by hierarchy level, then by predicate IRI (same as generation)
    properties.sort((a, b) {
      final levelCompare = a.hierarchyLevel.compareTo(b.hierarchyLevel);
      if (levelCompare != 0) return levelCompare;
      return a.predicate.value.compareTo(b.predicate.value);
    });

    if (properties.isEmpty) {
      expectationFailed(
          "GroupingRule has no properties (expected at least one)",
          subject: groupingRule,
          predicate: IdxGroupingRule.property,
          graph: graph);
      return null;
    }
    return properties;
  }

  /// Parses a single GroupingRuleProperty node.
  GroupingPropertyData? _parseGroupingProperty(
      RdfGraph graph, RdfSubject propNode) {
    // Extract sourceProperty (required) - CRITICAL because GroupingProperty is unusable without it
    final sourceProperty = graph.expectSingleObject<IriTerm>(
        propNode, IdxGroupingRuleProperty.sourceProperty,
        severity: ExpectationSeverity.critical);

    if (sourceProperty == null) {
      return null; // Cannot proceed without sourceProperty
    }

    // Extract hierarchyLevel (defaults to 1 if not present in RDF, even though it's required in RDF)
    // Together with sourceProperty, forms the identification key for the blank node
    // MINOR because we have a sensible default
    final hierarchyLevel = graph
            .expectSingleObject<LiteralTerm>(
                propNode, IdxGroupingRuleProperty.hierarchyLevel,
                severity: ExpectationSeverity.minor)
            ?.integerValue ??
        1;

    // Extract missingValue (optional)
    final missingValue = graph
        .findSingleObject<LiteralTerm>(
            propNode, IdxGroupingRuleProperty.missingValue)
        ?.value;

    // Extract transforms (optional RDF list)
    final transformObjects = graph.getListObjects<RdfSubject>(
        propNode, IdxGroupingRuleProperty.transform);

    final transforms = transformObjects
        .map((node) => _parseRegexTransform(graph, node))
        .toList();

    return GroupingPropertyData(
      sourceProperty,
      hierarchyLevel: hierarchyLevel,
      missingValue: missingValue,
      transforms: transforms,
    );
  }

  /// Parses a RegexTransform node.
  RegexTransformData _parseRegexTransform(
      RdfGraph graph, RdfSubject transformNode) {
    // Extract pattern (required)
    final pattern = graph
            .findSingleObject<LiteralTerm>(
                transformNode, IdxRegexTransform.pattern)
            ?.value ??
        (throw ArgumentError('RegexTransform missing required pattern'));

    // Extract replacement (required)
    final replacement = graph
            .findSingleObject<LiteralTerm>(
                transformNode, IdxRegexTransform.replacement)
            ?.value ??
        (throw ArgumentError('RegexTransform missing required replacement'));

    return RegexTransformData(pattern, replacement);
  }
}
