/// Main facade for the CRDT sync system.
library;

import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_core/src/crdt/crdt_types.dart';
import 'package:locorda_core/src/crdt_document_manager.dart';
import 'package:locorda_core/src/hlc_service.dart';
import 'package:locorda_core/src/index/group_index_subscription_manager.dart';
import 'package:locorda_core/src/index/index_config_base.dart';
import 'package:locorda_core/src/index/index_discovery.dart';
import 'package:locorda_core/src/index/index_manager.dart';
import 'package:locorda_core/src/index/index_parser.dart';
import 'package:locorda_core/src/index/index_rdf_generator.dart';
import 'package:locorda_core/src/index/shard_determiner.dart';
import 'package:locorda_core/src/index/shard_manager.dart';
import 'package:locorda_core/src/installation_service.dart'
    show InstallationService, InstallationIdFactory;
import 'package:locorda_core/src/local_document_merger.dart';
import 'package:locorda_core/src/mapping/framework_iri_generator.dart';
import 'package:locorda_core/src/mapping/merge_contract_loader.dart';
import 'package:locorda_core/src/mapping/recursive_rdf_loader.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/storage/storage_interface.dart' as storage;
import 'package:locorda_core/src/sync/remote_document_merger.dart';
import 'package:locorda_core/src/sync/remote_sync_orchestrator.dart';
import 'package:locorda_core/src/sync/shard_document_generator.dart';
import 'package:locorda_core/src/sync/standard_sync_manager.dart';
import 'package:locorda_core/src/sync/sync_function.dart';
import 'package:locorda_core/src/util/build_effective_config.dart';
import 'package:locorda_core/src/util/retry.dart';
import 'package:logging/logging.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:rxdart/rxdart.dart';

final _log = Logger('StandardSyncEngine');

typedef IdentifiedGraph = (IriTerm id, RdfGraph graph);
typedef HydrationBatch = ({
  List<IdentifiedGraph> updates,
  List<IdentifiedGraph> deletions,
  String? cursor
});

/// Simple config service for testing that doesn't listen to remote changes.
class SimpleConfigService extends ConfigService {
  SimpleConfigService(super.initialConfig) : super(backends: []);
}

class ConfigService {
  final BehaviorSubject<SyncEngineConfig> _configSubject;
  final SyncEngineConfig _initialConfig;
  final List<Backend> _backends;
  final List<StreamSubscription> _remoteSubscriptions = [];
  bool _needsPrefetchAll = false;

  Stream<SyncEngineConfig> get configChanges => _configSubject.stream;
  SyncEngineConfig get currentConfig => _configSubject.value;

  ConfigService(SyncEngineConfig initialConfig,
      {required List<Backend> backends})
      : _configSubject =
            BehaviorSubject<SyncEngineConfig>.seeded(initialConfig),
        _initialConfig = initialConfig,
        _backends = backends {
    _setupRemoteListeners();
  }

  /// Setup listeners for remote availability changes across all backends.
  void _setupRemoteListeners() {
    for (final backend in _backends) {
      final subscription = backend.remotesChanged.listen((_) {
        _onRemotesChanged();
      });
      _remoteSubscriptions.add(subscription);
    }

    // Check initial state
    _onRemotesChanged();
  }

  /// Handle remote availability changes.
  void _onRemotesChanged() {
    // Check if any available remote uses shard datasets
    final anyDatasetRemote = _backends.any((backend) {
      return backend.remotes.any((remote) {
        // Remote must be available to be considered
        // We can't check availability synchronously here, but remotes list
        // only contains authenticated/configured remotes, so we can assume they're potentially available
        return remote.useShardDatasets;
      });
    });

    if (anyDatasetRemote != _needsPrefetchAll) {
      _needsPrefetchAll = anyDatasetRemote;
      final SyncEngineConfig _effectiveConfig;
      if (_needsPrefetchAll) {
        _log.info(
            'Dataset-based remote detected - adjusting ItemFetchPolicy to Prefetch() for all indices');
        _effectiveConfig = _adjustConfigForDatasets(_initialConfig);
      } else {
        _log.info('No dataset-based remotes - using original configuration');
        _effectiveConfig = _initialConfig;
      }
      _configSubject.add(_effectiveConfig);
      // Note: Config change takes effect on next sync cycle
      // Active sync operations continue with their original config
    }
  }

