/// Manages index lifecycle including creation, shard management, and entry operations.
///
/// The IndexManager coordinates index and shard operations using IndexRdfGenerator
/// and ShardManager to create and maintain indices according to the specification.
library;

import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_core/src/crdt_document_manager.dart';
import 'package:locorda_core/src/standard_sync_engine.dart';
import 'package:locorda_core/src/vocab/generated/_index.dart';
import 'package:locorda_core/src/index/index_discovery.dart';
import 'package:locorda_core/src/util/build_effective_config.dart';
import 'package:locorda_core/src/index/index_property_resolver.dart';
import 'package:locorda_core/src/index/index_rdf_generator.dart';
import 'package:locorda_core/src/index/shard_determiner.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/util/retry.dart';
import 'package:logging/logging.dart';
import 'package:locorda_rdf_core/core.dart';

final _log = Logger('IndexManager');

/// Manages index and shard operations for the sync system.
///
/// Responsibilities:
/// - Creates indices during initialization based on configuration
/// - Creates initial shards for each index
/// - Adds entries to appropriate shards
/// - Handles shard scaling when thresholds are exceeded
class IndexManager {
  final CrdtDocumentManager _documentManager;
  final IndexRdfGenerator _rdfGenerator;
  final IndexPropertyResolver _propertyResolver;
  final Storage _storage;
  final ConfigService _configService;
  final IriTerm _installationIri;
  final IndexDiscovery _indexDiscovery;
  final ShardDeterminer _shardDeterminer;

  SyncEngineConfig get _config => _configService.currentConfig;

  IndexManager({
    required CrdtDocumentManager crdtDocumentManager,
    required IndexRdfGenerator rdfGenerator,
    required Storage storage,
    required IriTerm installationIri,
    required ConfigService configService,
    required IndexDiscovery indexDiscovery,
    required ResourceLocator resourceLocator,
    required ShardDeterminer shardDeterminer,
  })  : _documentManager = crdtDocumentManager,
        _rdfGenerator = rdfGenerator,
        _storage = storage,
        _configService = configService,
        _propertyResolver = IndexPropertyResolver(
            storage: storage, resourceLocator: resourceLocator),
        _installationIri = installationIri,
        _indexDiscovery = indexDiscovery,
        _shardDeterminer = shardDeterminer;

  /// Initializes all indices defined in the configuration.
  ///
  /// Creates FullIndex or GroupIndexTemplate documents for each resource type
  /// and their initial shards. Should be called once during setup after
  /// installation document creation.
  ///
  /// Returns the number of indices created (useful for testing).
  Future<int> initializeIndices() async {
    var createdCount = 0;
    var anyCreated = false;

    // Make sure to create indices in the correct, deterministic order
    for (final (indexConfig, resourceTypeIri) in _config.allIndicesInOrder) {
      // Create index based on type
      final created = switch (indexConfig) {
        FullIndexData _ => await _createFullIndex(indexConfig, resourceTypeIri),
        GroupIndexData _ =>
          await _createGroupIndexTemplate(indexConfig, resourceTypeIri),
      };
      if (created) anyCreated = true;

      createdCount++;
    }

    // Meta-index documents (e.g. the IoI — Index of Indices) cannot determine
    // their own shard during initial creation because their index document
    // does not exist yet at that point. Now that all indices are created,
    // re-save them so shard determination succeeds and they get proper
    // idx:belongsToIndexShard assignments + index entries in their own shard.
    if (anyCreated) {
      await _reconcileMetaIndexShards();
    }

    return createdCount;
  }

