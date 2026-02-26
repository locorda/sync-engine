/// Object-oriented wrapper for the CRDT sync system.
///
/// Provides a type-safe API for working with Dart domain objects instead of
/// raw RDF graphs. Transparently handles RDF serialization/deserialization
/// using RdfMapper.
library;

import 'dart:async';

import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:locorda_rdf_mapper/mapper.dart';
import 'package:logging/logging.dart';

import 'config/locorda_config.dart';
import 'config/locorda_config_converter.dart';
import 'config/locorda_config_util.dart';
import 'config/locorda_config_validator.dart';
import 'index/group_index_sync_failed_exception.dart';
import 'index/group_index_subscription_manager.dart';
import 'mapping/local_resource_iri_service.dart';
import 'mapping/solid_mapping_context.dart';

/// Type alias for mapper initializer functions.
///
/// These functions receive framework services via SolidMappingContext
/// and return a fully configured RdfMapper.
typedef MapperInitializerFunction = RdfMapper Function(
    SolidMappingContext context);

/// Type alias for a hydration batch with decoded objects of type [T].
typedef TypedHydrationBatch<T> = ({
  List<T> updates,

  /// Ids of deleted items
  List<String> deletions,
  String? cursor,
});

/// Factory function that creates a SyncEngine instance.
///
/// Used by ObjectSyncEngine.create() to obtain the underlying sync engine.
typedef SyncEngineFactory = Future<SyncEngine> Function(
    SyncEngineConfig config);

/// Object-oriented facade for CRDT sync operations with automatic RDF mapping.
///
/// This class wraps [SyncEngine] to provide a type-safe API that works with
/// Dart domain objects (like `Note`, `Category`) instead of raw RDF graphs.
/// All RDF serialization/deserialization is handled transparently via [RdfMapper].
///
/// ## Key Responsibilities
///
/// 1. **Object Mapping**: Converts between Dart objects and RDF graphs
/// 2. **Type Safety**: Provides generic methods like `save<Note>()`, `ensure<Note>()`
/// 3. **Configuration**: Validates and converts [LocordaConfig] to [SyncEngineConfig]
/// 4. **Resource Management**: Manages resource type IRIs and local IRI generation
///
/// ## Usage
///
/// Most applications should use [Locorda] from `package:locorda/locorda.dart`,
/// which provides additional worker setup and UI integration. Use ObjectSyncEngine
/// directly only when:
/// - Building custom abstractions over the sync system
/// - Testing sync behavior with custom SyncEngine implementations
///
/// ## API Overview
///
/// ```dart
/// final objectSyncEngine = await ObjectSyncEngine.create(...);
///
/// // Save objects (automatically mapped to RDF)
/// await objectSyncEngine.save(myNote);
///
/// // Stream hydration (automatically decoded from RDF)
/// objectSyncEngine.hydrateStream<Note>().listen((batch) {
///   for (final note in batch.updates) {
///     // Work with typed Dart objects
///   }
/// });
///
/// // Ensure resource availability (fetch if needed)
/// final note = await objectSyncEngine.ensure<Note>(
///   'note-123',
///   loadFromLocal: (id) => noteDao.getById(id),
/// );
///
/// // Delete documents
/// await objectSyncEngine.deleteDocument<Note>('note-123');
/// ```
///
/// ## Comparison with SyncEngine
///
/// | Feature | SyncEngine | ObjectSyncEngine |
/// |---------|-----------|------------------|
/// | Input | `RdfGraph` | Dart objects |
/// | Output | `RdfGraph` | Dart objects |
/// | Config | `SyncEngineConfig` (IRIs) | `LocordaConfig` (Dart types) |
/// | Mapping | Manual | Automatic via RdfMapper |
/// | Type safety | Runtime | Compile-time |
///
class ObjectSyncEngine {
  final SyncEngine _syncSystem;
  final RdfMapper _mapper;
  final LocordaConfig _config;
  final ResourceTypeCache _resourceTypeCache;
  late final GroupKeyConverter _groupKeyConverter;
  final ResourceLocator _localResourceLocator;