  /// Adjust configuration to enforce Prefetch policy for dataset compatibility.
  static SyncEngineConfig _adjustConfigForDatasets(SyncEngineConfig config) {
    final adjustedResources = config.resources.map((resource) {
      final adjustedIndices = resource.indices.map((index) {
        // Only FullIndex has itemFetchPolicy that needs adjustment
        return switch (index) {
          FullIndexData(itemFetchPolicy: final policy)
              when policy is! Prefetch =>
            () {
              _log.warning(
                  'Overriding ItemFetchPolicy for index ${index.localName} to Prefetch() for dataset compatibility');

              return index.copyWith(
                itemFetchPolicy: ItemFetchPolicy.prefetch,
              );
            }(),
          _ => index, // GroupIndexData or already Prefetch - no change needed
        };
      }).toList();

      // Create new resource config with adjusted indices
      return resource.copyWith(indices: adjustedIndices);
    }).toList();

    return config.copyWith(
      resources: adjustedResources,
    );
  }

  Future<void> close() async {
    // Cancel remote listeners
    for (final subscription in _remoteSubscriptions) {
      await subscription.cancel();
    }
    _remoteSubscriptions.clear();
  }
}

/// Main facade for the locorda system.
///
/// Provides a simple, high-level API for offline-first applications with
/// optional Solid Pod synchronization. Handles RDF mapping, storage,
/// and sync operations transparently.
class StandardSyncEngine implements SyncEngine {
  final Storage _storage;
  final IndexManager _indexManager;
  final ConfigService _configService;
  final CrdtDocumentManager _crdtDocumentManager;
  final IriTranslator _iriTranslator;
  final GroupIndexGraphSubscriptionManager _groupIndexManager;
  final SyncManager _syncManager;
  final PhysicalTimestampFactory _physicalTimestampFactory;
  final IndexRdfGenerator _indexRdfGenerator;
  final List<Future<void> Function()> _closeFunctions;

  /// Access the sync manager for manual sync triggering and status monitoring.
  SyncManager get syncManager => _syncManager;

  StandardSyncEngine._(
      {required Storage storage,
      required IndexManager indexManager,
      required ConfigService configService,
      required ResourceLocator resourceLocator,
      required CrdtDocumentManager crdtDocumentManager,
      required IndexRdfGenerator indexRdfGenerator,
      required PhysicalTimestampFactory physicalTimestampFactory,
      required SyncManager syncManager,
      required List<Backend> backends,
      List<Future<void> Function()> closeFunctions = const []})
      : _storage = storage,
        _indexManager = indexManager,
        _configService = configService,
        _groupIndexManager = GroupIndexGraphSubscriptionManager(
          configService: configService,
        ),
        _iriTranslator = IriTranslator.forConfig(
          resourceLocator: resourceLocator,
          resourceConfigs: configService.currentConfig.resources,
        ),
        _crdtDocumentManager = crdtDocumentManager,
        _syncManager = syncManager,
        _indexRdfGenerator = indexRdfGenerator,
        _physicalTimestampFactory = physicalTimestampFactory,
        _closeFunctions = closeFunctions;

  SyncEngineConfig get _effectiveConfig => _configService.currentConfig;