  /// Creates a FullIndex with its initial shard.
  ///
  /// Returns `true` if the index was created, `false` if it already existed.
  Future<bool> _createFullIndex(
    FullIndexData config,
    IriTerm resourceType,
  ) async {
    // Generate local ID from config
    final indexResourceIri =
        _rdfGenerator.generateFullIndexIri(config, resourceType);
    final indexDocumentIri = indexResourceIri.getDocumentIri();

    if (await _documentManager.hasDocument(indexDocumentIri)) {
      // Index already exists, skip creation
      return false;
    }

    // Create initial shard
    final (shardResourceIri, shardGraph) = _rdfGenerator.generateShard(
      totalShards: 1,
      shardNumber: 0,
      configVersion: '1_0_0',
      indexResourceIri: indexResourceIri,
      indexTypeIri: IdxFullIndex.classIri,
    );

    // Generate index RDF
    final indexGraph = _rdfGenerator.generateFullIndex(
      config: config,
      resourceIri: indexResourceIri,
      resourceType: resourceType,
      installationIri: _installationIri,
      shards: [shardResourceIri],
    );

    // Important: first save shard document - because we will skip this entire
    // block if the index document already exists, so we must ensure the
    // index document is saved last.
    if (!(await _documentManager
        .hasDocument(shardResourceIri.getDocumentIri()))) {
      await _saveWithRetry(
        IdxShard.classIri,
        shardGraph,
        context: 'shard for FullIndex $indexResourceIri',
        // Shard clock is generated from Item clocks, so initialize with 0
        physicalTime: 0,
      );
    }

    // Save index document
    await _saveWithRetry(
      IdxFullIndex.classIri,
      indexGraph,
      context: 'FullIndex $indexResourceIri',
    );
    return true;
  }

  /// Creates a GroupIndexTemplate.
  ///
  /// Returns `true` if the template was created, `false` if it already existed.
  Future<bool> _createGroupIndexTemplate(
    GroupIndexData config,
    IriTerm resourceType,
  ) async {
    final templateResourceIri =
        _rdfGenerator.generateGroupIndexTemplateIri(config, resourceType);
    if (await _documentManager
        .hasDocument(templateResourceIri.getDocumentIri())) {
      // Template already exists, skip creation
      return false;
    }
    // Generate template RDF
    final templateGraph = _rdfGenerator.generateGroupIndexTemplate(
      config: config,
      resourceIri: templateResourceIri,
      resourceType: resourceType,
      installationIri: _installationIri,
    );

    // Save template document
    // GroupIndexTemplate doesn't have shards - those are created per group

    await _saveWithRetry(
      IdxGroupIndexTemplate.classIri,
      templateGraph,
      context: 'GroupIndexTemplate $templateResourceIri',
    );
    return true;
  }

  /// Creates index entries for meta-index documents that could not determine
  /// their own shard during initial creation.
  ///
  /// During initial creation, the IoI (Index of FullIndices) cannot determine
  /// which shard it belongs to because its own index document does not exist
  /// yet — `ShardDeterminer` skips shard determination for meta types when
  /// the index document is absent (the `maySkip` guard). Now that all indices
  /// are created, we run shard determination again and create the index entry
  /// directly. The document's `idx:belongsToIndexShard` triple will be added
  /// later during sync by the CRDT reconciliation step.
  Future<void> _reconcileMetaIndexShards() async {
    // Only the IoI (Index of Indices) has a chicken-and-egg problem: it indexes
    // FullIndex documents and is itself a FullIndex, so it can't find its own
    // shard during initial creation. All other meta-indices (IoGIT, IoGI) are
    // also FullIndex documents but can resolve their shard via the IoI (or its
    // fallback in discoverIndices).
    final ioiConfig = _config
        .getResourceConfig(IdxFullIndex.classIri)
        .getIndexByName(IndexNames.fullIndices) as FullIndexData;

    final indexResourceIri =
        _rdfGenerator.generateFullIndexIri(ioiConfig, IdxFullIndex.classIri);
    final indexDocumentIri = indexResourceIri.getDocumentIri();

    final storedDoc = await _storage.getDocument(indexDocumentIri);
    if (storedDoc == null) {
      _log.warning('IoI document not found: ${indexDocumentIri.debug}');
      return;
    }

    final shardResult = await _shardDeterminer.determineShards(
      IdxFullIndex.classIri,
      indexResourceIri,
      storedDoc.document,
      mode: ShardDeterminationMode.lenient,
    );

    if (shardResult.shards.isEmpty) {
      _log.fine('No shards determined for IoI ${indexResourceIri.debug}');
      return;
    }

    final clockHash = storedDoc.document
        .findSingleObject<LiteralTerm>(
            indexDocumentIri, SyncManagedDocument.crdtClockHash)
        ?.value;
    if (clockHash == null) {
      _log.warning('IoI ${indexDocumentIri.debug} has no clockHash');
      return;
    }

    final shardDocumentIris =
        shardResult.shards.map((s) => s.getDocumentIri()).toSet();
    final indexedPropertiesByShardDocumentIri = await _propertyResolver
        .resolveIndexedPropertiesBatch(shardDocumentIris);

    final entries = await _buildShardIndexEntryWrites(
      IdxFullIndex.classIri,
      indexResourceIri,
      clockHash,
      storedDoc.document,
      shardResult.shards,
      storedDoc.metadata.ourPhysicalClock,
      storedDoc.metadata.updatedAt,
      indexedPropertiesByShardDocumentIri,
    );

    if (entries.isNotEmpty) {
      await _storage.saveIndexEntries(entries);
      _log.fine('Created ${entries.length} index entries for IoI '
          '${indexResourceIri.debug}');
    }
  }

