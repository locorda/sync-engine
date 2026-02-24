/// Generates RDF graphs for index and shard documents from Dart configurations.
///
/// This class translates Dart index configuration objects (FullIndexConfigBase,
/// GroupIndexConfigBase) into RDF graphs that can be saved as ManagedDocuments
/// using SyncEngine.save().
library;

import 'package:locorda_core/src/config/sync_engine_config.dart';
import 'package:locorda_core/src/vocab/generated/_index.dart';
import 'package:locorda_core/src/index/index_config_base.dart';
import 'package:locorda_core/src/index/shard_manager.dart';
import 'package:locorda_core/src/mapping/resource_locator.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/rdf/xsd.dart';
import 'package:locorda_core/src/sync/shard_document_generator.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:crypto/crypto.dart';
import 'dart:convert';

/// Generates RDF graphs for index resources.
///
/// Translates Dart index configurations into RDF triples suitable for
/// saving as idx:FullIndex, idx:GroupIndexTemplate, idx:GroupIndex, and idx:Shard resources.
class IndexRdfGenerator {
  /// Mapping file IRI for index merge contracts
  static final IriTerm _indexMappingIri =
      IriTerm('https://w3id.org/solid-crdt-sync/mappings/index-v1');

  /// Mapping file IRI for shard merge contracts
  static final IriTerm _shardMappingIri =
      IriTerm('https://w3id.org/solid-crdt-sync/mappings/shard-v1');

  final ResourceLocator _resourceLocator;
  final ShardManager _shardManager;
  const IndexRdfGenerator(
      {required ResourceLocator resourceLocator,
      required ShardManager shardManager})
      : _resourceLocator = resourceLocator,
        _shardManager = shardManager;

  /// Generates RDF graph for a FullIndex resource.
  ///
  /// The resource will use fragment identifier #it per the ManagedDocument pattern.
  /// Uses LocalResourceLocator to generate internal IRIs.
  ///
  /// Example local ID: `indices/recipe/index-full-abc123/index`
  /// Example IRI: `tag:locorda.org,2025:l:{base64(idx:FullIndex)}:{base64(localId)}#it`
  ///
  /// Example:
  /// ```
  /// final config = FullIndexGraphConfig(
  ///   localName: 'notes',
  ///   rootResourceFetchPolicy: RootResourceFetchPolicy.prefetch,
  /// );
  /// final resourceType = SchemaNote.classIri;
  /// final installationIri = IriTerm('...');
  ///
  /// final (resourceIri, graph) = generator.generateFullIndex(
  ///   config: config,
  ///   resourceType: resourceType,
  ///   installationIri: installationIri,
  /// );
  /// ```
  RdfGraph generateFullIndex(
      {required FullIndexData config,
      required IriTerm resourceIri,
      required IriTerm resourceType,
      required IriTerm installationIri,
      required Iterable<IriTerm> shards}) {
    final triples = <Triple>[];

    // 1. Type declaration
    triples.add(Triple(resourceIri, Rdf.type, IdxFullIndex.classIri));

    // 2. Indexed class
    triples.add(Triple(resourceIri, IdxFullIndex.indexesClass, resourceType));

    // 3. Sharding algorithm with initial single shard
    final shardingAlgorithm = BlankNodeTerm();
    triples.add(
        Triple(resourceIri, IdxFullIndex.shardingAlgorithm, shardingAlgorithm));
    triples.addAll(_generateShardingAlgorithm(
      config,
      shardingAlgorithm,
      numberOfShards: 1,
      configVersion: '1_0_0',
    ));

    // 4. Initial empty shard list (will be populated by IndexManager)
    // hasShard triples will be added when first shard is created

    // 5. Population state - set to 'active' for FullIndex (no initial population needed)
    triples.add(Triple(resourceIri, IdxFullIndex.populationState,
        LiteralTerm('active', datatype: Xsd.string)));

    // 6. Reader tracking - this installation reads the index
    triples.add(Triple(resourceIri, IdxFullIndex.readBy, installationIri));

    // 7. Indexed properties (if any)
    if (config.item != null) {
      triples.addNodes(
          resourceIri,
          IdxFullIndex.indexedProperty,
          _generateIndexedProperties(
            config.item!,
            installationIri,
          ));
    }

    // 8. Shards
    triples.addMultiple(resourceIri, IdxFullIndex.hasShard, shards);

    return triples.toRdfGraph();
  }

  IriTerm generateIndexOrTemplateIri(CrdtIndexData index, IriTerm typeIri) =>
      // FIXME: lru cache these IRIs?
      switch (index) {
        FullIndexData _ => generateFullIndexIri(index, typeIri),
        GroupIndexData() => generateGroupIndexTemplateIri(index, typeIri)
      };