  /// Set up the CRDT sync system with resource-focused configuration.
  ///
  /// This is the main entry point for applications. Creates a fully
  /// configured sync system that works locally by default.
  ///
  /// Configuration is organized around resources (Note, Category, etc.)
  /// with their paths, CRDT mappings, and indices all defined together.
  ///
  /// Throws [SyncConfigValidationException] if the configuration is invalid.
  static Future<SyncEngine> create({
    required List<Backend> backends,
    required Storage storage,
    required SyncEngineConfig config,
    PhysicalTimestampFactory? physicalTimestampFactory,
    InstallationIdFactory? installationIdFactory,
    IriTermFactory? iriFactory,
    RdfCore? rdfCore,
    http.Client? httpClient,
    Fetcher? fetcher,
  }) async {
    rdfCore ??= RdfCore.withStandardCodecs();
    httpClient ??= http.Client();
    fetcher ??= HttpFetcher(httpClient: httpClient);
    iriFactory ??= IriTerm.validated;
    final timestampFactory =
        physicalTimestampFactory ?? defaultPhysicalTimestampFactory;

    // Automatically add configuration for Framework-Owned resources
    final configService =
        ConfigService(buildEffectiveConfig(config), backends: backends);

    // Validate configuration before proceeding
    final configValidationResult =
        SyncEngineConfigValidator().validate(configService.currentConfig);

    // Throw if any validation failed
    configValidationResult.throwIfInvalid();

    // Initialize storage
    await storage.initialize();

    final localResourceLocator =
        LocalResourceLocator(iriTermFactory: iriFactory);
    // Initialize installation service
    final installationService = await InstallationService.create(
      storage: storage,
      resourceLocator: localResourceLocator,
      installationIdFactory: installationIdFactory,
      iriTermFactory: iriFactory,
      physicalTimestampFactory: timestampFactory,
    );

    // Create HlcService with installation IRI and localId
    final hlcService = HlcService(
      installationLocalId: installationService.installationLocalId,
      physicalTimestampFactory: timestampFactory,
    );
    final crdtTypeRegistry = CrdtTypeRegistry.forStandardTypes();

    // TODO: the HttpRdfGraphFetcher should be db-cached (ideally with initialization from deployment and etag)
    final mergeContractLoader = CachingMergeContractLoader(
        StandardMergeContractLoader(
            RecursiveRdfLoader(
                fetcher:
                    StandardRdfGraphFetcher(fetcher: fetcher, rdfCore: rdfCore),
                iriFactory: iriFactory),
            crdtTypeRegistry));

    final shardManager = const ShardManager();

    final indexRdfGenerator = IndexRdfGenerator(
        resourceLocator: localResourceLocator, shardManager: shardManager);

    final indexParser = IndexParser(
        knownConfig: configService.currentConfig,
        rdfGenerator: indexRdfGenerator);

    final indexDiscovery = IndexDiscovery(
      storage: storage,
      parser: indexParser,
      rdfGenerator: indexRdfGenerator,
      configService: configService,
    );

    final shardDeterminer = ShardDeterminer(
      storage: storage,
      rdfGenerator: indexRdfGenerator,
      shardManager: shardManager,
      indexDiscovery: indexDiscovery,
    );

    final frameworkIriGenerator =
        FrameworkIriGenerator(iriTermFactory: iriFactory);

    final localDocumentMerger = LocalDocumentMerger(
      frameworkIriGenerator: frameworkIriGenerator,
      crdtTypeRegistry: crdtTypeRegistry,
    );

    final crdtDocumentManager = CrdtDocumentManager(
      storage: storage,
      configService: configService,
      shardDeterminer: shardDeterminer,
      mergeContractLoader: mergeContractLoader,
      localDocumentMerger: localDocumentMerger,
      hlcService: hlcService,
      physicalTimestampFactory: timestampFactory,
    );

    // Initialize indices after installation document is created
    final indexManager = IndexManager(
      crdtDocumentManager: crdtDocumentManager,
      rdfGenerator: indexRdfGenerator,
      storage: storage,
      installationIri: installationService.installationIri,
      configService: configService,
      indexDiscovery: indexDiscovery,
      resourceLocator: localResourceLocator,
    );

    await indexManager.initializeIndices();

    final remoteDocumentMerger = RemoteDocumentMerger(
      storage: storage,
      hlcService: hlcService,
      crdtTypeRegistry: crdtTypeRegistry,
      frameworkIriGenerator: frameworkIriGenerator,
    );
    final shardDocumentGenerator = ShardDocumentGenerator(
      storage: storage,
      documentManager: crdtDocumentManager,
      indexManager: indexManager,
    );
    final remoteSyncOrchestratorFactory = (
      RemoteSyncStorage remoteSyncStorage,
      RemoteId remoteId, {
      required bool useShardDatasets,
    }) =>
        RemoteSyncOrchestrator(
          remoteSyncStorage: remoteSyncStorage,
          remoteId: remoteId,
          storage: storage,
          merger: remoteDocumentMerger,
          indexRdfGenerator: indexRdfGenerator,
          indexManager: indexManager,
          shardDeterminer: shardDeterminer,
          hlcService: hlcService,
          mergeContractLoader: mergeContractLoader,
          localDocumentMerger: localDocumentMerger,
          shardDocumentGenerator: shardDocumentGenerator,
          physicalTimestampFactory: timestampFactory,
          useShardDatasets: useShardDatasets,
        );

    final syncManager = StandardSyncManager(
        syncFunction: SyncFunction(
          storage: storage,
          configService: configService,
          shardDocumentGenerator: shardDocumentGenerator,
          backends: backends,
          remoteSyncOrchestratorFactory: remoteSyncOrchestratorFactory,
        ),
        configService: configService,
        physicalTimestampFactory: timestampFactory);

    final sync = StandardSyncEngine._(
        storage: storage,
        indexManager: indexManager,
        configService: configService,
        resourceLocator: localResourceLocator,
        crdtDocumentManager: crdtDocumentManager,
        indexRdfGenerator: indexRdfGenerator,
        physicalTimestampFactory: timestampFactory,
        syncManager: syncManager,
        backends: backends,
        closeFunctions: backends.map((b) => b.dispose).toList());

    // installation documents might be organized in indices, so we need to use graph sync instead of crdtDocumentManager directly
    await installationService.ensureDocumentSaved(sync);

    return sync;
  }