  /// Access the sync manager for manual sync triggering and status monitoring.
  ///
  /// Use this to:
  /// - Trigger manual sync: `syncManager.sync()`
  /// - Monitor sync status: `syncManager.statusStream`
  /// - Access current state: `syncManager.currentState`
  /// - Control automatic sync: `syncManager.enableAutoSync()` / `disableAutoSync()`
  SyncManager get syncManager => _syncSystem.syncManager;

  ObjectSyncEngine._({
    required SyncEngine syncEngine,
    required RdfMapper mapper,
    required LocordaConfig config,
    required ResourceTypeCache resourceTypeCache,
    required ResourceLocator localResourceLocator,
  })  : _syncSystem = syncEngine,
        _mapper = mapper,
        _config = config,
        _resourceTypeCache = resourceTypeCache,
        _localResourceLocator = localResourceLocator {
    _groupKeyConverter = GroupKeyConverter(
      config: _config,
      mapper: _mapper,
    );
  }

  static Future<
      ({
        LocalResourceLocator localResourceLocator,
        ResourceTypeCache resourceTypeCache,
        SyncEngineConfig syncEngineConfig,
        RdfMapper mapper,
      })> _setup({
    required LocordaConfig config,
    required MapperInitializerFunction mapperInitializer,
    IriTermFactory? iriTermFactory,
    RdfCore? rdfCore,
  }) async {
    iriTermFactory ??= IriTerm.validated;
    rdfCore ??= RdfCore.withStandardCodecs();

    final localResourceLocator =
        LocalResourceLocator(iriTermFactory: iriTermFactory);
    final iriService = LocalResourceIriService(localResourceLocator);
    final mappingContext = SolidMappingContext(
      resourceIriFactory: iriService.createResourceIriMapper,
      resourceRefFactory: iriService.createResourceRefMapper,
      indexItemIriFactory: iriService.createIndexItemIriMapper,
      baseRdfMapper: RdfMapper(
          registry: RdfMapperRegistry(),
          iriTermFactory: iriTermFactory,
          rdfCore: rdfCore),
    );
    final mapper = mapperInitializer(mappingContext);

    final resourceTypeCache = buildResourceTypeCache(mapper, config);

    // Validate configuration before proceeding
    final configValidationResult = LocordaConfigValidator()
        .validate(config, resourceTypeCache, mapper: mapper);

    // Validate IRI service setup and finish setup if valid
    final iriServiceValidationResult =
        iriService.finishSetupAndValidate(resourceTypeCache);

    // Combine validation results
    final combinedValidationResult = ValidationResult.merge(
        [configValidationResult, iriServiceValidationResult]);

    // Throw if any validation failed
    combinedValidationResult.throwIfInvalid();

    final syncEngineConfig = toSyncEngineConfig(config, resourceTypeCache);
    return (
      syncEngineConfig: syncEngineConfig,
      localResourceLocator: localResourceLocator,
      resourceTypeCache: resourceTypeCache,
      mapper: mapper,
    );
  }

