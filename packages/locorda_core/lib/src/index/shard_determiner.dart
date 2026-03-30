/// Determines which index shards a resource belongs to (read-only operations).
///
/// This class is responsible for calculating shard membership based on resource
/// type and properties, without creating any documents. Shard/GroupIndex creation
/// is handled by IndexManager after this determination is made.
///
/// The determiner now uses the index-of-indices from storage instead of the
/// configuration, allowing dynamic discovery of indices during sync.
library;

import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_core/src/index/group_key_generator.dart';
import 'package:locorda_core/src/index/index_discovery.dart';
import 'package:locorda_core/src/index/index_rdf_generator.dart';
import 'package:locorda_core/src/index/shard_manager.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:logging/logging.dart';
import 'package:locorda_rdf_core/core.dart';

final _log = Logger('ShardDeterminer');

/// Controls error handling and shard preservation behavior.
///
/// This allows context-dependent behavior:
/// - During user-initiated saves: be lenient, proceed with best effort
/// - During sync operations: be strict, ensure consistency
enum ShardDeterminationMode {
  /// Strict mode - used during sync operations after index-of-indices sync.
  ///
  /// Error handling:
  /// - Throws exception if FullIndex or GroupIndexTemplate documents are missing
  /// - Expects complete index information to be available
  ///
  /// Shard preservation:
  /// - Uses ONLY calculated shards from available index documents
  /// - Discards old shard associations (they belong to obsolete/unknown indices)
  /// - Rationale: With storage-based discovery, we know ALL relevant indices,
  ///   so any shard we didn't calculate is obsolete or belongs to a dead index
  strict,

  /// Lenient mode - used during user-initiated saves before index sync.
  ///
  /// Error handling:
  /// - Returns empty shards for missing indices with logged warnings
  /// - Proceeds with partial information
  ///
  /// Shard preservation:
  /// - Uses calculated shards PLUS old shards from other installations
  /// - Preserves shards that might belong to indices not yet synced
  /// - Self-healing: missing shards will be recalculated on next sync
  lenient,
}

/// Type of index for missing document reporting.
enum IndexType {
  fullIndex,
  groupIndexTemplate,
  groupIndex,
}

/// Information about a missing index document discovered during shard determination.
///
/// This can represent a missing FullIndex, GroupIndexTemplate, or GroupIndex.
/// Missing indices are expected during the sync process when the index-of-indices
/// is synced but the actual index documents haven't been fetched yet.
class MissingIndexDocument {
  final IriTerm indexIri;
  final IriTerm typeIri;
  final IndexType indexType;
  final String? localName; // For FullIndex/GroupIndexTemplate from config