  /// Configure subscription to a group index with the given group key.
  ///
  /// ## Group Index Subscription Overview
  ///
  /// Group subscriptions determine how items within a group are fetched and synced:
  ///
  /// **Default State**: Groups are not subscribed by default. Items can still be
  /// accessed on-demand, but no automatic sync or prefetching occurs.
  ///
  /// **Implicit Subscriptions**: When individual items are fetched, groups they
  /// belong to (via their `idx:belongsToIndexShard` properties) are automatically subscribed
  /// with `ItemFetchPolicy.onRequest`. This ensures basic sync functionality.
  ///
  /// **Explicit Configuration**: This method allows you to explicitly configure
  /// a group's subscription with a specific fetch policy:
  /// - `ItemFetchPolicy.onRequest`: Fetch items only when specifically requested
  /// - `ItemFetchPolicy.prefetch`: Eagerly fetch all items in the group
  ///
  /// ## Subscription Lifecycle
  ///
  /// - **Create**: First call creates subscription with specified policy
  /// - **Update**: Subsequent calls update the fetch policy
  /// - **Persistence**: Subscriptions persist across app restarts
  /// - **No Unsubscribe**: Once subscribed, groups cannot be unsubscribed as
  ///   the subscription is required for proper sync management of items
  ///
  /// ## Technical Details
  ///
  /// Validates that G is a valid group type for the specified localName,
  /// converts the group key to RDF triples, and generates group identifiers
  /// using the configured GroupKeyGenerator.
  ///
  /// ## Example
  /// ```dart
  /// // Configure current month for eager fetching
  /// await syncSystem.configureGroupIndexSubscription(
  ///   NoteGroupKey.currentMonth,
  ///   ItemFetchPolicy.prefetch
  /// );
  ///
  /// // Later, change to on-demand fetching
  /// await syncSystem.configureGroupIndexSubscription(
  ///   NoteGroupKey.currentMonth,
  ///   ItemFetchPolicy.onRequest
  /// );
  /// ```
  ///
  /// Throws [GroupIndexGraphSubscriptionException] if:
  /// - No GroupIndex is configured for type G with the given localName
  /// - The group key cannot be serialized to RDF
  /// - No group identifiers can be generated from the group key
  ///
  Future<void> configureGroupIndexSubscription(String indexName,
      RdfGraph groupKeyGraph, ItemFetchPolicy itemFetchPolicy) async {
    // Use the GroupIndexSubscriptionManager to handle validation and processing
    final groupIdentifiers =
        await _groupIndexManager.getGroupIdentifiers(indexName, groupKeyGraph);
    final (resourceConfig, indexConfig) =
        _effectiveConfig.findGroupIndexConfig(indexName)!;
    _log.info(
        'configure called for index: $indexName and group key: $groupKeyGraph, resolved to group identifiers: $groupIdentifiers');
    for (final id in groupIdentifiers) {
      final groupIndexTemplateIri = _indexRdfGenerator
          .generateGroupIndexTemplateIri(indexConfig, resourceConfig.typeIri);
      final groupIndexIri =
          _indexRdfGenerator.generateGroupIndexIri(groupIndexTemplateIri, id);
      await _storage.saveGroupIndexSubscription(
          groupIndexIri: groupIndexIri,
          groupIndexTemplateIri: groupIndexTemplateIri,
          indexedType: resourceConfig.typeIri,
          itemFetchPolicy: itemFetchPolicy,
          createdAt: _physicalTimestampFactory().millisecondsSinceEpoch);
    }
  }

  /// Save an object with CRDT processing.
  ///
  /// Stores the object locally and triggers sync if connected to Solid Pod.
  /// Application state is updated via the hydration stream - repositories should
  /// listen to hydrateStream() to receive updates.
  ///
  /// Process:
  /// 1. CRDT processing (merge with existing, clock increment)
  /// 2. Store locally in sync system
  /// 3. Hydration stream automatically emits update
  /// 4. Schedule async Pod sync
  Future<void> save(IriTerm type, RdfGraph appData) async {
    // 1. Translate external IRIs to internal format if documentIriTemplate is configured
    final internalAppData = _iriTranslator.translateGraphToInternal(appData);

    // 2. Extract resource IRI to determine shards
    final resourceIri = internalAppData.getIdentifier(type);
    if (!LocalResourceLocator.isLocalIri(resourceIri)) {
      throw ArgumentError('''
Cannot save resource with non-local IRI $resourceIri. Only local IRIs are supported for save(). 

Use the 'documentIriTemplate' property of the resource configuration to configure automatic IRI translation from your IRI to the internal format on save().
''');
    }

    // 4. save (with CRDT processing, diffing etc)
    final saved = await retryOnConflict(
        () => _crdtDocumentManager.save(type, internalAppData),
        debugOperationName: 'save for ${resourceIri.debug}');
    if (saved == null) {
      // nothing changed, nothing to do
      return;
    }

    // 5. Update indices
    await _indexManager.updateIndices(
      document: saved.crdtDocument,
      documentIri: saved.documentIri,
      physicalTime: saved.physicalTime,
      resourceTypeIri: type,
      updatedAt: saved.updatedAt,
      missingGroupIndices: saved.missingGroupIndices,
    );
  }

