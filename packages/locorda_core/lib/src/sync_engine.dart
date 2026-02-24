/// Main facade for the CRDT sync system.
library;

import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:locorda_core/locorda_core.dart';

import 'package:locorda_rdf_core/core.dart'
    show RdfCore, IriTerm, RdfGraph, IriTermFactory;

typedef IdentifiedGraph = (IriTerm id, RdfGraph graph);
typedef HydrationBatch = ({
  List<IdentifiedGraph> updates,
  List<IdentifiedGraph> deletions,
  String? cursor
});

class EngineParams {
  final Storage storage;
  final List<Backend> backends;
  final PhysicalTimestampFactory? physicalTimestampFactory;
  final InstallationIdFactory? installationIdFactory;
  final IriTermFactory? iriFactory;
  final RdfCore? rdfCore;
  final http.Client? httpClient;
  final Fetcher? fetcher;
  final Iterable<String>? mappingBootstrapSources;

  EngineParams({
    required this.storage,
    required this.backends,
    this.physicalTimestampFactory,
    this.installationIdFactory,
    this.iriFactory,
    this.rdfCore,
    this.httpClient,
    this.fetcher,
    this.mappingBootstrapSources,
  });

  EngineParams copyWith({
    Storage? storage,
    List<Backend>? backends,
    PhysicalTimestampFactory? physicalTimestampFactory,
    InstallationIdFactory? installationIdFactory,
    IriTermFactory? iriFactory,
    RdfCore? rdfCore,
    http.Client? httpClient,
    Fetcher? fetcher,
    Iterable<String>? mappingBootstrapSources,
  }) {
    return EngineParams(
      storage: storage ?? this.storage,
      backends: backends ?? this.backends,
      physicalTimestampFactory:
          physicalTimestampFactory ?? this.physicalTimestampFactory,
      installationIdFactory:
          installationIdFactory ?? this.installationIdFactory,
      iriFactory: iriFactory ?? this.iriFactory,
      rdfCore: rdfCore ?? this.rdfCore,
      httpClient: httpClient ?? this.httpClient,
      fetcher: fetcher ?? this.fetcher,
      mappingBootstrapSources:
          mappingBootstrapSources ?? this.mappingBootstrapSources,
    );
  }
}

/// Main facade for the locorda system.
///
/// Provides a simple, high-level API for offline-first applications with
/// optional Solid Pod synchronization. Handles RDF mapping, storage,
/// and sync operations transparently.
abstract interface class SyncEngine {
  SyncManager get syncManager;

  /// Reactively observes sync state for one subscribed group index instance.
  Stream<IndexInstanceSyncState> watchGroupIndexSyncState({
    required String indexName,
    required RdfGraph groupKeyGraph,
  });

  /// Reactively observes sync state for the full-index instance of [typeIri].
  Stream<IndexInstanceSyncState> watchSyncState({
    required IriTerm typeIri,
    String? indexName,
  });

  /// Ensures a group index subscription exists and optionally triggers sync.
  ///
  /// When [rootResourceFetchPolicy] is `null`, the policy configured on the
  /// [GroupIndexData] for [indexName] is used.
  Future<void> ensureGroupIndexSubscription({
    required String indexName,
    required RdfGraph groupKeyGraph,
    RootResourceFetchPolicy? rootResourceFetchPolicy,
    bool triggerSync = true,
  });

  /// Ensures a group index instance completed initial sync.
  ///
  /// When [rootResourceFetchPolicy] is `null`, the policy configured on the
  /// [GroupIndexData] for [indexName] is used.
  ///
  /// Throws [IndexInstanceSyncFailedException] when initial sync fails.
  Future<void> ensureGroupIndexSynced({
    required String indexName,
    required RdfGraph groupKeyGraph,
    RootResourceFetchPolicy? rootResourceFetchPolicy,
  });

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
    required SyncEngineConfig config,
    required EngineParams engineParams,
  }) async {
    return StandardSyncEngine.create(
      backends: engineParams.backends,
      storage: engineParams.storage,
      config: config,
      physicalTimestampFactory: engineParams.physicalTimestampFactory,
      installationIdFactory: engineParams.installationIdFactory,
      iriFactory: engineParams.iriFactory,
      rdfCore: engineParams.rdfCore,
      httpClient: engineParams.httpClient,
      fetcher: engineParams.fetcher,
      mappingBootstrapSources: engineParams.mappingBootstrapSources,
    );
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
  Future<void> save(IriTerm type, RdfGraph appData);

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
      bool skipInitialFetch = false});

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
  Future<void> deleteDocument(IriTerm typeIri, IriTerm externalIri);

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
  });

  /// Close the sync system and free resources.
  Future<void> close();
}

/// Thrown when initial sync fails for at least one remote.
class IndexInstanceSyncFailedException implements Exception {
  final String message;
  final IndexInstanceSyncState lastState;

  const IndexInstanceSyncFailedException(this.message,
      {required this.lastState});

  @override
  String toString() => 'IndexInstanceSyncFailedException: $message';
}
