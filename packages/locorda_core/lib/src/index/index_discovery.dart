/// Discovers indices from storage for a given indexed class.
///
/// This class queries the index-of-indices (fullIndices and groupIndexTemplates)
/// to find which indices exist for a resource type, then loads and parses those
/// index documents to provide complete configuration objects.
///
/// This enables dynamic index discovery during sync, allowing the system to
/// work with both own and foreign application indices without compile-time
/// configuration.
///
/// Performance: Uses watch-based caching for IRI mapping to enable fast lookups
/// during frequent ShardDeterminer calls (every sync, every user update).
library;

import 'dart:async';

import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_core/src/index/index_parser.dart';
import 'package:locorda_core/src/index/index_rdf_generator.dart';
import 'package:locorda_core/src/index/shard_determiner.dart'
    show ShardDeterminationMode;
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/storage/storage_interface.dart'
    show IndexEntryWithIri;
import 'package:locorda_core/src/util/build_effective_config.dart';
import 'package:locorda_core/src/util/lru_cache.dart';
import 'package:locorda_core/src/vocab/generated/_index.dart';
import 'package:locorda_core/src/vocab/generated/idx.dart';
import 'package:logging/logging.dart';
import 'package:locorda_rdf_core/core.dart';

final _log = Logger('IndexDiscovery');

/// Cache entry for parsed index configurations.
///
/// Contains the parsed config and the clockHash used for validation.
class _ParsedIndexCacheEntry {
  final CrdtIndexData config;
  final String clockHash;

  const _ParsedIndexCacheEntry({
    required this.config,
    required this.clockHash,
  });
}

/// Metadata for an index IRI tracked in the cache.
///
/// Contains the current clockHash to enable efficient staleness detection.
class _IndexMetadata {
  final IriTerm indexIri;
  final String clockHash;