  /// Ensures a resource is available locally, fetching it from the remote source if necessary.
  ///
  /// This method guarantees that after its successful completion, the requested
  /// resource will exist in the local database and be managed by the sync system.
  /// It follows a "offline-first" approach.
  ///
  /// The process is as follows:
  /// 1. It first attempts to retrieve the item from the local database using the
  ///    provided [loadFromLocal] function.
  /// 2. If the item is found locally, it is returned immediately.
  /// 3. If the item is not found locally, this method triggers a fetch from the
  ///    remote Solid Pod.
  /// 4. Once fetched, the item is processed and inserted into the local database
  ///    via the standard hydration stream, which in turn makes it available to the
  ///    rest of the application.
  /// 5. The method then returns the newly fetched and stored item.
  ///
  /// This is the primary method repositories should use for on-demand loading of
  /// individual resources that may not be part of an eagerly synced group. It
  /// abstracts away all the complexity of network requests, caching, and state
  /// management.
  ///
  /// Throws a [TimeoutException] if the remote fetch takes too long.
  ///
  ///
  /// #### Parameters:
  ///   - [id]: The unique identifier of the resource to ensure is available.
  ///   - [loadFromLocal]: A callback function that takes the resource `id` and
  ///     is responsible for loading it from the local application database.
  ///
  /// #### Returns:
  /// A `Future` that completes with the resource of type [T] once it is available
  /// locally. Returns `null` if the resource cannot be found either locally or
  /// remotely, or if the request times out.
  ///
  /// #### Example:
  ///
  /// ```dart
  /// // Inside a repository class
  ///
  /// Future<Note?> getNoteById(String noteId) async {
  ///   return await _syncSystem.ensure<Note>(
  ///     noteId,
  ///     loadFromLocal: (id) async {
  ///       final driftNote = await _noteDao.getNoteById(id);
  ///       return driftNote != null ? _noteFromDrift(driftNote) : null;
  ///     },
  ///   );
  /// }
  /// ```
  Future<RdfGraph?> ensure(IriTerm typeIri, IriTerm localIri,
      {required Future<RdfGraph?> Function(IriTerm localIri) loadFromLocal,
      Duration? timeout = const Duration(seconds: 15),
      bool skipInitialFetch = false}) async {
    // 1. First, try to load from the local database.
    final localItem = skipInitialFetch ? null : await loadFromLocal(localIri);
    if (localItem != null) {
      return localItem;
    }

    // TODO: properly implement remote fetch with pending fetch tracking
    // TODO: check with fetch strategy - if fetch is prefetch, we can return a 404
    // immediately since the item must be present through sync - but note that
    // it would be a severe error if an ite is in the index entries, in prefetch mode, but not present in the documents.
/*
Check with https://g.co/gemini/share/60e9b2d3036e for the details

    // 2. If not found, check if a fetch is already in progress.
    if (_pendingFetches.containsKey(id)) {
      return (await _pendingFetches[id]!.future) as T?;
    }

    // 3. If not, initiate a new fetch.
    final completer = Completer<T?>();
    _pendingFetches[id] = completer;

    // 4. Trigger the remote fetch in the background.
    // (This reuses the logic from the previous proposal)
    _fetchAndEmit<T>(id);

    // 5. Return the future, which completes when the item arrives.
    return completer.future.timeout(const Duration(seconds: 15), onTimeout: () {
      _pendingFetches.remove(id);
      // Return null or throw a custom exception on timeout.
      return null;
    });

    */
    return null;
  }

  /// Delete a document with CRDT processing.
  ///
  /// This performs document-level deletion, marking the entire document as deleted
  /// and affecting all resources contained within, following CRDT semantics.
  /// Application state is updated via the hydration stream - repositories should
  /// listen to hydrateStream() to receive deletion notifications.
  ///
  /// Process:
  /// 1. Add crdt:deletedAt timestamp to document
  /// 2. Perform universal emptying (remove semantic content, keep framework metadata)
  /// 3. Store updated document in sync system
  /// 4. Hydration stream automatically emits deletion (via Drift's reactive queries)
  /// 5. Schedule async Pod sync
  Future<void> deleteDocument(IriTerm typeIri, IriTerm externalIri) async {
    // Translate external IRI to internal format
    // ignore: unused_local_variable
    final internalIri = _iriTranslator.externalToInternal(externalIri);

    // ignore: unused_local_variable
    final resourceConfig = _effectiveConfig.getResourceConfig(typeIri);

    // TODO: Implement proper CRDT deletion processing:
    // 1. Load existing document
    // 2. Add crdt:deletedAt timestamp
    // 3. Perform universal emptying (remove semantic content, keep framework metadata)
    // 4. Save to storage (this will trigger Drift's watch() to emit updates automatically)
    // 5. Update indices accordingly

    // TODO: universal emptying **must** preserve the primaryTopic relationship
    // to ensure the resource IRI remains known for hydration streams
    throw UnimplementedError('deleteDocument not yet fully implemented');
  }