  /// Creates a GroupIndex that was resolved during shard determination but
  /// does not yet exist locally.
  ///
  /// Uses IndexDiscovery to load the GroupIndexTemplate configuration dynamically,
  /// supporting both own and foreign application templates.
  Future<void> _createMissingGroupIndex(ResolvedGroupIndex resolved) async {
    // Use IndexDiscovery to load the template configuration
    // This supports both own and foreign templates via the cache infrastructure
    final templateConfig = await _indexDiscovery.discoverGroupIndexTemplate(
      resolved.templateIri,
      mode: ShardDeterminationMode
          .strict, // Must succeed - data consistency critical
    );

    if (templateConfig == null) {
      throw StateError(
          'Could not load GroupIndexTemplate configuration for ${resolved.templateIri.debug}. '
          'Template may not be properly indexed in groupIndexTemplates meta-index.');
    }

    await _createGroupIndex(
      templateConfig,
      resolved.typeIri,
      resolved.templateIri,
      resolved.groupKey,
      resolved.groupIndexIri,
    );
  }

  /// Creates a new GroupIndex instance for a specific group.
  ///
  /// Creates the GroupIndex document and its initial shard(s) based on the
  /// template's sharding configuration.
  Future<void> _createGroupIndex(
    GroupIndexData config,
    IriTerm typeIri,
    IriTerm templateIri,
    String groupKey,
    IriTerm groupIndexIri,
  ) async {
    // Generate initial shard
    final (shardResourceIri, shardGraph) = _rdfGenerator.generateShard(
      totalShards: 1, // Start with single shard per group
      shardNumber: 0,
      configVersion: '1_0_0',
      indexResourceIri: groupIndexIri,
      indexTypeIri: IdxGroupIndex.classIri,
    );

    // Generate GroupIndex RDF
    final groupIndexGraph = _generateGroupIndex(
      config: config,
      resourceType: typeIri,
      resourceIri: groupIndexIri,
      templateIri: templateIri,
      shards: [shardResourceIri],
    );

    // Save shard document first (same pattern as FullIndex)
    if (!(await _documentManager
        .hasDocument(shardResourceIri.getDocumentIri()))) {
      await _saveWithRetry(
        IdxShard.classIri,
        shardGraph,
        context: 'shard for GroupIndex $groupIndexIri',
        // Shard clock is generated from Item clocks, so initialize with 0
        physicalTime: 0,
      );
    }

    // Save GroupIndex document
    await _saveWithRetry(
      IdxGroupIndex.classIri,
      groupIndexGraph,
      context: 'GroupIndex $groupIndexIri',
    );
  }