  const _IndexMetadata({
    required this.indexIri,
    required this.clockHash,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _IndexMetadata &&
          indexIri == other.indexIri &&
          clockHash == other.clockHash;

  @override
  int get hashCode => indexIri.hashCode ^ clockHash.hashCode;
}

/// Discovers indices from storage for resource types.
///
/// Queries the index-of-indices meta-indices to find existing indices,
/// then loads and parses the index documents to provide configuration objects.
///
/// Uses watch-based caching for fast indexed class → index IRI lookups,
/// critical for performance as this is called for every document during sync.
class IndexDiscovery {
  final Storage _storage;
  final IndexParser _parser;
  final IndexRdfGenerator _rdfGenerator;
  final SyncEngineConfig _config;

  /// Watch-based cache: indexed class → set of FullIndex metadata
  ///
  /// Updated automatically via storage watches on the fullIndices index-of-indices.
  /// Only contains entries for resource types configured in effectiveConfig.
  /// Stores both IRI and clockHash for staleness detection.
  final Map<IriTerm, Set<_IndexMetadata>> _indexedClassToFullIndexMetadata = {};

  /// Watch-based cache: indexed class → set of GroupIndexTemplate metadata
  ///
  /// Updated automatically via storage watches on the groupIndexTemplates index-of-indices.
  /// Only contains entries for resource types configured in effectiveConfig.
  /// Stores both IRI and clockHash for staleness detection.
  final Map<IriTerm, Set<_IndexMetadata>> _indexedClassToTemplateMetadata = {};

  /// LRU cache of parsed index configurations.
  ///
  /// Key: Index IRI string value
  /// Value: Parsed config with clockHash for validation
  ///
  /// Bounded size to prevent memory bloat with many foreign indices.
  /// ClockHash validation ensures we always use current version.
  final LRUCache<String, _ParsedIndexCacheEntry> _parsedConfigCache =
      LRUCache(maxCacheSize: 100);

  /// Subscriptions to storage watches for automatic cache updates
  late final List<StreamSubscription> _watchSubscriptions;

  IndexDiscovery({
    required Storage storage,
    required IndexParser parser,
    required IndexRdfGenerator rdfGenerator,
    required SyncEngineConfig config,
  })  : _storage = storage,
        _parser = parser,
        _rdfGenerator = rdfGenerator,
        _config = config {
    _watchSubscriptions = _initializeWatches();
  }

  /// Dispose of watch subscriptions
  Future<void> dispose() async {
    for (final subscription in _watchSubscriptions) {
      await subscription.cancel();
    }
    _watchSubscriptions.clear();
  }

  /// Initializes storage watches for index-of-indices.
  ///
  /// Sets up reactive watches on:
  /// 1. fullIndices index-of-indices → updates _indexedClassToFullIndexIris
  /// 2. groupIndexTemplates index-of-indices → updates _indexedClassToTemplateIris
  ///
  /// Only tracks resource types configured in effectiveConfig to minimize memory.
  ///
  /// Throws [StateError] if index-of-indices IRIs cannot be found in config.
  List<StreamSubscription> _initializeWatches() {
    // Get the IRIs of the index-of-indices themselves
    final fullIndicesIndexIri = _getIndexIriByLocalName(IndexNames.fullIndices);
    final groupIndexTemplatesIndexIri =
        _getIndexIriByLocalName(IndexNames.groupIndexTemplates);

    if (fullIndicesIndexIri == null || groupIndexTemplatesIndexIri == null) {
      throw StateError('Index-of-indices not found in config. '
          'Missing: ${fullIndicesIndexIri == null ? IndexNames.fullIndices : ''} '
          '${groupIndexTemplatesIndexIri == null ? IndexNames.groupIndexTemplates : ''}. '
          'Ensure buildEffectiveConfig() is used to add framework-owned resources.');
    }
    final watchSubscriptions = <StreamSubscription>[];

    // Watch fullIndices index-of-indices
    final fullIndicesSubscription = _storage.watchIndexEntries(
      indexIris: [fullIndicesIndexIri],
      cursorTimestamp: null, // Start from beginning
    ).listen(
      (entries) => _updateIndexMetadataCache(
        entries,
        _indexedClassToFullIndexMetadata,
        'FullIndex',
      ),
      onError: (error, stackTrace) {
        _log.severe(
            'Error watching fullIndices index-of-indices', error, stackTrace);
      },
    );
    watchSubscriptions.add(fullIndicesSubscription);

    // Watch groupIndexTemplates index-of-indices
    final templatesSubscription = _storage.watchIndexEntries(
      indexIris: [groupIndexTemplatesIndexIri],
      cursorTimestamp: null, // Start from beginning
    ).listen(
      (entries) => _updateIndexMetadataCache(
        entries,
        _indexedClassToTemplateMetadata,
        'GroupIndexTemplate',
      ),
      onError: (error, stackTrace) {
        _log.severe('Error watching groupIndexTemplates index-of-indices',
            error, stackTrace);
      },
    );
    watchSubscriptions.add(templatesSubscription);

    _log.fine('Initialized index-of-indices watches');
    return watchSubscriptions;
  }

  /// Updates the metadata cache based on index entries from storage watches.
  ///
  /// Process:
  /// 1. For each entry, extract idx:indexesClass from headerProperties
  /// 2. Update cache: indexedClass → set of index metadata (IRI + clockHash)
  /// 3. Handle deletions (isDeleted flag)
  /// 4. Filter to only configured resource types
  /// 5. Invalidate parsed config cache for changed indices
  ///
  /// Error handling: Always strict - watches run continuously in background,
  /// so data consistency is critical. Any issues indicate corrupted state.
  Future<void> _updateIndexMetadataCache(
    List<IndexEntryWithIri> entries,
    Map<IriTerm, Set<_IndexMetadata>> cache,
    String indexTypeName,
  ) async {
    for (final entry in entries) {
      final indexIri = entry.resourceIri;
      final clockHash = entry.clockHash;

      if (entry.isDeleted) {
        // Remove from cache
        _removeIndexFromCache(cache, indexIri);
        // Invalidate parsed config cache
        _parsedConfigCache.remove(indexIri.value);
        _log.fine('Removed $indexTypeName from cache: ${indexIri.debug}');
        continue;
      }

      // Strict: headerProperties must be present (it's a tracked property)
      if (entry.headerProperties == null) {
        throw StateError(
            'Index entry missing headerProperties (idx:indexesClass is tracked): ${indexIri.debug}');
      }

      final headerProperties = turtle.decode(entry.headerProperties!);
      final indexedClassTriples =
          headerProperties.findTriples(predicate: Idx.indexesClass);

      // Strict: indexesClass must be present and unique
      if (indexedClassTriples.isEmpty) {
        throw StateError(
            '$indexTypeName missing idx:indexesClass property: ${indexIri.debug}');
      }
      if (indexedClassTriples.length > 1) {
        throw StateError(
            '$indexTypeName has multiple idx:indexesClass values: ${indexIri.debug}');
      }

      final indexedClass = indexedClassTriples.single.object;
      if (indexedClass is! IriTerm) {
        throw StateError(
            '$indexTypeName idx:indexesClass is not an IRI: ${indexIri.debug} → $indexedClass');
      }

      // Only track if this resource type is in our config
      if (!_isConfiguredResourceType(indexedClass)) {
        _log.fine(
            'Skipping $indexTypeName for unconfigured resource type: $indexedClass');
        continue;
      }

      // Create metadata with current clockHash
      final metadata = _IndexMetadata(
        indexIri: indexIri,
        clockHash: clockHash,
      );

      // Update cache - replace old metadata for this IRI if present
      final metadataSet = cache.putIfAbsent(indexedClass, () => {});
      // Remove old metadata with same IRI (different clockHash)
      metadataSet.removeWhere((m) => m.indexIri == indexIri);
      // Add new metadata
      metadataSet.add(metadata);

      // Invalidate parsed config cache if clockHash changed
      final cachedEntry = _parsedConfigCache[indexIri.value];
      if (cachedEntry != null && cachedEntry.clockHash != clockHash) {
        _parsedConfigCache.remove(indexIri.value);
        _log.fine(
            'Invalidated parsed config cache for $indexTypeName ${indexIri.debug} (clockHash changed)');
      }

      _log.fine(
          'Index Discovery Cache refreshed $indexTypeName metadata: indexed class $indexedClass → index Iri ${indexIri.debug} (clockHash: $clockHash)');
    }
  }

  /// Removes an index IRI from the metadata cache.
  void _removeIndexFromCache(
      Map<IriTerm, Set<_IndexMetadata>> cache, IriTerm indexIri) {
    // Find and remove the metadata with matching IRI from all sets
    for (final set in cache.values) {
      set.removeWhere((m) => m.indexIri == indexIri);
    }
    // Remove empty sets
    cache.removeWhere((key, value) => value.isEmpty);
  }

  /// Checks if a resource type is configured in effectiveConfig.
  bool _isConfiguredResourceType(IriTerm typeIri) {
    return _config.resources.any((r) => r.typeIri == typeIri);
  }

  /// Gets an index IRI by its local name from the config.
  ///
  /// Uses IndexRdfGenerator to compute the canonical IRI for the index.
  IriTerm? _getIndexIriByLocalName(String localName) {
    for (final resourceConfig in _config.resources) {
      for (final indexConfig in resourceConfig.indices) {
        if (indexConfig.localName == localName) {
          // Generate the IRI using the same logic as when creating the index
          return _rdfGenerator.generateIndexOrTemplateIri(
            indexConfig,
            resourceConfig.typeIri,
          );
        }
      }
    }
    return null;
  }

  /// Discovers all indices for the given indexed class.
  ///
  /// Process:
  /// 1. Look up FullIndex metadata from watch-based cache (fast, synchronous)
  /// 2. Look up GroupIndexTemplate metadata from watch-based cache (fast, synchronous)
  /// 3. For each index, check parsed config cache with clockHash validation
  /// 4. Load and parse documents only if cache miss or stale clockHash
  /// 5. Return complete configuration objects
  ///
  /// Returns an iterable of CrdtIndexGraphConfig (FullIndexGraphConfig or GroupIndexGraphConfig).
  /// Returns empty iterable if no indices are found.
  ///
  /// Performance:
  /// - Fast synchronous cache lookups for IRI + clockHash resolution
  /// - LRU cache minimizes document loading and parsing
  /// - ClockHash validation ensures correctness
  ///
  /// Error handling depends on [mode]:
  /// - Strict: Throws on missing documents or parse errors (sync context)
  /// - Lenient: Logs warnings and skips problematic indices (user-save context)
  Future<Iterable<CrdtIndexData>> discoverIndices(
    IriTerm indexedClass, {
    ShardDeterminationMode mode = ShardDeterminationMode.lenient,
  }) async {
    final configs = <CrdtIndexData>[];

    // Fast synchronous lookups from watch-based caches
    final fullIndexMetadata =
        _indexedClassToFullIndexMetadata[indexedClass] ?? {};
    final templateMetadata =
        _indexedClassToTemplateMetadata[indexedClass] ?? {};

    _log.fine('Discovered ${fullIndexMetadata.length} FullIndex + '
        '${templateMetadata.length} GroupIndexTemplate for $indexedClass');

    // Load and parse FullIndex documents (with cache)
    for (final metadata in fullIndexMetadata) {
      final config = await _getOrLoadIndexConfig<FullIndexData>(
        metadata,
        'FullIndex',
        _loadAndParseFullIndex,
        mode: mode,
      );
      if (config != null) {
        configs.add(config);
      }
    }

    // Load and parse GroupIndexTemplate documents (with cache)
    for (final metadata in templateMetadata) {
      final config = await _getOrLoadIndexConfig<GroupIndexData>(
        metadata,
        'GroupIndexTemplate',
        _loadAndParseTemplate,
        mode: mode,
      );
      if (config != null) {
        configs.add(config);
      }
    }

    if (configs.isEmpty && indexedClass == IdxFullIndex.classIri) {
      final fullIndexResource =
          _config.getResourceConfig(IdxFullIndex.classIri);
      final config = fullIndexResource.getIndexByName(IndexNames.fullIndices);
      return [config];
    }
    return configs;
  }

  /// Gets or loads an index configuration with cache and clockHash validation.
  ///
  /// Generic method that handles both FullIndex and GroupIndexTemplate.
  ///
  /// Process:
  /// 1. Check parsed config cache with clockHash validation
  /// 2. If cache hit with matching clockHash, return cached config
  /// 3. If cache miss or stale clockHash, load and parse document via loader
  /// 4. Store in cache with current clockHash
  ///
  /// Error handling depends on [mode]:
  /// - Strict: Throws if document missing or parse fails
  /// - Lenient: Returns null and logs warning
  Future<T?> _getOrLoadIndexConfig<T extends CrdtIndexData>(
    _IndexMetadata metadata,
    String indexTypeName,
    Future<T?> Function(IriTerm, ShardDeterminationMode) loader, {
    required ShardDeterminationMode mode,
  }) async {
    final indexIri = metadata.indexIri;
    final expectedClockHash = metadata.clockHash;

    // Check cache
    final cachedEntry = _parsedConfigCache[indexIri.value];
    if (cachedEntry != null && cachedEntry.clockHash == expectedClockHash) {
      // Cache hit with matching clockHash
      _log.fine('Cache hit for $indexTypeName: ${indexIri.debug}');
      return cachedEntry.config as T;
    }

    // Cache miss or stale - load and parse
    if (cachedEntry != null) {
      _log.fine(
          'Cache stale for $indexTypeName: ${indexIri.debug} (expected: $expectedClockHash, cached: ${cachedEntry.clockHash})');
    } else {
      _log.fine('Cache miss for $indexTypeName: ${indexIri.debug}');
    }

    final config = await loader(indexIri, mode);
    if (config != null) {
      // Store in cache with current clockHash
      _parsedConfigCache[indexIri.value] = _ParsedIndexCacheEntry(
        config: config,
        clockHash: expectedClockHash,
      );
    }
    return config;
  }

  /// Generic method to load and parse an index document.
  ///
  /// Handles document loading, parsing, and mode-dependent error handling
  /// for any index type.
  ///
  /// Error handling depends on [mode]:
  /// - Strict: Throws if document missing or parse fails
  /// - Lenient: Returns null and logs warning
  Future<T?> _loadAndParseIndexDocument<T extends CrdtIndexData>(
    IriTerm indexIri,
    String indexTypeName,
    T? Function(RdfGraph, IriTerm) parser,
    ShardDeterminationMode mode,
  ) async {
    final documentIri = indexIri.getDocumentIri();
    final doc = await _storage.getDocument(documentIri);

    if (doc == null) {
      final message = '$indexTypeName document not found: $documentIri';
      if (mode == ShardDeterminationMode.strict) {
        throw StateError('$message (strict mode)');
      }
      _log.warning('$message (lenient mode)');
      return null;
    }

    try {
      final config = parser(doc.document, indexIri);
      if (config == null) {
        final message = 'Failed to parse $indexTypeName: $indexIri';
        if (mode == ShardDeterminationMode.strict) {
          throw StateError('$message (strict mode)');
        }
        _log.warning('$message (lenient mode)');
        return null;
      }
      return config;
    } catch (e, st) {
      final message = 'Error parsing $indexTypeName: $indexIri';
      if (mode == ShardDeterminationMode.strict) {
        _log.severe('$message (strict mode)', e, st);
        rethrow;
      }
      _log.warning('$message (lenient mode)', e, st);
      return null;
    }
  }

  /// Loads and parses a FullIndex document.
  Future<FullIndexData?> _loadAndParseFullIndex(
    IriTerm indexIri,
    ShardDeterminationMode mode,
  ) =>
      _loadAndParseIndexDocument(
        indexIri,
        'FullIndex',
        (graph, iri) => _parser.parseFullIndex(graph, iri)?.config,
        mode,
      );

  /// Loads and parses a GroupIndexTemplate document.
  Future<GroupIndexData?> _loadAndParseTemplate(
    IriTerm templateIri,
    ShardDeterminationMode mode,
  ) =>
      _loadAndParseIndexDocument(
        templateIri,
        'GroupIndexTemplate',
        (graph, iri) => _parser.parseGroupIndexTemplate(graph, iri)?.config,
        mode,
      );

  /// Discovers a specific GroupIndexTemplate by its IRI.
  ///
  /// This method is used when we need to load the configuration for a specific
  /// template, for example when creating a missing GroupIndex instance.
  ///
  /// Process:
  /// 1. Look up template in watch-based cache to get current clockHash
  /// 2. Check parsed config cache with clockHash validation
  /// 3. Load and parse document only if cache miss or stale clockHash
  ///
  /// Returns null if the template is not found in the cache (not indexed) or
  /// if loading/parsing fails in lenient mode.
  ///
  /// Error handling depends on [mode]:
  /// - Strict: Throws if template not found in cache or parse fails
  /// - Lenient: Returns null and logs warning
  Future<GroupIndexData?> discoverGroupIndexTemplate(
    IriTerm templateIri, {
    ShardDeterminationMode mode = ShardDeterminationMode.lenient,
  }) async {
    // Look up template in all cached indexed classes to find its metadata
    _IndexMetadata? metadata;
    for (final metadataSet in _indexedClassToTemplateMetadata.values) {
      final found = metadataSet.where((m) => m.indexIri == templateIri);
      if (found.isNotEmpty) {
        metadata = found.first;
        break;
      }
    }

    if (metadata == null) {
      final message = 'GroupIndexTemplate not found in cache: $templateIri';
      if (mode == ShardDeterminationMode.strict) {
        throw StateError('$message (strict mode). '
            'Ensure the template is indexed via groupIndexTemplates meta-index.');
      }
      _log.warning('$message (lenient mode)');
      return null;
    }

    // Load config using existing cache infrastructure
    return await _getOrLoadIndexConfig<GroupIndexData>(
      metadata,
      'GroupIndexTemplate',
      _loadAndParseTemplate,
      mode: mode,
    );
  }
}