  /// Hydrates resources of the specified type using a reactive stream.
  ///
  /// Returns a stream of [HydrationBatch]es containing updates, deletions,
  /// and cursor information.
  ///
  /// ## Without Index (indexName == null)
  /// Hydrates complete resource documents:
  /// - Loads all existing documents in batches (bounded by [initialBatchSize])
  /// - Switches to reactive mode for ongoing changes (via Drift's watch())
  /// - Orders documents by updatedAt ascending for consistent processing
  /// - Emits (primaryTopicIri, appGraph) for each resource
  ///
  /// ## With Index (indexName != null)
  /// Hydrates lightweight index entries from the specified index:
  /// - Loads index entries in batches (bounded by [initialBatchSize])
  /// - Switches to reactive mode for ongoing changes
  /// - **Entry-level change tracking**: Only changed entries are re-emitted,
  ///   not entire shards. Uses progressive cursor tracking to minimize overhead.
  /// - Extracts entries with indexed properties only (not full resources)
  /// - Emits (resourceIri, entryGraph) for each indexed item
  /// - For GroupIndex: Automatically handles subscription changes and loads
  ///   historical data for newly subscribed groups
  ///
  /// ## Performance Characteristics
  /// - **Batch Loading Phase**: Controlled by [initialBatchSize], loads existing
  ///   data in configurable chunks to avoid memory spikes
  /// - **Reactive Phase**: Only emits entries that have actually changed since
  ///   the last emission, using entry-level timestamps for efficient filtering
  /// - **Memory Footprint**: Minimal overhead (one cursor int per active stream)
  ///
  /// The caller is responsible for:
  /// - Providing the current cursor position via [cursor]
  /// - Processing updates and deletions from the batch
  /// - Persisting cursor updates for resume capability
  ///
  Stream<HydrationBatch> hydrateStream({
    required IriTerm typeIri,
    String? indexName,
    String? cursor,
    int initialBatchSize = 100,
  }) async* {
    // Validate configuration
    final resourceConfig = _effectiveConfig.getResourceConfig(typeIri);
    if (indexName == null) {
      yield* _hydrateRootResourceStream(
        typeIri: typeIri,
        cursor: cursor,
        initialBatchSize: initialBatchSize,
      );
    } else {
      // Index-specific hydration
      final indexConfig = resourceConfig.getIndexByName(indexName);

      // Parse cursor format: "<millis-since-epoch>@<indexSetVersionId>"
      // e.g., "1697198445123@42"
      // If no @ present, assume just timestamp with no index set version tracking
      final (cursorTimestamp, cursorIndexSetVersionId) = _parseCursor(cursor);
      final startCursor = cursorTimestamp ?? 0;
      switch (indexConfig) {
        case GroupIndexData _:
          // For GroupIndex: Use reactive subscriptions that automatically rebuild the stream
          // when subscriptions change.
          final templateIri = _indexRdfGenerator.generateGroupIndexTemplateIri(
              indexConfig, typeIri);
          // Reactive approach: Watch subscription changes and rebuild the entry stream
          yield* _storage
              .watchSubscribedGroupIndexIris(templateIri)
              .switchMap((indexIris) => _doHydrateIndexEntryStream(
                    indexName,
                    indexIris,
                    startCursor,
                    useIndexSetVersionId: true,
                    cursorIndexSetVersionId: cursorIndexSetVersionId,
                    initialBatchSize: initialBatchSize,
                  ));
        case FullIndexData _: // FullIndex: there is just a single index
          final indexIri =
              _indexRdfGenerator.generateFullIndexIri(indexConfig, typeIri);
          yield* _doHydrateIndexEntryStream(
            indexName,
            {indexIri},
            startCursor,
            useIndexSetVersionId: false,
            initialBatchSize: initialBatchSize,
          );
      }
    }
  }