  /// Saves a document and updates indices with retry logic for concurrent updates.
  ///
  /// Retries up to 3 times on [ConcurrentUpdateException].
  /// Throws [StateError] if all retries fail.
  Future<DocumentSaveResult?> _saveWithRetry(
    IriTerm type,
    RdfGraph appData, {
    required String context,
    int? physicalTime,
    int? logicalTime,
  }) =>
      retryOnConflict(
          () => _save(type, appData,
              physicalTime: physicalTime, logicalTime: logicalTime),
          debugOperationName: 'save $context',
          log: _log);

  /// Internal save method that throws [ConcurrentUpdateException] on optimistic lock failure.
  Future<DocumentSaveResult?> _save(IriTerm type, RdfGraph appData,
      {int? physicalTime, int? logicalTime}) async {
    final saved = await _documentManager.save(type, appData,
        physicalTime: physicalTime, logicalTime: logicalTime);
    if (saved != null) {
      await updateIndices(
          document: saved.crdtDocument,
          documentIri: saved.documentIri,
          resourceTypeIri: type,
          physicalTime: saved.physicalTime,
          updatedAt: saved.updatedAt,
          resolvedGroupIndices: saved.resolvedGroupIndices);
    }
    return saved;
  }

  Future<void> updateIndices(
      {required RdfGraph document,
      required IriTerm documentIri,
      required IriTerm resourceTypeIri,
      required int physicalTime,
      required int updatedAt,
      required Iterable<ResolvedGroupIndex> resolvedGroupIndices}) async {
    final requests = await prepareIndexEntryWrites(
      document: document,
      documentIri: documentIri,
      resourceTypeIri: resourceTypeIri,
      physicalTime: physicalTime,
      updatedAt: updatedAt,
      resolvedGroupIndices: resolvedGroupIndices,
    );

    await _storage.saveIndexEntries(requests);
  }

  Future<List<SaveIndexEntryRequest>> prepareIndexEntryWrites({
    required RdfGraph document,
    required IriTerm documentIri,
    required IriTerm resourceTypeIri,
    required int physicalTime,
    required int updatedAt,
    required Iterable<ResolvedGroupIndex> resolvedGroupIndices,
  }) async {
    // Check which resolved GroupIndices don't exist locally yet and create them.
    // Batched existence check: collect all IRIs, query storage once.
    if (resolvedGroupIndices.isNotEmpty) {
      final groupIndexIris =
          resolvedGroupIndices.map((r) => r.groupIndexIri).toList();
      final existingDocs = await _storage.getDocumentsByIri(groupIndexIris);
      for (final resolved in resolvedGroupIndices) {
        if (existingDocs[resolved.groupIndexIri] == null) {
          _log.info(
              'Creating missing GroupIndex for group "${resolved.groupKey}" '
              'at ${resolved.groupIndexIri}');
          await _createMissingGroupIndex(resolved);
        }
      }
    }

    // Update the Index Shards
    final allShards = document.getMultiValueObjectList<IriTerm>(
        documentIri, SyncManagedDocument.idxBelongsToIndexShard);

    // Extract clock hash from the saved document
    final clockHashLiteral = document.findSingleObject<LiteralTerm>(
        documentIri, SyncManagedDocument.crdtClockHash);
    final clockHash = clockHashLiteral?.value;
    if (clockHash == null) {
      throw StateError(
          'Saved document $documentIri is missing crdt:clockHash, cannot update indices.');
    }
    final resourceIri = document.expectSingleObject<IriTerm>(
        documentIri, SyncManagedDocument.foafPrimaryTopic)!;
    final type = document.expectSingleObject<IriTerm>(resourceIri, Rdf.type)!;

    final tombstonedShards = _collectTombstonedShards(document, documentIri);
    final shardDocumentIris = {
      ...allShards.map((shardIri) => shardIri.getDocumentIri()),
      ...tombstonedShards.map((shardIri) => shardIri.getDocumentIri()),
    };
    final indexedPropertiesByShardDocumentIri = await _propertyResolver
        .resolveIndexedPropertiesBatch(shardDocumentIris);

    final tombstonedEntries = await _buildTombstonedShardEntryWrites(
      resourceIri,
      resourceTypeIri,
      document,
      documentIri,
      physicalTime,
      updatedAt,
      indexedPropertiesByShardDocumentIri,
    );

    final updatedEntries = await _buildShardIndexEntryWrites(
      type,
      resourceIri,
      clockHash,
      document,
      allShards,
      physicalTime,
      updatedAt,
      indexedPropertiesByShardDocumentIri,
    );

    return [
      ...tombstonedEntries,
      ...updatedEntries,
    ];
  }