  const MissingIndexDocument({
    required this.indexIri,
    required this.typeIri,
    required this.indexType,
    this.localName,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MissingIndexDocument &&
          runtimeType == other.runtimeType &&
          indexIri == other.indexIri &&
          typeIri == other.typeIri &&
          indexType == other.indexType;

  @override
  int get hashCode => indexIri.hashCode ^ typeIri.hashCode ^ indexType.hashCode;

  @override
  String toString() =>
      'MissingIndexDocument(type: $indexType, indexIri: $indexIri, resourceType: $typeIri)';
}

/// Information about a GroupIndex resolved from grouping rules.
///
/// Represents all relevant GroupIndex instances for a resource. Existence of
/// the GroupIndex document is checked later (in Stage 9 / [IndexManager]) to
/// keep shard determination a pure CPU operation.
class ResolvedGroupIndex {
  final IriTerm typeIri;
  final IriTerm templateIri;
  final String groupKey;
  final IriTerm groupIndexIri;
  final RootResourceFetchPolicy rootResourceFetchPolicy;

  const ResolvedGroupIndex({
    required this.typeIri,
    required this.templateIri,
    required this.groupKey,
    required this.groupIndexIri,
    required this.rootResourceFetchPolicy,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ResolvedGroupIndex &&
          runtimeType == other.runtimeType &&
          typeIri == other.typeIri &&
          templateIri == other.templateIri &&
          groupKey == other.groupKey &&
          groupIndexIri == other.groupIndexIri &&
          rootResourceFetchPolicy == other.rootResourceFetchPolicy;

  @override
  int get hashCode =>
      typeIri.hashCode ^
      templateIri.hashCode ^
      groupKey.hashCode ^
      groupIndexIri.hashCode ^
      rootResourceFetchPolicy.hashCode;

  @override
  String toString() =>
      'ResolvedGroupIndex(groupKey: $groupKey, groupIndexIri: $groupIndexIri)';
}

/// Result of shard determination including shards and missing components.
///
/// The result distinguishes between:
/// - Missing index documents (FullIndex/GroupIndexTemplate not yet synced)
/// - Resolved GroupIndex instances (computed from grouping rules)
/// - Successfully determined shards
class ShardDeterminationResult {
  final Set<IriTerm> shards;
  final List<ResolvedGroupIndex> resolvedGroupIndices;
  final List<MissingIndexDocument> missingIndexDocuments;

  const ShardDeterminationResult({
    required this.shards,
    required this.resolvedGroupIndices,
    required this.missingIndexDocuments,
  });

  bool get hasMissingIndexDocuments => missingIndexDocuments.isNotEmpty;

  /// Returns true if all required index documents are available.
  ///
  /// When false, the shard set may be incomplete and should be recalculated
  /// once the missing components become available.
  bool get isComplete => !hasMissingIndexDocuments;
}

/// Request-scoped read-through cache for index document lookups during shard determination.
///
/// Caches both existing and missing documents to avoid repeated storage reads for
/// identical index/template/group-index documents within one sync batch.
class ShardDeterminationLookupCache {
  final Map<String, StoredDocument?> _documentsByIri =
      <String, StoredDocument?>{};

  Future<StoredDocument?> getOrLoad(
    IriTerm documentIri,
    Future<StoredDocument?> Function(IriTerm documentIri) loader,
  ) async {
    final key = documentIri.value;
    if (_documentsByIri.containsKey(key)) {
      return _documentsByIri[key];
    }
    final loaded = await loader(documentIri);
    _documentsByIri[key] = loaded;
    return loaded;
  }

  void clear() => _documentsByIri.clear();
}

/// Determines which index shards a resource belongs to (read-only).
///
/// This class uses the index-of-indices from storage to discover which indices
/// exist for a given resource type, then loads those index documents to determine
/// shard membership. This allows dynamic index discovery during sync without
/// relying on compile-time configuration.
///
/// The determiner does NOT create any documents - only calculates which shards
/// a resource should belong to and reports missing components.
class ShardDeterminer {
  final Storage _storage;
  final IndexRdfGenerator _rdfGenerator;
  final ShardManager _shardManager;

  final IndexDiscovery _indexDiscovery;

  const ShardDeterminer({
    required Storage storage,
    required IndexRdfGenerator rdfGenerator,
    required ShardManager shardManager,
    required IndexDiscovery indexDiscovery,
  })  : _storage = storage,
        _rdfGenerator = rdfGenerator,
        _shardManager = shardManager,
        _indexDiscovery = indexDiscovery;

  /// Calculates which shards a resource belongs to, including handling of
  /// shards from other installations and detecting removed shards.
  ///
  /// This method:
  /// 1. Determines new shards based on current appData
  /// 2. Determines old shards based on previous appData (if exists)
  /// 3. Calculates which shards were removed
  /// 4. Preserves shards from other installations that weren't removed
  ///
  /// Parameters:
  /// - [mode]: Controls error handling for missing index documents
  /// - [type]: The RDF type of the resource
  /// - [resourceIri]: The IRI of the resource being indexed
  /// - [documentIri]: The document IRI containing the resource
  /// - [appData]: Current application data for the resource
  /// - [oldAppData]: Previous application data (for change detection)
  /// - [oldFrameworkGraph]: Previous framework metadata (for other installations' shards)
  ///
  /// Returns: Tuple of (all shards, removed shards, resolved group indices, missing index documents)
  Future<
      (
        Set<IriTerm> all,
        Set<IriTerm> removed,
        List<ResolvedGroupIndex> resolvedGroupIndices,
        List<MissingIndexDocument> missingIndexDocuments
      )> calculateShards(
    IriTerm type,
    IriTerm resourceIri,
    IriTerm documentIri,
    RdfGraph appData,
    RdfGraph? oldAppData,
    RdfGraph? oldFrameworkGraph, {
    ShardDeterminationMode mode = ShardDeterminationMode.lenient,
  }) async {
    // Calculate new shards based on current appData
    final newShardResult = await determineShards(
      type,
      resourceIri,
      appData,
      mode: mode,
    );
    final newShards = newShardResult.shards;

    // Calculate old shards based on previous appData (if exists)
    // This is needed to determine which shards should be removed
    final oldShardResult = oldAppData != null
        ? await determineShards(
            type,
            resourceIri,
            oldAppData,
            mode: mode,
          )
        : const ShardDeterminationResult(
            shards: <IriTerm>{},
            resolvedGroupIndices: <ResolvedGroupIndex>[],
            missingIndexDocuments: <MissingIndexDocument>[],
          );
    final oldCalculatedShards = oldShardResult.shards;
    final removed = oldCalculatedShards.difference(newShards);

    // Get shards from old framework graph for other installations
    final oldStoredShards = oldFrameworkGraph?.getMultiValueObjectList<IriTerm>(
            documentIri, SyncManagedDocument.idxBelongsToIndexShard) ??
        const <IriTerm>[];

    // Mode-dependent shard preservation strategy
    final Set<IriTerm> allShards;

    if (mode == ShardDeterminationMode.strict) {
      // STRICT MODE: Only use calculated shards
      //
      // Rationale: After index-of-indices sync, we have complete information
      // about ALL relevant indices (own + foreign apps). With storage-based
      // discovery, any shard we didn't calculate either:
      // 1. Belongs to an index that no longer exists (obsolete)
      // 2. Belongs to an index we don't know about (but should be in index-of-indices)
      //
      // Therefore, old shards from other installations should be discarded.
      // The entire purpose of storage-based index discovery is to play well
      // with foreign applications by following THEIR sharding rules, which we
      // do by reading their index documents from storage.
      allShards = newShards;

      if (oldStoredShards.isNotEmpty &&
          oldStoredShards.length != newShards.length) {
        _log.fine(
            'Strict mode: Using only ${newShards.length} calculated shards, '
            'discarding ${oldStoredShards.length - newShards.length} old shards');
      }
    } else {
      // LENIENT MODE: Preserve shards from other installations as safety net
      //
      // Rationale: Indices might not be synced yet. Old shards could belong
      // to indices we don't know about yet. Preserve them to avoid data loss
      // during the transition period before index sync completes.
      //
      // This is self-healing: once indices are synced and we recalculate
      // in strict mode, obsolete shards will be cleaned up.
      final shardsFromOtherInstallations = removed.isEmpty
          ? oldStoredShards
          : oldStoredShards.where((shard) => !removed.contains(shard));
      allShards = {...newShards, ...shardsFromOtherInstallations};

      if (shardsFromOtherInstallations.isNotEmpty) {
        _log.fine('Lenient mode: Using ${newShards.length} calculated shards '
            '+ ${shardsFromOtherInstallations.length} preserved shards');
      }
    }

    // Combine resolved components from both old and new calculations
    // Use sets to avoid duplicates
    final allResolvedGroupIndices = {
      ...newShardResult.resolvedGroupIndices,
      ...oldShardResult.resolvedGroupIndices,
    }.toList();
    final allMissingIndexDocuments = {
      ...newShardResult.missingIndexDocuments,
      ...oldShardResult.missingIndexDocuments,
    }.toList();

    return (
      allShards,
      removed,
      allResolvedGroupIndices,
      allMissingIndexDocuments
    );
  }

  /// Determines which shards a resource of the given type should belong to.
  ///
  /// This method now uses the index-of-indices from storage to discover which
  /// indices exist for the resource type, rather than using compile-time config.
  ///
  /// Process:
  /// 1. Query index-of-indices for FullIndex and GroupIndexTemplate items
  /// 2. For each index item found:
  ///    a. For FullIndex: Load document, calculate shard based on resource IRI hash
  ///    b. For GroupIndexTemplate: Determine group membership, check/create GroupIndex,
  ///       calculate shard per group
  /// 3. Handle missing index documents according to the mode parameter
  ///
  /// This method is READ-ONLY - it does not create any documents. Missing components
  /// are reported via the result object so the caller can handle them appropriately.
  ///
  /// Parameters:
  /// - [type]: The RDF type of the resource (e.g., schema:Recipe)
  /// - [resourceIri]: The IRI of the resource being indexed
  /// - [internalAppData]: The resource's semantic data (for group determination)
  /// - [mode]: Controls error handling for missing index documents
  ///
  /// Returns: ShardDeterminationResult with shards and missing components
  Future<ShardDeterminationResult> determineShards(
    IriTerm type,
    IriTerm resourceIri,
    RdfGraph internalAppData, {
    required ShardDeterminationMode mode,
    ShardDeterminationLookupCache? lookupCache,
  }) async {
    final shards = <IriTerm>{};
    final resolvedGroupIndices = <ResolvedGroupIndex>[];
    final missingIndexDocuments = <MissingIndexDocument>[];

    // Discover indices from storage via index-of-indices
    final indexConfigs =
        await _indexDiscovery.discoverIndices(type, mode: mode);
    if (indexConfigs.isEmpty) {
      if (type != IdxShard.classIri && type != IdxGroupIndex.classIri) {
        _log.warning('No index configs found for type $type');
      }
      return ShardDeterminationResult(
        shards: shards,
        resolvedGroupIndices: resolvedGroupIndices,
        missingIndexDocuments: missingIndexDocuments,
      );
    }

    // Process each discovered index configuration
    for (final indexConfig in indexConfigs) {
      switch (indexConfig) {
        case FullIndexData _:
          final result = await _determineShardsForFullIndex(
            indexConfig,
            resourceIri,
            type,
            mode: mode,
            lookupCache: lookupCache,
          );
          shards.addAll(result.shards);
          resolvedGroupIndices.addAll(result.resolvedGroupIndices);
          missingIndexDocuments.addAll(result.missingIndexDocuments);

        case GroupIndexData _:
          final result = await _determineShardsForGroupIndex(
            indexConfig,
            resourceIri,
            type,
            internalAppData,
            mode: mode,
            lookupCache: lookupCache,
          );
          shards.addAll(result.shards);
          resolvedGroupIndices.addAll(result.resolvedGroupIndices);
          missingIndexDocuments.addAll(result.missingIndexDocuments);
      }
    }

    return ShardDeterminationResult(
      shards: shards,
      resolvedGroupIndices: resolvedGroupIndices,
      missingIndexDocuments: missingIndexDocuments,
    );
  }

  /// Determines which shard(s) a resource belongs to for a FullIndex.
  ///
  /// Process per SHARDING.md:
  /// 1. Generate the FullIndex IRI from config
  /// 2. Load the FullIndex document from storage
  /// 3. Parse its sharding configuration (numberOfShards, configVersion)
  /// 4. Calculate shard number using MD5 hash modulo algorithm
  /// 5. Generate the shard IRI
  ///
  /// Error handling depends on mode parameter:
  /// - strict: Throws exception if index document is missing
  /// - lenient/partial: Returns empty result with MissingIndexDocument entry
  ///
  /// Returns: ShardDeterminationResult with shards and missing documents
  Future<ShardDeterminationResult> _determineShardsForFullIndex(
    FullIndexData config,
    IriTerm resourceIri,
    IriTerm typeIri, {
    required ShardDeterminationMode mode,
    ShardDeterminationLookupCache? lookupCache,
  }) async {
    final shards = <IriTerm>[];
    final missingIndexDocuments = <MissingIndexDocument>[];

    // Generate the index IRI from config
    final indexResourceIri =
        _rdfGenerator.generateFullIndexIri(config, typeIri);
    final indexDocumentIri = indexResourceIri.getDocumentIri();

    // Load the index document from storage
    final storedDoc = await _getDocument(
      indexDocumentIri,
      lookupCache: lookupCache,
    );

    // Special case: Indices for FullIndex or GroupIndexTemplate themselves
    // cannot exist yet during their own creation
    final maySkip = typeIri == IdxFullIndex.classIri ||
        typeIri == IdxGroupIndexTemplate.classIri;

    if (storedDoc == null) {
      if (!maySkip) {
        final missing = MissingIndexDocument(
          indexIri: indexResourceIri,
          typeIri: typeIri,
          indexType: IndexType.fullIndex,
          localName: config.localName,
        );
        missingIndexDocuments.add(missing);

        if (mode == ShardDeterminationMode.strict) {
          throw StateError(
              'FullIndex document not found (strict mode): ${indexDocumentIri.debug}. '
              'Ensure index-of-indices has been synced and FullIndex documents are available.');
        }

        _log.warning(
            'FullIndex document not found (${mode.name} mode): ${indexDocumentIri.debug}');
      }
      return ShardDeterminationResult(
        shards: shards.toSet(),
        resolvedGroupIndices: const [],
        missingIndexDocuments: missingIndexDocuments,
      );
    }

    // Parse sharding configuration from the index
    final shardingConfig =
        _shardManager.parseShardingConfig(storedDoc.document, indexResourceIri);
    if (shardingConfig == null) {
      _log.warning(
          'Could not parse sharding config from index: ${indexResourceIri.debug}');
      return ShardDeterminationResult(
        shards: shards.toSet(),
        resolvedGroupIndices: const [],
        missingIndexDocuments: missingIndexDocuments,
      );
    }

    // Calculate which shard number this resource belongs to
    final shardNumber = _shardManager.determineShardNumber(
      resourceIri,
      numberOfShards: shardingConfig.numberOfShards,
    );

    // Generate the expected shard IRI
    final shardIri = _rdfGenerator.generateShardIri(
      shardingConfig.numberOfShards,
      shardNumber,
      shardingConfig.configVersion,
      indexResourceIri,
      IdxFullIndex.classIri,
    );

    shards.add(shardIri);

    return ShardDeterminationResult(
      shards: shards.toSet(),
      resolvedGroupIndices: const [],
      missingIndexDocuments: missingIndexDocuments,
    );
  }

  /// Determines which shard(s) a resource belongs to for a GroupIndexTemplate.
  ///
  /// Process per LOCORDA-SPECIFICATION.md section 5.3:
  /// 1. Load GroupIndexTemplate document to get grouping configuration
  /// 2. Generate group keys from resource properties using GroupKeyGenerator
  /// 3. For each group key:
  ///    a. Generate GroupIndex IRI from template IRI + group key
  ///    b. Record as [ResolvedGroupIndex] (existence check deferred to Stage 9)
  ///    c. Calculate shard number using resource IRI hash
  ///    d. Generate shard IRI
  ///
  /// Error handling depends on mode parameter:
  /// - strict: Throws exception if template document is missing
  /// - lenient/partial: Returns empty result with MissingIndexDocument entry
  ///
  /// Returns: ShardDeterminationResult with shards and missing components
  Future<ShardDeterminationResult> _determineShardsForGroupIndex(
    GroupIndexData config,
    IriTerm resourceIri,
    IriTerm typeIri,
    RdfGraph internalAppData, {
    required ShardDeterminationMode mode,
    ShardDeterminationLookupCache? lookupCache,
  }) async {
    final shards = <IriTerm>[];
    final resolvedGroupIndices = <ResolvedGroupIndex>[];
    final missingIndexDocuments = <MissingIndexDocument>[];

    // Generate the GroupIndexTemplate IRI
    final templateIri =
        _rdfGenerator.generateGroupIndexTemplateIri(config, typeIri);

    // Generate group keys from resource properties
    final groupKeyGenerator = GroupKeyGenerator(config);
    final triples = internalAppData.triples.toList();
    final groupKeys = groupKeyGenerator.generateGroupKeys(triples);

    // If no group keys, resource doesn't belong to any group (missing required properties)
    if (groupKeys.isEmpty) {
      _log.fine(
          'Resource $resourceIri has no group keys for template $templateIri');
      return ShardDeterminationResult(
        shards: shards.toSet(),
        resolvedGroupIndices: resolvedGroupIndices,
        missingIndexDocuments: missingIndexDocuments,
      );
    }

    // Load template document for sharding configuration (needed for all groups)
    final templateDocumentIri = templateIri.getDocumentIri();
    final templateDoc = await _getDocument(
      templateDocumentIri,
      lookupCache: lookupCache,
    );
    if (templateDoc == null) {
      final missing = MissingIndexDocument(
        indexIri: templateIri,
        typeIri: typeIri,
        indexType: IndexType.groupIndexTemplate,
        localName: config.localName,
      );
      missingIndexDocuments.add(missing);

      if (mode == ShardDeterminationMode.strict) {
        throw StateError(
            'GroupIndexTemplate document not found (strict mode): $templateDocumentIri. '
            'Ensure index-of-indices has been synced and GroupIndexTemplate documents are available.');
      }

      _log.warning(
          'GroupIndexTemplate document not found (${mode.name} mode): $templateDocumentIri');
      return ShardDeterminationResult(
        shards: shards.toSet(),
        resolvedGroupIndices: resolvedGroupIndices,
        missingIndexDocuments: missingIndexDocuments,
      );
    }

    final shardingConfig =
        _shardManager.parseShardingConfig(templateDoc.document, templateIri);
    if (shardingConfig == null) {
      _log.warning(
          'Could not parse sharding config from GroupIndexTemplate: $templateIri');
      return ShardDeterminationResult(
        shards: shards.toSet(),
        resolvedGroupIndices: resolvedGroupIndices,
        missingIndexDocuments: missingIndexDocuments,
      );
    }

    // Process each group key
    for (final groupKey in groupKeys) {
      // Generate GroupIndex IRI
      final groupIndexIri =
          _rdfGenerator.generateGroupIndexIri(templateIri, groupKey);

      resolvedGroupIndices.add(
        ResolvedGroupIndex(
          typeIri: typeIri,
          templateIri: templateIri,
          groupKey: groupKey,
          groupIndexIri: groupIndexIri,
          rootResourceFetchPolicy: config.rootResourceFetchPolicy,
        ),
      );

      // Calculate which shard number this resource belongs to
      final shardNumber = _shardManager.determineShardNumber(
        resourceIri,
        numberOfShards: shardingConfig.numberOfShards,
      );

      // Generate the shard IRI (relative to GroupIndex, not template)
      final shardIri = _rdfGenerator.generateShardIri(
        shardingConfig.numberOfShards,
        shardNumber,
        shardingConfig.configVersion,
        groupIndexIri,
        IdxGroupIndex.classIri,
      );

      shards.add(shardIri);
    }

    return ShardDeterminationResult(
      shards: shards.toSet(),
      resolvedGroupIndices: resolvedGroupIndices,
      missingIndexDocuments: missingIndexDocuments,
    );
  }

  Future<StoredDocument?> _getDocument(
    IriTerm documentIri, {
    ShardDeterminationLookupCache? lookupCache,
  }) async {
    if (lookupCache == null) {
      return _storage.getDocument(documentIri);
    }
    return lookupCache.getOrLoad(documentIri, _storage.getDocument);
  }
}