  IriTerm generateFullIndexIri(
    FullIndexData config,
    IriTerm typeIri,
  ) {
    // FIXME: should we maybe cache these IRIs somewhere to avoid recomputing them?
    final hash = generateHash(
        typeIri, config.shardingAlgorithmClass, config.hashAlgorithmClass);

    final localId = 'index-full-$hash/index';

    // Generate internal IRI using ResourceLocator
    return _resourceLocator
        .toIri(ResourceIdentifier(IdxFullIndex.classIri, localId, 'index'));
  }

  /// Generates RDF graph for a GroupIndexTemplate resource.
  ///
  /// The resource will use fragment identifier #it per the ManagedDocument pattern.
  /// Uses LocalResourceLocator to generate internal IRIs.
  RdfGraph generateGroupIndexTemplate({
    required GroupIndexData config,
    required IriTerm resourceType,
    required IriTerm resourceIri,
    required IriTerm installationIri,
  }) {
    final triples = <Triple>[];

    // 1. Type declaration
    triples.add(Triple(resourceIri, IdxGroupIndexTemplate.rdfType,
        IdxGroupIndexTemplate.classIri));

    // 2. Indexed class
    triples.add(
        Triple(resourceIri, IdxGroupIndexTemplate.indexesClass, resourceType));

    // 3. Sharding algorithm
    final shardingAlgorithm = BlankNodeTerm();
    triples.add(Triple(resourceIri, IdxGroupIndexTemplate.shardingAlgorithm,
        shardingAlgorithm));
    triples.addAll(_generateShardingAlgorithm(
      config,
      shardingAlgorithm,
      numberOfShards: 1,
      configVersion: '1_0_0',
    ));

    // 4. Grouping rule
    final groupingRule = BlankNodeTerm();
    triples.add(
        Triple(resourceIri, IdxGroupIndexTemplate.groupedBy, groupingRule));
    triples.add(Triple(
        groupingRule, IdxGroupingRule.rdfType, IdxGroupingRule.classIri));

    // Add grouping properties
    for (final prop in config.groupingProperties) {
      final groupingRuleProp = BlankNodeTerm();
      triples.add(
          Triple(groupingRule, IdxGroupingRule.property, groupingRuleProp));
      triples.add(Triple(groupingRuleProp, IdxGroupingRuleProperty.rdfType,
          IdxGroupingRuleProperty.classIri));
      triples.add(Triple(groupingRuleProp,
          IdxGroupingRuleProperty.sourceProperty, prop.predicate));
      triples.add(Triple(
          groupingRuleProp,
          IdxGroupingRuleProperty.hierarchyLevel,
          LiteralTerm(prop.hierarchyLevel.toString(), datatype: Xsd.integer)));

      if (prop.missingValue != null) {
        triples.add(Triple(
            groupingRuleProp,
            IdxGroupingRuleProperty.missingValue,
            LiteralTerm(prop.missingValue!, datatype: Xsd.string)));
      }

      if (prop.transforms != null && prop.transforms!.isNotEmpty) {
        // Create RDF list of transform objects
        final transformNodes = prop.transforms!.map((t) {
          final transformNode = BlankNodeTerm();
          triples.add(Triple(transformNode, IdxRegexTransform.rdfType,
              IdxRegexTransform.classIri));
          triples.add(Triple(transformNode, IdxRegexTransform.pattern,
              LiteralTerm(t.pattern, datatype: Xsd.string)));
          triples.add(Triple(transformNode, IdxRegexTransform.replacement,
              LiteralTerm(t.replacement, datatype: Xsd.string)));
          return transformNode as RdfObject;
        }).toList();

        triples.addRdfList(groupingRuleProp, IdxGroupingRuleProperty.transform,
            transformNodes);
      }
    }

    // 5. Reader tracking
    triples.add(
        Triple(resourceIri, IdxGroupIndexTemplate.readBy, installationIri));

    // 6. Indexed properties (if any)
    if (config.item != null) {
      triples.addNodes(
          resourceIri,
          IdxGroupIndexTemplate.indexedProperty,
          _generateIndexedProperties(
            config.item!,
            installationIri,
          ));
    }

    return triples.toRdfGraph();
  }