  (int? cursorTimestamp, int? setVersionId) _parseCursor(String? cursor) {
    // Parse cursor format: "<millis-since-epoch>@<setVersionId>"
    // e.g., "1697198445123@42"
    // If no @ present, assume old format (just timestamp) with no version tracking
    int? cursorTimestamp;
    int? cursorSetVersionId;
    if (cursor != null && cursor.isNotEmpty) {
      final parts = cursor.split('@');
      cursorTimestamp = int.tryParse(parts[0]);
      if (cursorTimestamp == null) {
        _log.warning(
            'Invalid cursor timestamp: ${parts[0]}, starting from beginning.');
      }
      if (parts.length > 1) {
        cursorSetVersionId = int.tryParse(parts[1]);
      }
    }
    return (cursorTimestamp, cursorSetVersionId);
  }

  /// Formats a cursor string from a timestamp and optional set version ID
  String _formatCursor(int timestamp, int? setVersionId) {
    return setVersionId != null ? '$timestamp@$setVersionId' : '$timestamp';
  }

  Stream<HydrationBatch> _doHydrateIndexEntryStream(
    String indexName,
    Set<IriTerm> indexIris,
    int startCursor, {
    bool useIndexSetVersionId = false,
    int? cursorIndexSetVersionId,
    required int initialBatchSize,
  }) async* {
    int? indexSetVersionId;
    // Track the last cursor emitted from batch loading
    int lastEmittedCursor = startCursor;

    // If useIndexSetVersionId is true, we need to associate the indexIris with a set version
    // to track which indices we query against. This also means that the set version
    // will be included in the actual (string) cursor we emit
    if (useIndexSetVersionId) {
      if (indexIris.isEmpty) {
        _log.warning(
            'No subscriptions for GroupIndex $indexName, emitting empty stream.');
        yield (
          updates: <IdentifiedGraph>[],
          deletions: <IdentifiedGraph>[],
          cursor: startCursor.toString()
        );
        return;
      }
      var now = _physicalTimestampFactory().millisecondsSinceEpoch;
      // Create/get set version for current subscriptions
      indexSetVersionId = await _storage.ensureIndexSetVersion(
        indexIris: indexIris,
        createdAt: now,
      );

      // Determine which index IRIs are new vs. old based on cursor
      final cursorIndexIris = cursorIndexSetVersionId == null
          ? const <IriTerm>{}
          : await _storage.getIndexIrisForVersion(cursorIndexSetVersionId);

      final newIndexIris = indexIris.difference(cursorIndexIris);

      final hasNewIndices = newIndexIris.isNotEmpty;

      // Phase 1a: Load historical data for new indices (0 → startCursor)
      if (hasNewIndices && startCursor > 0) {
        _log.info(
            'Loading historical data for ${newIndexIris.length} new indices up to cursor $startCursor');

        final result = _loadExistingEntriesAsStream(
          newIndexIris,
          indexSetVersionId,
          fromCursor: 0,
          toCursor: startCursor,
          initialBatchSize: initialBatchSize,
        );
        yield* result.stream;
        lastEmittedCursor = await result.lastCursor;
      }
    }

    // Phase 1b: Load current data for all subscriptions (from startCursor)
    final result = _loadExistingEntriesAsStream(
      indexIris,
      indexSetVersionId,
      fromCursor: lastEmittedCursor,
      initialBatchSize: initialBatchSize,
    );
    yield* result.stream;
    lastEmittedCursor = await result.lastCursor;

    // Phase 2: Switch to reactive watch for ongoing changes
    yield* _storage
        .watchIndexEntries(
          indexIris: indexIris,
          cursorTimestamp: lastEmittedCursor,
        )
        .where((entries) => entries.isNotEmpty)
        .map((entries) => _convertIndexEntriesToBatch(
            entries, entries.last.updatedAt, indexSetVersionId));
  }

  /// Streams index entries in batches and returns the last emitted cursor.
  ///
  /// Returns a record containing:
  /// - stream: The stream of hydration batches
  /// - lastCursor: A future that completes with the last cursor emitted
  ///
  /// This allows callers to know where the batch loading ended, which is
  /// necessary to correctly position the cursor for the reactive watch phase.
  ({Stream<HydrationBatch> stream, Future<int> lastCursor})
      _loadExistingEntriesAsStream(
          Set<IriTerm> indexIris, int? indexSetVersionId,
          {required int fromCursor,
          int? toCursor,
          required int initialBatchSize}) {
    final controller = StreamController<HydrationBatch>();
    final lastCursorCompleter = Completer<int>();
    var lastEmittedCursor = fromCursor;

    Future<void> loadEntries() async {
      try {
        int? cursor = fromCursor;
        while (cursor != null && (toCursor == null || cursor < toCursor)) {
          final page = await _storage.getIndexEntries(
            indexIris: indexIris,
            cursorTimestamp: cursor,
            limit: initialBatchSize,
          );

          if (page.entries.isNotEmpty) {
            final batch = _convertIndexEntriesToBatch(
                page.entries, page.lastCursor, indexSetVersionId);
            controller.add(batch);
            lastEmittedCursor = page.lastCursor ?? lastEmittedCursor;
            cursor = page.lastCursor;
          }

          if (!page.hasMore ||
              (toCursor != null && (cursor != null && cursor > toCursor))) {
            break;
          }
        }
        lastCursorCompleter.complete(lastEmittedCursor);
      } catch (e, st) {
        lastCursorCompleter.completeError(e, st);
        _log.severe('Error loading index entries', e, st);
        controller.addError(e, st);
      } finally {
        await controller.close();
      }
    }

    loadEntries();

    return (stream: controller.stream, lastCursor: lastCursorCompleter.future);
  }