  /// Creates an ObjectSyncEngine with automatic RDF mapping configuration.
  ///
  /// This is a low-level factory that instantiates a [SyncEngine] via [syncEngineFactory],
  /// passing it the converted configuration. Most applications should use
  /// `Locorda.create()` instead, which provides worker setup and UI integration.
  ///
  /// ## Setup Process
  ///
  /// 1. **Mapper initialization**: Calls [mapperInitializer] with framework services
  ///    (IRI factories, resource references) to create a configured [RdfMapper]
  /// 2. **Configuration validation**: Validates [config] against resource types
  ///    and RDF mappings, checking for consistency
  /// 3. **IRI service setup**: Configures local resource IRI generation and validation
  /// 4. **Config conversion**: Converts [LocordaConfig] (Dart types) to
  ///    [SyncEngineConfig] (RDF IRIs)
  /// 5. **SyncEngine creation**: Calls [syncEngineFactory] with the converted config
  ///
  /// ## Parameters
  ///
  /// - [config]: High-level configuration with Dart types and resource definitions
  /// - [mapperInitializer]: Function that configures RDF mapping with framework services
  /// - [syncEngineFactory]: Factory function that creates the underlying SyncEngine
  /// - [iriTermFactory]: Optional custom IRI term factory (defaults to validated IRIs)
  /// - [rdfCore]: Optional custom RDF core with codecs (defaults to standard codecs)
  ///
  /// ## Example: Direct Usage
  ///
  /// ```dart
  /// final objectSyncEngine = await ObjectSyncEngine.create(
  ///   config: LocordaConfig(
  ///     resources: [
  ///       ResourceConfig(
  ///         type: Note,
  ///         crdtMapping: Uri.parse('https://example.org/mappings/note-v1.ttl'),
  ///         indices: [...],
  ///       ),
  ///     ],
  ///   ),
  ///   mapperInitializer: (context) => initRdfMapper(
  ///     rdfMapper: context.baseRdfMapper,
  ///     $resourceIriFactory: context.resourceIriFactory,
  ///     $resourceRefFactory: context.resourceRefFactory,
  ///     $indexItemIriFactory: context.indexItemIriFactory,
  ///   ),
  ///   syncEngineFactory: (config) async {
  ///     // Create your SyncEngine with storage and remotes
  ///     return SyncEngine(
  ///       storage: myDriftStorage,
  ///       remotes: [mySolidRemote],
  ///       config: config,
  ///     );
  ///   },
  /// );
  /// ```
  ///
  /// ## Example: With Locorda (Recommended)
  ///
  /// ```dart
  /// // Locorda handles SyncEngine creation internally via worker setup
  /// final locorda = await Locorda.create(
  ///   config: locordaConfig,
  ///   mapperInitializer: myMapperInitializer,
  ///   workerSetup: setupWorkerEngine,  // Creates SyncEngine in worker
  ///   remotes: [SolidMainIntegration(...)],
  ///   storage: DriftMainHandler(),
  /// );
  /// ```
  ///
  /// Throws [SyncConfigValidationException] if the configuration is invalid.
  static Future<ObjectSyncEngine> create({
    required LocordaConfig config,
    required MapperInitializerFunction mapperInitializer,
    required SyncEngineFactory syncEngineFactory,
    IriTermFactory? iriTermFactory,
    RdfCore? rdfCore,
  }) async {
    final (
      :localResourceLocator,
      :resourceTypeCache,
      :syncEngineConfig,
      :mapper
    ) = await _setup(
      config: config,
      mapperInitializer: mapperInitializer,
      iriTermFactory: iriTermFactory,
      rdfCore: rdfCore,
    );

    // Create storage plugin registry if plugins provided
    final syncEngine = await syncEngineFactory(
      syncEngineConfig,
    );

    return ObjectSyncEngine._(
      syncEngine: syncEngine,
      mapper: mapper,
      config: config,
      localResourceLocator: localResourceLocator,
      resourceTypeCache: resourceTypeCache,
    );
  }

  /// Reactively observes the sync state of one group index instance.
  Stream<IndexInstanceSyncState> watchGroupIndexSyncState<G>(G groupKey,
      {String localName = defaultIndexLocalName}) {
    final (indexName: indexName, groupKeyGraph: groupKeyGraph) =
        _groupKeyConverter.convertGroupKey<G>(groupKey, localName: localName);

    return _syncSystem.watchGroupIndexSyncState(
      indexName: indexName,
      groupKeyGraph: groupKeyGraph,
    );
  }

  /// Reactively observes the sync state of the full-index instance for [T].
  Stream<IndexInstanceSyncState> watchSyncState<T>(
      {String fullIndexLocalName = defaultIndexLocalName}) {
    final typeIri = _getTypeIri(T);
    final indexName =
        getFullIndexNameForResourceType(_config, T, fullIndexLocalName);
    if (indexName == null) {
      throw Exception(
          'No FullIndex found for resource type $T with localName "$fullIndexLocalName".');
    }

    return _syncSystem.watchSyncState(typeIri: typeIri, indexName: indexName);
  }