  IriTerm generateGroupIndexTemplateIri(
      GroupIndexData config, IriTerm typeIri) {
    // FIXME: should we maybe cache these IRIs somewhere to avoid recomputing them?

    // Generate hash from grouping rule properties per specification
    // Format: sourceProperty|transformList|hierarchyLevel|missingValue
    // Multiple properties sorted by hierarchy level first, then lexicographic IRI ordering
    // Concatenated with & separator
    final sortedProperties = [...config.groupingProperties]..sort((a, b) {
        // Sort by hierarchy level first
        final levelCompare = a.hierarchyLevel.compareTo(b.hierarchyLevel);
        if (levelCompare != 0) return levelCompare;
        // Then by lexicographic IRI ordering
        return a.predicate.value.compareTo(b.predicate.value);
      });

    final groupingRulePropertiesSerialization = sortedProperties.map((prop) {
      // Serialize transform list in canonical format
      final transformList = prop.transforms?.map((t) {
            // JSON-escape pattern and replacement
            final escapedPattern = _jsonEscape(t.pattern);
            final escapedReplacement = _jsonEscape(t.replacement);
            return '<${IdxRegexTransform.classIri.value}>{"pattern":"$escapedPattern","replacement":"$escapedReplacement"}';
          }).join('|') ??
          '';

      return '${prop.predicate.value}|$transformList|${prop.hierarchyLevel}|${prop.missingValue ?? ''}';
    }).join('&');

    // Compute hash per specification: groupingRuleProperties|indexedClassIRI|shardingAlgorithmClass|hashAlgorithm
    final hash = generateHash(
      typeIri,
      config.shardingAlgorithmClass,
      config.hashAlgorithmClass,
      groupingRuleProperties: groupingRulePropertiesSerialization,
    );

    final localId = 'index-grouped-$hash/index';

    // Generate internal IRI using ResourceLocator
    return _resourceLocator.toIri(ResourceIdentifier(
        IdxGroupIndexTemplate.classIri, localId, 'groupIndexTemplate'));
  }

  /// JSON-escapes a string for use in canonical transform format
  String _jsonEscape(String str) {
    return str
        .replaceAll('\\', '\\\\')
        .replaceAll('"', '\\"')
        .replaceAll('\n', '\\n')
        .replaceAll('\r', '\\r')
        .replaceAll('\t', '\\t');
  }

  /// Generates GroupIndex IRI from template IRI and group key.
  ///
  /// Group keys are generated by GroupKeyGenerator from resource properties.
  /// Format: {templateDir}/groups/{groupKey}/index
  ///
  /// Example:
  /// - Template: tag:locorda.org,2025:l:base64(idx:GroupIndexTemplate):base64(index-grouped-e5f6g7h8/index)
  /// - Group key: 2024-08
  /// - Result: tag:locorda.org,2025:l:base64(idx:GroupIndex):base64(index-grouped-e5f6g7h8/groups/2024-08/index)
  IriTerm generateGroupIndexIri(
    IriTerm templateIri,
    String groupKey,
  ) {
    // Extract template's resource identifier
    final templateIdentifier = _resourceLocator.fromIri(
        templateIri.getDocumentIri(),
        expectedTypeIri: IdxGroupIndexTemplate.classIri);

    // Template local ID format: index-grouped-{hash}/index
    // Extract the directory part (index-grouped-{hash})
    final templateId = templateIdentifier.id;
    final split = templateId.split('/');
    if (split.length != 2 || split[1] != 'index') {
      throw ArgumentError(
        'Invalid GroupIndexTemplate ID format: $templateId. Expected: index-grouped-{hash}/index',
      );
    }

    // Generate GroupIndex local ID: {templateDir}/groups/{groupKey}/index
    final groupIndexLocalId = '${split[0]}/groups/$groupKey/index';

    // Generate internal IRI using ResourceLocator
    return _resourceLocator.toIri(
      ResourceIdentifier(IdxGroupIndex.classIri, groupIndexLocalId, 'index'),
    );
  }

  /// Generates RDF graph for an empty Shard resource.
  ///
  /// The resource will use fragment identifier #it per the ManagedDocument pattern.
  /// Uses LocalResourceLocator with local ID: {indexLocalId}/shard-mod-md5-{totalShards}-{shardNumber}-v{version}
  ///
  /// Example shard name: shard-mod-md5-4-0-v1_2_0 means:
  /// - modulo hash sharding
  /// - md5 algorithm
  /// - 4 total shards
  /// - shard number 0
  /// - version 1_2_0
  (IriTerm resourceIri, RdfGraph graph) generateShard({
    required int totalShards,
    required int shardNumber,
    required String configVersion,
    required IriTerm indexResourceIri,
    required IriTerm indexTypeIri,
  }) {
    IriTerm resourceIri = generateShardIri(totalShards, shardNumber,
        configVersion, indexResourceIri, indexTypeIri);

    return (
      resourceIri,
      buildShardAppData(RdfGraph() /* no old data */, resourceIri,
          indexResourceIri, [] /* empty - no containsEntry triples yet */)
    );
  }