  /// Generates RDF graph for a GroupIndex resource.
  ///
  /// Similar to FullIndex but links back to GroupIndexTemplate via idx:basedOn
  RdfGraph _generateGroupIndex({
    required GroupIndexData config,
    required IriTerm resourceType,
    required IriTerm resourceIri,
    required IriTerm templateIri,
    required Iterable<IriTerm> shards,
  }) {
    final triples = <Triple>[
      // Type declaration
      Triple(resourceIri, Rdf.type, IdxGroupIndex.classIri),

      // Link back to template
      Triple(resourceIri, IdxGroupIndex.basedOn, templateIri),

      // Shards
      ...shards
          .map((shard) => Triple(resourceIri, IdxGroupIndex.hasShard, shard)),
    ];

    return triples.toRdfGraph();
  }

  /// Updates all index shards to reflect the current state of a resource.
  ///
  /// This method is called after a resource has been saved to ensure index entries
  /// are synchronized with the resource state. It processes all shards the resource
  /// belongs to and updates their entries accordingly.
  ///
  /// Process:
  /// 1. For each shard:
  ///    a. Resolve which properties should be indexed (from index document)
  ///    b. Extract those property values from the resource data
  ///    c. Generate entry graph with properties
  ///    d. Patch shard document with entry
  ///
  /// Parameters:
  /// - [type]: The RDF type of the resource (e.g., schema:Recipe)
  /// - [resourceIri]: The IRI of the resource being indexed
  /// - [clockHash]: The clock hash from the saved CRDT document
  /// - [document]: The full document (for extracting header properties)
  /// - [allShards]: All shard IRIs the resource currently belongs to (from idx:belongsToIndexShard)
  Future<List<SaveIndexEntryRequest>> _buildShardIndexEntryWrites(
    IriTerm type,
    IriTerm resourceIri,
    String clockHash,
    RdfGraph document,
    Iterable<IriTerm> allShards,
    int physicalTime,
    int updatedAt,
    Map<IriTerm, IndexProperties> indexedPropertiesByShardDocumentIri,
  ) async {
    final requests = <SaveIndexEntryRequest>[];

    // Process each shard the resource belongs to
    for (final shardIri in allShards) {
      final shardDocumentIri = shardIri.getDocumentIri();
      // Resolve which properties should be indexed for this shard
      final (indexIri, indexedProperties) =
          indexedPropertiesByShardDocumentIri[shardDocumentIri] ??
              (null, const <IriTerm>{});
      if (indexIri == null) {
        _log.warning(
            'Shard ${shardDocumentIri.debug} has no associated index or template, skipping.');
        continue;
      }
      // Extract property values from resource data
      final headerProperties = _extractHeaderProperties(
        resourceIri: resourceIri,
        document: document,
        propertiesToExtract: indexedProperties,
      );

      // Build header properties graph if present
      RdfGraph? headerPropertiesGraph;
      if (headerProperties != null) {
        headerPropertiesGraph = RdfGraph.fromTriples(headerProperties.entries
            .expand((e) => e.value.map((v) => Triple(resourceIri, e.key, v))));
      }

      requests.add(SaveIndexEntryRequest(
        shardIri: shardIri,
        indexIri: indexIri,
        resourceIri: resourceIri,
        resourceType: type,
        clockHash: clockHash,
        headerProperties: headerPropertiesGraph,
        updatedAt: updatedAt,
        ourPhysicalClock: physicalTime,
      ));
    }

    return requests;
  }