  /// Ensures a group index subscription exists and optionally triggers sync.
  ///
  /// When [rootResourceFetchPolicy] is `null`, the policy configured on the
  /// [GroupIndexData] for the resolved index is used.
  Future<void> ensureGroupIndexSubscription<G>(
    G groupKey, {
    RootResourceFetchPolicy? rootResourceFetchPolicy,
    bool triggerSync = true,
    String localName = defaultIndexLocalName,
  }) {
    final (indexName: indexName, groupKeyGraph: groupKeyGraph) =
        _groupKeyConverter.convertGroupKey<G>(groupKey, localName: localName);

    return _syncSystem.ensureGroupIndexSubscription(
      indexName: indexName,
      groupKeyGraph: groupKeyGraph,
      rootResourceFetchPolicy: rootResourceFetchPolicy,
      triggerSync: triggerSync,
    );
  }

  /// Ensures initial sync has completed for a group index instance.
  ///
  /// When [rootResourceFetchPolicy] is `null`, the policy configured on the
  /// [GroupIndexData] for the resolved index is used.
  Future<void> ensureGroupIndexSynced<G>(G groupKey,
      {String localName = defaultIndexLocalName,
      RootResourceFetchPolicy? rootResourceFetchPolicy}) async {
    final (indexName: indexName, groupKeyGraph: groupKeyGraph) =
        _groupKeyConverter.convertGroupKey<G>(groupKey, localName: localName);

    try {
      await _syncSystem.ensureGroupIndexSynced(
        indexName: indexName,
        groupKeyGraph: groupKeyGraph,
        rootResourceFetchPolicy: rootResourceFetchPolicy,
      );
    } on IndexInstanceSyncFailedException catch (error) {
      throw GroupIndexSyncFailedException(
        error.message,
        lastState: error.lastState,
      );
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
  Future<void> save<T>(T object) async {
    IriTerm typeIri = _getTypeIri(T);
    final graph =
        _mapper.graph.encodeObject(object); // Validate object can be mapped;
    _syncSystem.save(typeIri, graph);
  }

  /// Save multiple objects with CRDT processing in sequence.
  ///
  /// Each object is processed independently following the same CRDT merge logic
  /// as individual save() calls.
  Future<void> saveAll<T>(List<T> objects) async {
    IriTerm typeIri = _getTypeIri(T);

    // Convert objects to graphs and delegate to underlying sync system
    final items = objects.map((object) {
      final graph = _mapper.graph.encodeObject(object);
      return (typeIri, graph);
    }).toList();

    // Properly pass through to SyncEngine.saveAll, not a loop
    await _syncSystem.saveAll(items);
  }

  IriTerm _getTypeIri(Type type) => _resourceTypeCache.getIri(type);

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
  Future<T?> ensure<T>(String id,
      {required Future<T?> Function(String id) loadFromLocal,
      Duration? timeout = const Duration(seconds: 15)}) async {
    // Shortcut the _syncSystem.ensure() if the data is available locally - this
    // saves us from converting from and to RDF unnecessarily.
    final r = await loadFromLocal(id);
    if (r != null) {
      return r;
    }

    IriTerm typeIri = _getTypeIri(T);

    // If not found locally, ensure it from the sync system
    final localIri =
        _localResourceLocator.toIri(ResourceIdentifier.document(typeIri, id));

    final graph = await _syncSystem.ensure(typeIri, localIri,
        skipInitialFetch: true, loadFromLocal: (IriTerm iri) async {
      final resId =
          _localResourceLocator.fromIri(iri, expectedTypeIri: typeIri);
      final obj = await loadFromLocal(resId.id);
      return obj == null ? null : _mapper.graph.encodeObject(obj);
    }, timeout: timeout);

    return graph != null ? _mapper.graph.decodeObject<T>(graph) : null;
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
  /// 4. Hydration stream automatically emits deletion
  /// 5. Schedule async Pod sync
  Future<void> deleteDocument<T>(String id) async {
    IriTerm typeIri = _getTypeIri(T);
    final localIri =
        _localResourceLocator.toIri(ResourceIdentifier.document(typeIri, id));
    return _syncSystem.deleteDocument(typeIri, localIri);
  }

  /// Hydrates resources of type [T] using a reactive stream.
  ///
  /// Returns a stream of decoded objects of type [T]. The stream automatically:
  /// - Loads all existing resources/entries in batches (controlled by [initialBatchSize])
  /// - Switches to reactive mode for ongoing changes (via Drift's watch())
  /// - Orders resources by their update timestamp for consistent processing
  /// - Handles RDF mapping/unmapping transparently
  ///
  /// ## Behavior Based on Type [T]
  ///
  /// **Full Resource Hydration** (if [T] is a `@LocordaResource` type):
  /// - Loads complete resource documents with all properties
  /// - Uses [cursor] to resume from last processed position
  /// - Each emission represents a full resource object
  ///
  /// **Index Entry Hydration** (if [T] is a `@LocordaIndexItem` type):
  /// - Loads lightweight index entries with only indexed properties
  /// - **Entry-level change tracking**: Only changed entries are re-emitted,
  ///   not entire shards, using progressive cursor tracking
  /// - For GroupIndex: Automatically handles subscription changes and loads
  ///   historical data for newly subscribed groups
  /// - Significantly more efficient for large datasets
  ///
  /// ## Parameters
  /// - [cursor]: Resume position from previous hydration. Format depends on
  ///   hydration type (see [SyncEngine.hydrateStream] for details).
  ///   If null, starts from the beginning.
  /// - [localName]: Distinguishes between different indices using the same
  ///   Dart class (e.g., different GroupIndex configurations). Only relevant
  ///   for index item types. Default: [defaultIndexLocalName].
  /// - [initialBatchSize]: Number of items to load per batch during initial
  ///   catch-up phase. Default: 100. Adjust based on memory constraints and
  ///   network conditions.
  ///
  /// ## Performance Characteristics
  /// - **Batch Loading Phase**: Processes existing data in chunks of [initialBatchSize]
  /// - **Reactive Phase**: Only emits changed items, minimizing overhead
  /// - **Memory Efficient**: Streams data incrementally, never loads entire dataset
  ///
  /// ## Example
  /// ```dart
  /// // Full resource hydration
  /// syncSystem.hydrateStream<Note>(cursor: lastCursor).listen((batch) {
  ///   for (final note in batch.updates) {
  ///     // Process complete Note object
  ///   }
  /// });
  ///
  /// // Index entry hydration (lightweight)
  /// syncSystem.hydrateStream<NoteIndexEntry>(cursor: lastCursor).listen((batch) {
  ///   for (final entry in batch.updates) {
  ///     // Process lightweight NoteIndexEntry (only indexed properties)
  ///   }
  /// });
  /// ```
  ///
  Stream<TypedHydrationBatch<T>> hydrateStream<T>({
    String? cursor,
    String localName = defaultIndexLocalName,
    int initialBatchSize = 100,
  }) {
    final IriTerm typeIri;
    final String? indexName;
    final resourceConfig = _config.getResourceConfig(T);
    if (resourceConfig != null) {
      typeIri = _resourceTypeCache.getIri(T);
      indexName = null;
    } else {
      // Not a resource type, check if it's an index item type
      final r = findIndexConfigForType<T>(_config, localName);
      if (r == null) {
        throw Exception(
            'Type $T is not a registered resource or index item type.');
      }
      final (resourceConfig, index) = r;
      indexName = getIndexName(resourceConfig, index);
      typeIri = _resourceTypeCache.getIri(resourceConfig.type);
    }
    final completeness = indexName == null
        // it is advised for applications to use @RdfUnmappedTriples in order to
        // capture all data on the app resources, but it is not strictly required
        // so we only warn
        ? CompletenessMode.warnOnly
        // index items may have partial data, that is absolutely fine
        : CompletenessMode.lenient;

    return _syncSystem
        .hydrateStream(
          typeIri: typeIri,
          indexName: indexName,
          cursor: cursor,
          initialBatchSize: initialBatchSize,
        )
        .map((batch) => (
              updates: batch.updates
                  .map((identifiedGraph) => _mapper.graph.decodeObject<T>(
                      identifiedGraph.$2,
                      completeness: completeness))
                  .toList(),
              deletions: batch.deletions
                  .map((identifiedGraph) => _localResourceLocator
                      .fromIri(identifiedGraph.$1, expectedTypeIri: typeIri)
                      .id)
                  .toList(),
              cursor: batch.cursor,
            ));
  }

  /// Convenience wrapper for callback-based hydration with automatic error handling.
  ///
  /// This is a simpler alternative to [hydrateStream] for common use cases.
  /// Automatically handles:
  /// - Cursor fetching and updates
  /// - Error logging (unless custom [onError] provided)
  /// - Stream subscription lifecycle
  /// - Batch processing with updates, deletions, and cursor management
  ///
  /// For advanced use cases (custom stream operations, backpressure control, etc.),
  /// use [hydrateStream] directly.
  ///
  /// Example:
  /// ```dart
  /// final subscription = await syncSystem.hydrateWithCallbacks<Note>(
  ///   getCurrentCursor: () => cursorDao.getCursor('note'),
  ///   onUpdate: (note) => noteDao.upsert(note),
  ///   onDelete: (noteId) => noteDao.delete(noteId),
  ///   onCursorUpdate: (cursor) => cursorDao.storeCursor('note', cursor),
  /// );
  /// ```
  ///
  /// Parameters:
  /// - [getCurrentCursor]: Async function to retrieve the current cursor position
  /// - [onUpdate]: Callback for processing updated items
  /// - [onDelete]: Callback for processing deleted items by Id
  /// - [onCursorUpdate]: Callback for persisting cursor updates
  /// - [onError]: Optional custom error handler. If not provided, errors are logged
  ///   but the stream continues running
  /// - [localName]: For distinguishing between different indices (default: 'default')
  /// - [initialBatchSize]: Number of items to load per batch (default: 100)
  Future<StreamSubscription<TypedHydrationBatch<T>>> hydrateWithCallbacks<T>({
    required Future<String?> Function() getCurrentCursor,
    required Future<void> Function(T item) onUpdate,
    required Future<void> Function(String itemId) onDelete,
    required Future<void> Function(String cursor) onCursorUpdate,
    void Function(Object error, StackTrace stackTrace)? onError,
    String localName = defaultIndexLocalName,
    int initialBatchSize = 100,
  }) async {
    final cursor = await getCurrentCursor();
    final logger = Logger('Locorda.hydration<$T>');

    return hydrateStream<T>(
      cursor: cursor,
      localName: localName,
      initialBatchSize: initialBatchSize,
    ).listen(
      (batch) async {
        try {
          // Process updates
          for (final item in batch.updates) {
            await onUpdate(item);
          }

          // Process deletions
          for (final item in batch.deletions) {
            await onDelete(item);
          }

          // Update cursor if present
          if (batch.cursor != null) {
            await onCursorUpdate(batch.cursor!);
          }
        } catch (error, stackTrace) {
          // TODO: Review error handling strategy - should we allow the stream to continue on errors?
          // How will a new change behave? Will it be based on the old cursor, e.g.
          // include the failed batch, or will it fetch a new batch based on the last successfully processed cursor
          // and then "skip" the failed batch? This has implications on consistency and error recovery strategies.
          if (onError != null) {
            onError(error, stackTrace);
          } else {
            // Default: log but don't crash the stream
            logger.severe(
                'Failed to process hydration batch', error, stackTrace);
          }
        }
      },
      onError: onError ??
          (error, stackTrace) {
            logger.severe('Hydration stream error', error, stackTrace);
          },
      cancelOnError: false, // Keep stream alive despite errors
    );
  }

  /// Convenience wrapper for batch-based hydration with automatic error handling.
  ///
  /// This variant processes entire batches of updates and deletions at once,
  /// which is more efficient for repositories that support batch operations
  /// (e.g., database bulk inserts, transactional updates).
  ///
  /// Advantages over [hydrateWithCallbacks]:
  /// - **Performance**: Single batch operation instead of N individual operations
  /// - **Transactional integrity**: Wrap entire batch in transaction (all-or-nothing)
  /// - **Simpler code**: Direct mapping to batch-optimized repository methods
  ///
  /// Use [hydrateWithCallbacks] if you need item-by-item processing (e.g., for
  /// validation, side effects per item, or repositories without batch support).
  ///
  /// Example with transactional batch processing:
  /// ```dart
  /// final subscription = await syncSystem.hydrateWithBatchCallbacks<Note>(
  ///   getCurrentCursor: () => cursorDao.getCursor('note'),
  ///   onUpdateBatch: (notes) async {
  ///     await db.transaction(() async {
  ///       await noteDao.upsertAll(notes);
  ///     });
  ///   },
  ///   onDeleteBatch: (noteIds) async {
  ///     await db.transaction(() async {
  ///       await noteDao.deleteAll(noteIds);
  ///     });
  ///   },
  ///   onCursorUpdate: (cursor) => cursorDao.storeCursor('note', cursor),
  /// );
  /// ```
  ///
  /// Parameters:
  /// - [getCurrentCursor]: Async function to retrieve the current cursor position
  /// - [onUpdateBatch]: Callback for processing batches of updated items
  /// - [onDeleteBatch]: Callback for processing batches of deleted item IDs
  /// - [onCursorUpdate]: Callback for persisting cursor updates
  /// - [onError]: Optional custom error handler. If not provided, errors are logged
  ///   but the stream continues running
  /// - [localName]: For distinguishing between different indices (default: 'default')
  /// - [initialBatchSize]: Number of items to load per batch (default: 100)
  Future<StreamSubscription<TypedHydrationBatch<T>>> hydrateWithBatchCallbacks<T>({
    required Future<String?> Function() getCurrentCursor,
    required Future<void> Function(List<T> items) onUpdateBatch,
    required Future<void> Function(List<String> itemIds) onDeleteBatch,
    required Future<void> Function(String cursor) onCursorUpdate,
    void Function(Object error, StackTrace stackTrace)? onError,
    String localName = defaultIndexLocalName,
    int initialBatchSize = 100,
  }) async {
    final cursor = await getCurrentCursor();
    final logger = Logger('Locorda.hydration<$T>');

    return hydrateStream<T>(
      cursor: cursor,
      localName: localName,
      initialBatchSize: initialBatchSize,
    ).listen(
      (batch) async {
        try {
          // Process updates as batch
          if (batch.updates.isNotEmpty) {
            await onUpdateBatch(batch.updates);
          }

          // Process deletions as batch
          if (batch.deletions.isNotEmpty) {
            await onDeleteBatch(batch.deletions);
          }

          // Update cursor if present
          if (batch.cursor != null) {
            await onCursorUpdate(batch.cursor!);
          }
        } catch (error, stackTrace) {
          if (onError != null) {
            onError(error, stackTrace);
          } else {
            // Default: log but don't crash the stream
            logger.severe(
                'Failed to process hydration batch', error, stackTrace);
          }
        }
      },
      onError: onError ??
          (error, stackTrace) {
            logger.severe('Hydration stream error', error, stackTrace);
          },
      cancelOnError: false, // Keep stream alive despite errors
    );
  }

  /// Close the sync system and free resources.
  Future<void> close() async {
    await _syncSystem.close();
  }
}