  IriTerm generateShardIri(int totalShards, int shardNumber,
      String configVersion, IriTerm indexResourceIri, IriTerm indexTypeIri) {
    // Extract local ID from index document IRI for shard generation
    final indexIdentifier = _resourceLocator.fromIri(
        indexResourceIri.getDocumentIri(),
        expectedTypeIri: indexTypeIri);

    final shardName = _shardManager.generateShardName(
        totalShards: totalShards,
        shardNumber: shardNumber,
        configVersion: configVersion);
    final indexId = indexIdentifier.id;
    final split = indexId.split('/');
    if (split.length < 2) {
      throw ArgumentError(
          'Index IRI document part must have at least two segments separated by /. Got: $indexId');
    }

    // Replace the last segment ('index') with the shard name
    // For FullIndex: 'index-abc/index' -> 'index-abc/shard-xxx'
    // For GroupIndex: 'index-grouped-xxx/groups/Desserts/index' -> 'index-grouped-xxx/groups/Desserts/shard-xxx'
    final shardLocalId =
        '${split.sublist(0, split.length - 1).join('/')}/$shardName';

    // Generate internal IRI using ResourceLocator
    return _resourceLocator
        .toIri(ResourceIdentifier(IdxShard.classIri, shardLocalId, 'shard'));
  }

  /// Generates sharding algorithm blank node triples.
  List<Triple> _generateShardingAlgorithm(
    CrdtIndexConfigBase idxConfig,
    BlankNodeTerm algorithmNode, {
    required int numberOfShards,
    required String configVersion,
    int autoScaleThreshold = 1000,
  }) {
    if (idxConfig.shardingAlgorithmClass != IdxModuloHashSharding.classIri) {
      throw ArgumentError(
          'Sharding algorithm generation currently only supports ${IdxModuloHashSharding.classIri}.');
    }
    if (idxConfig.hashAlgorithmClass != 'md5') {
      throw ArgumentError(
          'Hash algorithm generation currently only supports md5.');
    }
    return [
      Triple(algorithmNode, Rdf.type, IdxModuloHashSharding.classIri),
      Triple(algorithmNode, IdxModuloHashSharding.hashAlgorithm,
          LiteralTerm('md5', datatype: Xsd.string)),
      Triple(algorithmNode, IdxModuloHashSharding.numberOfShards,
          LiteralTerm(numberOfShards.toString(), datatype: Xsd.integer)),
      Triple(algorithmNode, IdxModuloHashSharding.configVersion,
          LiteralTerm(configVersion, datatype: Xsd.string)),
      Triple(algorithmNode, IdxModuloHashSharding.autoScaleThreshold,
          LiteralTerm(autoScaleThreshold.toString(), datatype: Xsd.integer)),
    ];
  }

  /// Generates indexed property blank nodes for an index.
  Iterable<Node> _generateIndexedProperties(
    IndexItemConfigBase itemConfig,
    IriTerm installationIri,
  ) {
    return itemConfig.properties.map((property) {
      final indexedProp = BlankNodeTerm();
      return (
        indexedProp,
        RdfGraph.fromTriples([
          Triple(indexedProp, IdxIndexedProperty.rdfType,
              IdxIndexedProperty.classIri),
          Triple(indexedProp, IdxIndexedProperty.trackedProperty, property),
          Triple(indexedProp, IdxIndexedProperty.readBy, installationIri),
        ])
      );
    });
  }

  /// Generates a short hash from structural index properties for use in IRIs.
  ///
  /// Computes MD5 hash of the canonical serialization of structural properties:
  /// - For FullIndex: indexedClassIRI|shardingAlgorithmClass|hashAlgorithm
  /// - For GroupIndexTemplate: groupingRuleProperties|indexedClassIRI|shardingAlgorithmClass|hashAlgorithm
  ///
  /// Returns the first 8 hex characters.
  ///
  /// This ensures deterministic, convergent index naming across installations.
  String generateHash(
    IriTerm typeIri,
    IriTerm shardingAlgorithmClass,
    String hashAlgorithmClass, {
    String? groupingRuleProperties,
  }) {
    final input = groupingRuleProperties != null
        ? '$groupingRuleProperties|${typeIri.value}|${shardingAlgorithmClass.fragment}|$hashAlgorithmClass'
        : '${typeIri.value}|${shardingAlgorithmClass.fragment}|$hashAlgorithmClass';
    final bytes = utf8.encode(input);
    final digest = md5.convert(bytes);
    return digest.toString().substring(0, 8);
  }

  /// Returns the merge contract IRI for index resources.
  IriTerm get indexMappingIri => _indexMappingIri;

  /// Returns the merge contract IRI for shard resources.
  IriTerm get shardMappingIri => _shardMappingIri;
}