  // Helper to convert DB entries to HydrationBatch
  HydrationBatch _convertIndexEntriesToBatch(
      List<storage.IndexEntryWithIri> entries,
      int? lastCursor,
      int? setVersionId) {
    final updates = <IdentifiedGraph>[];
    final deletions = <IdentifiedGraph>[];

    for (final entry in entries) {
      // Entry structure in DB:
      // - entry.resourceIri: The resource IRI (already external, stored as IriTerm.value)
      // - entry.clockHash: The CRDT clock hash of the resource
      // - entry.headerProperties: Turtle-encoded triples with indexed properties
      //
      // In RDF, the full entry looks like:
      //   entryIri idx:resource resourceIri .
      //   entryIri crdt:clockHash "hash" .
      //   entryIri schema:title "..." .  // header properties
      //
      // For hydration, we flatten this to just the resource IRI and its properties.
      final resourceIri = entry.resourceIri;

      // Build graph with header properties
      final triples = <Triple>[];

      // Add header properties if present
      // Header properties are stored as Turtle-encoded triples in the DB
      if (entry.headerProperties != null) {
        final headerGraph = turtle.decode(entry.headerProperties!);
        triples.addAll(headerGraph.triples);
      }

      final graph = RdfGraph.fromTriples(triples);

      // Entries with isDeleted=true are tombstones
      if (entry.isDeleted) {
        deletions.add((resourceIri, graph));
      } else {
        updates.add((resourceIri, graph));
      }
    }

    return (
      updates: updates,
      deletions: deletions,
      cursor: _formatCursor(lastCursor ?? 0, setVersionId)
    );
  }

  Stream<HydrationBatch> _hydrateRootResourceStream({
    required IriTerm typeIri,
    String? cursor,
    int initialBatchSize = 100,
  }) async* {
    HydrationBatch convertResult(
        List<StoredDocument> documents, String? cursor) {
      final (deletions, updates) = documents
          .fold((<IdentifiedGraph>[], <IdentifiedGraph>[]), (acc, doc) {
        // Translate internal IRIs to external format for application consumption
        final externalIri = _iriTranslator.internalToExternal(doc.documentIri);
        final externalGraph =
            _iriTranslator.translateGraphToExternal(doc.document);

        final primaryTopicIri = externalGraph.expectSingleObject<IriTerm>(
            externalIri, SyncManagedDocument.foafPrimaryTopic);
        final appGraph = primaryTopicIri != null
            ? externalGraph.subgraph(primaryTopicIri)
            : externalGraph;
        final isDeletion = externalGraph.hasTriples(
            subject: externalIri, predicate: SyncManagedDocument.crdtDeletedAt);
        if (primaryTopicIri == null) {
          _log.warning(
              'Document ${doc.documentIri} (isDeletion: $isDeletion) is missing foaf:primaryTopic, cannot determine resource IRI. Skipping.');
          return acc;
        }
        (isDeletion ? acc.$1 : acc.$2).add((primaryTopicIri, appGraph));
        return acc;
      });
      return (updates: updates, deletions: deletions, cursor: cursor);
    }

    // Phase 1: Load all existing documents in batches using pagination
    // This ensures we don't load unbounded amounts of data into memory
    while (true) {
      final result = await _storage.getDocumentsModifiedSince(
        typeIri,
        cursor,
        limit: initialBatchSize,
      );

      // Process each document in the batch
      yield convertResult(result.documents, result.currentCursor);

      cursor = result.currentCursor;

      // If there are no more documents to fetch, we've loaded everything
      if (!result.hasNext) {
        break;
      }
    }

    // Phase 2: Switch to reactive watch for ongoing changes
    // This automatically emits updates whenever documents of this type change
    yield* _storage
        .watchDocumentsModifiedSince(typeIri, cursor)
        .map((result) => convertResult(result.documents, result.currentCursor));
  }

  /// Close the sync system and free resources.
  Future<void> close() async {
    await _configService.close();

    await _syncManager.dispose();
    await _crdtDocumentManager.close();
    for (final func in _closeFunctions) {
      await func();
    }
  }
}