  /// Extracts header properties from resource data for specified properties.
  ///
  /// Takes a set of property IRIs (resolved from the index configuration)
  /// and extracts their values from the resource's RDF graph.
  ///
  /// Process:
  /// 1. For each property IRI in the set
  /// 2. Get all values for that property from the resource
  /// 3. Use first value (index entries use LWW-Register for all properties)
  /// 4. Skip properties with no values
  ///
  /// Parameters:
  /// - [resourceIri]: The IRI of the resource to extract properties from
  /// - [document]: The resource's semantic RDF data
  /// - [propertiesToExtract]: Set of property IRIs to extract (from index config)
  ///
  /// Returns: Map of property IRI to RdfObject, or null if no properties found
  Map<IriTerm, List<RdfObject>>? _extractHeaderProperties({
    required IriTerm resourceIri,
    required RdfGraph document,
    required Set<IriTerm> propertiesToExtract,
  }) {
    // If no properties configured, return null
    if (propertiesToExtract.isEmpty) {
      return null;
    }

    // Extract property values from resource data
    final headerProperties = <IriTerm, List<RdfObject>>{};
    for (final propertyIri in propertiesToExtract) {
      // Get all values for this property
      final values = document.getMultiValueObjectList<RdfObject>(
        resourceIri,
        propertyIri,
      );

      // Use first value if available (index entries use LWW-Register)
      if (values.isNotEmpty) {
        headerProperties[propertyIri] = values;
        if (values.any((v) => v is BlankNodeTerm)) {
          throw ArgumentError(
              'Header property $propertyIri has blank node value, which is not supported in index entries.');
        }
      }
      // If property has no values, don't include it in the entry
    }

    // Return null if no properties were found, otherwise return the map
    return headerProperties.isEmpty ? null : headerProperties;
  }

  IriTerm getIndexOrTemplateIri(CrdtIndexData index, IriTerm typeIri) =>
      _rdfGenerator.generateIndexOrTemplateIri(index, typeIri);

  /// Removes entries from shards based on tombstones in idx:belongsToIndexShard.
  ///
  /// When a resource's group membership changes (e.g., recipe category changes from
  /// 'Dessert' to 'Main Course'), the OR-Set semantics automatically create tombstones
  /// for the removed shard references. This method:
  ///
  /// 1. Detects tombstoned idx:belongsToIndexShard values in the CRDT document
  /// 2. For each tombstoned shard, removes the corresponding entry using patch()
  /// 3. Uses empty graph to signal removal (OR-Set tombstone will be created automatically)
  ///
  /// This ensures indices remain consistent with current group membership while preserving
  /// tombstones for conflict resolution during synchronization.
  ///
  /// Parameters:
  /// - [resourceIri]: The resource whose shard entries should be cleaned up
  /// - [crdtDocument]: The saved CRDT document containing potential tombstones
  /// - [documentIri]: The document IRI to search for tombstones
  Future<List<SaveIndexEntryRequest>> _buildTombstonedShardEntryWrites(
    IriTerm resourceIri,
    IriTerm resourceType,
    RdfGraph crdtDocument,
    IriTerm documentIri,
    int ourPhysicalClock,
    int updatedAt,
    Map<IriTerm, IndexProperties> indexedPropertiesByShardDocumentIri,
  ) async {
    // Find all reified statements with crdt:deletedAt for idx:belongsToIndexShard
    final reifiedStmts =
        crdtDocument.findTriples(predicate: Rdf.subject, object: documentIri);

    if (reifiedStmts.isEmpty) {
      return const []; // No reified statements, nothing to clean up
    }

    final tombstones = <Triple>[];
    for (final reifiedStmt in reifiedStmts) {
      if (reifiedStmt.subject is! IriTerm) continue;
      final stmtIri = reifiedStmt.subject as IriTerm;

      // Check if it has crdt:deletedAt (tombstone marker).
      // crdt:deletedAt uses OR_Set semantics (core-v1.ttl): after merging peers,
      // there can be multiple values (even identical duplicates).
      // We only need to know if any deletedAt exists (presence = tombstoned).
      final deletedAt = crdtDocument.findMaxDateTimeObject(
        stmtIri,
        Crdt.deletedAt,
      );
      if (deletedAt == null) continue;

      // Check if the reified statement is about belongsToIndexShard
      final reifiedPredicate = crdtDocument.findSingleObject<IriTerm>(
        stmtIri,
        Rdf.predicate,
      );

      if (reifiedPredicate == SyncManagedDocument.idxBelongsToIndexShard) {
        tombstones.add(reifiedStmt);
      }
    }

    if (tombstones.isEmpty) {
      return const []; // No tombstones found, nothing to clean up
    }

    _log.info(
        'Found ${tombstones.length} tombstoned shard references for $resourceIri');

    final requests = <SaveIndexEntryRequest>[];

    // For each tombstoned shard reference, remove the entry
    for (final tombstone in tombstones) {
      final reifiedStmtIri = tombstone.subject as IriTerm;

      // Get the shard IRI from the reified statement's object
      final shardIri = crdtDocument.findSingleObject<IriTerm>(
        reifiedStmtIri,
        Rdf.object,
      );

      if (shardIri == null) {
        _log.warning(
            'Tombstone ${reifiedStmtIri.debug} has no rdf:object, skipping cleanup');
        continue;
      }

      _log.info(
          'Marking entry for ${resourceIri.debug} as deleted in shard ${shardIri.debug}');

      // Resolve index IRI for this shard
      final shardDocumentIri = shardIri.getDocumentIri();
      final (indexIri, _) =
          indexedPropertiesByShardDocumentIri[shardDocumentIri] ??
              (null, const <IriTerm>{});

      if (indexIri == null) {
        _log.warning(
            'Cannot resolve index for shard ${shardDocumentIri.debug}, skipping tombstone');
        continue;
      }

      requests.add(SaveIndexEntryRequest(
        shardIri: shardIri,
        indexIri: indexIri,
        resourceIri: resourceIri,
        resourceType: resourceType,
        // TODO: is it correct to use empty clockHash here?
        clockHash: '', // Empty hash for deleted entries
        headerProperties: null,
        isDeleted: true,
        ourPhysicalClock: ourPhysicalClock,
        updatedAt: updatedAt,
      ));
    }

    return requests;
  }

  Set<IriTerm> _collectTombstonedShards(
      RdfGraph crdtDocument, IriTerm documentIri) {
    final reifiedStmts =
        crdtDocument.findTriples(predicate: Rdf.subject, object: documentIri);
    if (reifiedStmts.isEmpty) {
      return const {};
    }

    final tombstonedShards = <IriTerm>{};
    for (final reifiedStmt in reifiedStmts) {
      if (reifiedStmt.subject is! IriTerm) continue;
      final stmtIri = reifiedStmt.subject as IriTerm;

      final deletedAt =
          crdtDocument.findMaxDateTimeObject(stmtIri, Crdt.deletedAt);
      if (deletedAt == null) continue;

      final reifiedPredicate =
          crdtDocument.findSingleObject<IriTerm>(stmtIri, Rdf.predicate);
      if (reifiedPredicate != SyncManagedDocument.idxBelongsToIndexShard) {
        continue;
      }

      final shardIri =
          crdtDocument.findSingleObject<IriTerm>(stmtIri, Rdf.object);
      if (shardIri != null) {
        tombstonedShards.add(shardIri);
      }
    }

    return tombstonedShards;
  }
}

/// Extension to expose internal helper methods for testing.
extension IndexManagerTestHelpers on IndexManager {
  IndexRdfGenerator get rdfGenerator => _rdfGenerator;
}
