/// Abstract storage interface for CRDT sync operations.
///
/// This interface defines the contract for local storage backends
/// that support CRDT synchronization with offline-first capabilities.
library;

import 'dart:typed_data';

import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_rdf_core/core.dart';

abstract interface class Storage {
  /// Execute [action] inside one storage transaction.
  ///
  /// Non-transactional backends should implement this as `=> action()`.
  /// Transactional backends (e.g. SQLite) should wrap [action] in a real DB
  /// transaction to guarantee atomicity and coalesce reactive notifications.
  Future<T> inTransaction<T>(Future<T> Function() action);

  /// Save a document with content, metadata, and property changes atomically.
  ///
  /// Storage handles RDF serialization and persists all data in a single transaction.
  /// Returns cursor information including the previous cursor for gap detection.
  ///
  /// Supports optimistic locking via [ifMatchUpdatedAt]:
  /// - If null: unconditional save (no conflict check)
  /// - If non-null: save only if current updatedAt matches expected value
  /// - Returns null on conflict (like HTTP 412 Precondition Failed)
  ///
  /// This prevents lost updates in concurrent scenarios (e.g., user edit during sync).
  /// Uses updatedAt (not ourPhysicalClock) because it's monotonically increasing
  /// across all saves (local and remote), making it a true "version number".
  ///
  /// Throws [ConcurrentUpdateException] on optimistic lock failure.
  Future<SaveDocumentResult> saveDocument(
      IriTerm documentIri,
      IriTerm typeIri,
      RdfGraph document,
      DocumentMetadata metadata,
      List<PropertyChange> changes,
      {int? ifMatchUpdatedAt});

  /// Save multiple documents.
  ///
  /// Default implementation delegates to [saveDocument] per request.
  /// Storage backends may override this with optimized set-based writes.
  ///
  /// When [preEncodedContents] is provided, implementations that perform
  /// binary encoding (e.g., protobuf) can skip the encode step and use
  /// the pre-encoded bytes directly. See [preEncodeDocuments].
  Future<List<SaveDocumentResult>> saveDocuments(
      Iterable<SaveDocumentRequest> requests,
      {List<Uint8List>? preEncodedContents}) async {
    final results = <SaveDocumentResult>[];
    for (final request in requests) {
      results.add(await saveDocument(
        request.documentIri,
        request.typeIri,
        request.document,
        request.metadata,
        request.changes,
        ifMatchUpdatedAt: request.ifMatchUpdatedAt,
      ));
    }
    return results;
  }

  /// Pre-encode document contents into binary form for pipeline optimization.
  ///
  /// Returns encoded bytes for each request, or `null` if this storage
  /// backend doesn't support pre-encoding (the default). When non-null,
  /// the result can be passed to [saveDocuments] via [preEncodedContents]
  /// to skip the in-method encoding step, enabling encode ∥ DB-write
  /// pipelining across commit chunks.
  List<Uint8List>? preEncodeDocuments(List<SaveDocumentRequest> requests) =>
      null;

  /// Persist the full shard membership for an index document.
  ///
  /// Replaces all previously stored shard IRIs for [indexIri] with
  /// [shardIris] (full-replace / OR-Set semantics: the caller always provides
  /// the complete post-merge shard set).  Called automatically by
  /// [DocumentSaveService] when an [IdxFullIndex] or [IdxGroupIndex] document
  /// is saved; storage backends that derive shard membership from the RDF
  /// graph at query time may leave this as a no-op.
  ///
  /// Each entry is a record of `(indexIri, shardIris)` so the entire batch can
  /// be persisted in a single round-trip / transaction.
  Future<void> saveIndexShards(List<(IriTerm, List<IriTerm>)> indexShards);

  /// Returns the known shard IRIs for each of the given index IRIs.
  ///
  /// Backends populate this table via [saveIndexShards]; callers rely on the
  /// result being accurate — an empty map is treated as "no shards" and will
  /// cause sync to skip indices silently.
  Future<Map<IriTerm, List<IriTerm>>> getIndexShards(
      Iterable<IriTerm> indexIris);

  /// Get document with content and metadata by IRI.
  Future<StoredDocument?> getDocument(
    IriTerm documentIri, {
    int? ifChangedSincePhysicalClock = 0,
  });

  /// Get multiple documents by IRI.
  ///
  /// Default implementation delegates to [getDocument] per IRI.
  /// Storage backends may override this with optimized batch queries.
  Future<Map<IriTerm, StoredDocument?>> getDocumentsByIri(
    Iterable<IriTerm> documentIris, {
    int? ifChangedSincePhysicalClock,
  }) async {
    final result = <IriTerm, StoredDocument?>{};
    for (final documentIri in documentIris) {
      result[documentIri] = await getDocument(
        documentIri,
        ifChangedSincePhysicalClock: ifChangedSincePhysicalClock,
      );
    }
    return result;
  }

  /// Warm up backend-internal IRI resolution caches for frequently accessed IRIs.
  ///
  /// Default implementation is a no-op. Backends may override this to pre-resolve
  /// IRI IDs in one batch and avoid repeated lookups under high contention.
  Future<void> warmupIriIds(Iterable<IriTerm> iris) async {}

  /// Get property changes for a document, optionally filtered by logical clock.
  ///
  /// [sinceLogicalClock] - Only return changes with changeLogicalClock > this value.
  /// Used during merge operations to get changes since a specific HLC state.
  Future<List<PropertyChange>> getPropertyChanges(IriTerm documentIri,
      {int? sinceLogicalClock});

  /// Get documents of a specific type modified since cursor (local OR remote changes).
  ///
  /// Returns a Future with a batch of documents for pagination during initial loading.
  /// Used for batch loading existing documents before switching to reactive watch.
  ///
  /// Parameters:
  /// - [typeIri]: The type of documents to query
  /// - [minCursor]: Only return documents with updatedAt > minCursor (null = from beginning)
  /// - [limit]: Maximum number of documents to return (for pagination)
  ///
  /// Returns documents with updatedAt > minCursor, ordered by updatedAt ascending.
  /// If result.nextCursor is not null, more data is available and should be fetched.
  Future<DocumentsResult> getDocumentsModifiedSince(
      IriTerm typeIri, String? minCursor,
      {required int limit});

  /// Get documents of a specific type changed by us since cursor (local changes only).
  ///
  /// Returns a Future with a batch of documents for pagination during initial sync.
  /// Used for batch loading local changes before switching to reactive watch.
  ///
  /// Parameters:
  /// - [typeIri]: The type of documents to query
  /// - [minCursor]: Only return documents with ourPhysicalClock > minCursor (null = from beginning)
  /// - [limit]: Maximum number of documents to return (for pagination)
  ///
  /// Returns documents we changed with ourPhysicalClock > minCursor,
  /// ordered by ourPhysicalClock ascending.
  Future<DocumentsResult> getDocumentsChangedByUsSince(
      IriTerm typeIri, String? minCursor,
      {required int limit});

  /// Check for missing documents referenced by index entries.
  ///
  /// Returns resource IRIs that have entries in the index_items table
  /// but no corresponding document in the documents table.
  ///
  /// Used for validation before switching to shard dataset backends:
  /// - Dataset shards require all resources to be present locally
  /// - Lazy loading is incompatible with dataset mode
  ///
  /// Parameters:
  /// - [resourceType]: Optional filter for specific resource type
  ///
  /// Returns list of missing resource IRIs (empty if storage is complete).
  Future<List<IriTerm>> getMissingDocumentsForIndexEntries(
      {IriTerm? resourceType});

  /// Watch documents of a specific type modified since cursor (local OR remote changes).
  ///
  /// Emits DocumentsResult whenever documents of the given type change in the database.
  /// Used for reactive hydration - automatically receiving updates when data changes.
  ///
  /// The stream emits:
  /// - Initial data immediately upon subscription
  /// - New DocumentsResult whenever relevant data changes in the database
  ///
  /// Parameters:
  /// - [typeIri]: The type of documents to watch
  /// - [minCursor]: Only emit documents with updatedAt > minCursor (null = from beginning)
  ///
  /// Returns a stream that emits all documents of the type with updatedAt > minCursor,
  /// ordered by updatedAt ascending. The stream automatically updates when documents change.
  Stream<DocumentsResult> watchDocumentsModifiedSince(
      IriTerm typeIri, String? minCursor);

  /// Watch documents of a specific type changed by us since cursor (local changes only).
  ///
  /// Emits DocumentsResult whenever documents that we changed are modified in the database.
  /// Used for reactive sync to remote - automatically detecting local changes to upload.
  ///
  /// The stream emits:
  /// - Initial data immediately upon subscription
  /// - New DocumentsResult whenever relevant local changes occur
  ///
  /// Parameters:
  /// - [typeIri]: The type of documents to watch
  /// - [minCursor]: Only emit documents with ourPhysicalClock > minCursor (null = from beginning)
  ///
  /// Returns a stream that emits all documents we changed with ourPhysicalClock > minCursor,
  /// ordered by ourPhysicalClock ascending.
  Stream<DocumentsResult> watchDocumentsChangedByUsSince(
      IriTerm typeIri, String? minCursor);

  /// Initialize the storage backend.
  Future<void> initialize();

  /// Close the storage backend and free resources.
  Future<void> close();

  /// Get multiple settings by keys in a single database request.
  ///
  /// Returns a map of key-value pairs. Missing keys are omitted from the result.
  /// Used during startup to efficiently load multiple settings together.
  Future<Map<String, String>> getSettings(Iterable<String> keys);

  /// Set a single setting value.
  ///
  /// Creates or updates the setting. Used to persist configuration values
  /// like installation IRI and flags.
  Future<void> setSetting(String key, String value);

  // ========================================================================
  // Index Management
  // ========================================================================

  /// Get index entries for hydration (cursor-based, excluding deleted).
  ///
  /// Returns a batch of entries for pagination during initial loading.
  /// Used for batch loading existing index entries before switching to reactive watch.
  ///
  /// Parameters:
  /// - [indexIris]: The index IRIs to query
  /// - [cursorTimestamp]: Only return entries with updatedAt > cursor (milliseconds since epoch, null = from beginning)
  /// - [limit]: Maximum number of entries to return (for pagination)
  ///
  /// Returns entries ordered by updatedAt ascending.
  /// Implementation may translate IRIs to IDs internally for efficiency.
  Future<IndexEntriesPage> getIndexEntries({
    required Iterable<IriTerm> indexIris,
    int? cursorTimestamp,
    int limit = 100,
  });

  /// Watch index entries for reactive hydration.
  ///
  /// Emits entries whenever they change in the database.
  /// Used for reactive hydration - automatically receiving updates when entries change.
  ///
  /// The stream emits:
  /// - Initial data immediately upon subscription
  /// - New entries whenever relevant data changes in the database
  ///
  /// Parameters:
  /// - [indexIris]: The index IRIs to watch
  /// - [cursorTimestamp]: Only emit entries with updatedAt > cursor (milliseconds since epoch, null = from beginning)
  ///
  /// Returns a stream that emits entries ordered by updatedAt ascending.
  /// The stream automatically updates when entries change.
  /// Implementation may translate IRIs to IDs internally for efficiency.
  Stream<List<IndexEntryWithIri>> watchIndexEntries({
    required Iterable<IriTerm> indexIris,
    int? cursorTimestamp,
  });

  /// Save or update a group index subscription.
  ///
  /// Creates or updates the subscription for the given index.
  /// Triggers reactive updates in watchIndexEntries() streams.
  Future<void> saveGroupIndexSubscription({
    required IriTerm groupIndexIri,
    required IriTerm groupIndexTemplateIri,
    required IriTerm indexedType,
    required RootResourceFetchPolicy rootResourceFetchPolicy,
    required int createdAt,
  });

  /// Watch subscribed group index IRIs for reactive updates.
  ///
  /// Emits the list of subscribed index IRIs whenever subscriptions change.
  Stream<Set<IriTerm>> watchSubscribedGroupIndexIris(IriTerm templateIri);

  /// Get subscribed group indices for a specific indexed type.
  ///
  /// Returns a list of tuples containing the group index IRI, indexed type IRI,
  /// and item fetch policy for all group indices that index the given type.
  /// Used during remote sync to determine which indices need synchronization.
  Future<
      List<
          (
            IriTerm groupIndexIri,
            IriTerm indexedType,
            RootResourceFetchPolicy
          )>> getSubscribedGroupIndices(IriTerm indexedType);

  /// Get or create an index set version for cursor tracking.
  ///
  /// Returns a version ID that can be embedded in cursor strings.
  /// Index IRIs are automatically sorted for consistent hashing.
  ///
  /// Used to track which indices were active at a given cursor position,
  /// enabling correct historical data loading when subscriptions change.
  Future<int> ensureIndexSetVersion({
    required Set<IriTerm> indexIris,
    required int createdAt,
  });

  /// Get the index IRIs for a given set version.
  ///
  /// Returns empty set if version not found.
  /// Used to parse cursor strings and determine which indices were active.
  Future<Set<IriTerm>> getIndexIrisForVersion(int versionId);

  /// Save or update an index entry.
  ///
  /// Overwrites existing entry with same (shardIri, resourceIri) if present.
  /// This is a cache of the actual resource data - caller is responsible for
  /// providing current data.
  ///
  /// Parameters:
  /// - [shardIri]: The shard this entry belongs to
  /// - [indexIri]: The index this entry belongs to (immutable)
  /// - [resourceIri]: The resource this entry points to
  /// - [clockHash]: CRDT clock hash from the resource
  /// - [headerProperties]: Indexed properties as RDF graph (nullable)
  /// - [isDeleted]: Whether this entry is marked as deleted (tombstone)
  ///
  /// Timestamps (updatedAt, ourPhysicalClock) are set automatically by storage.
  Future<void> saveIndexEntry({
    required IriTerm shardIri,
    required IriTerm indexIri,
    required IriTerm resourceIri,
    required IriTerm resourceType,
    required String clockHash,
    RdfGraph? headerProperties,
    bool isDeleted = false,
    required int ourPhysicalClock,
    required int updatedAt,
  });

  /// Save or update multiple index entries.
  ///
  /// Default implementation delegates to [saveIndexEntry] per request.
  /// Storage backends may override this with optimized batch writes.
  Future<void> saveIndexEntries(
      Iterable<SaveIndexEntryRequest> requests) async {
    for (final request in requests) {
      await saveIndexEntry(
        shardIri: request.shardIri,
        indexIri: request.indexIri,
        resourceIri: request.resourceIri,
        resourceType: request.resourceType,
        clockHash: request.clockHash,
        headerProperties: request.headerProperties,
        isDeleted: request.isDeleted,
        ourPhysicalClock: request.ourPhysicalClock,
        updatedAt: request.updatedAt,
      );
    }
  }

  /// Looks up the stored `indexIri` for each (shard, resource) pair.
  ///
  /// Used by Stage 9 to resolve `indexIri` for tombstoned shard entries,
  /// where the index IRI cannot be determined from pre-loaded pipeline data.
  ///
  /// Looks up the structural shard→index mapping (from the IndexShards table),
  /// NOT the per-resource IndexEntries table.
  ///
  /// Returns a map from shard IRI to the stored index IRI. Shards not found
  /// in the database are omitted from the result.
  Future<Map<IriTerm, IriTerm>> getIndexIrisForShards(
      Iterable<IriTerm> shardIris);

  /// Get all active (non-deleted) index entries for a shard.
  ///
  /// Used by SyncFunction to generate shard documents for sync.
  /// Only returns entries where isDeleted = false.
  ///
  /// Parameters:
  /// - [shardIri]: The shard IRI to query entries for
  ///
  /// Returns all non-deleted entries for the shard, unordered.
  Future<List<IndexEntryWithIri>> getActiveIndexEntriesForShard(
      IriTerm shardIri);

  /// Batch version of [getActiveIndexEntriesForShard] for multiple shards.
  ///
  /// Returns a map from each requested shard IRI to its active (non-deleted) entries.
  /// Shards with no active entries appear in the map with an empty list.
  ///
  /// Default implementation delegates to [getActiveIndexEntriesForShard] per shard.
  /// Storage backends should override with a single IN-query for efficiency —
  /// the default incurs one isolate roundtrip per shard.
  Future<Map<IriTerm, List<IndexEntryWithIri>>> getActiveIndexEntriesForShards(
      Iterable<IriTerm> shardIris) async {
    final result = <IriTerm, List<IndexEntryWithIri>>{};
    for (final shardIri in shardIris) {
      result[shardIri] = await getActiveIndexEntriesForShard(shardIri);
    }
    return result;
  }

  /// Get shard IRIs that have entries modified after the given timestamp.
  ///
  /// Used by SyncFunction to determine which shards need regeneration.
  /// Includes both new/updated entries and deleted entries (tombstones).
  ///
  /// Parameters:
  /// - [sinceTimestamp]: Physical clock timestamp (milliseconds since epoch)
  ///
  /// Returns: List of shard IRIs with modifications after the timestamp
  Future<
      List<
          ({
            IriTerm shardIri,
            IriTerm indexIri,
            IriTerm resourceTypeIri,
            int maxPhysicalClock
          })>> getShardsToUpdate(int sinceTimestamp);

  /// Get foreign index shards that need partial sync.
  ///
  /// Foreign indices are those NOT explicitly configured/subscribed.
  /// We need to sync their shards when they contain resources that:
  /// 1. Were modified locally (dirty entries need upload)
  /// 2. Are not yet covered by any configured index shard (uncovered resources)
  ///
  /// This avoids redundant syncing: resources already managed via configured
  /// indices don't need to be synced again through foreign indices.
  ///
  /// Parameters:
  /// - [sinceTimestamp]: Physical clock timestamp - entries modified after this are dirty
  /// - [excludeIndexIris]: Configured/subscribed index IRIs to exclude from foreign sync
  ///
  /// Returns: Map structure: indexIri -> shardIri -> resourceIri -> clockHash
  Future<Map<IriTerm, Map<IriTerm, Map<IriTerm, String>>>>
      getForeignIndexShardsToSync({
    required IriTerm resourceType,
    required int sinceTimestamp,
    required Set<IriTerm> excludeIndexIris,
  });

  // ========================================================================
  // Remote Sync State Management (Multi-Remote Support)
  // ========================================================================
  // All remote-specific methods take a RemoteId parameter to support
  // synchronization with multiple remotes simultaneously.
  //
  // Remote sync timestamps are stored in RemoteSettings table.
  // Shard sync timestamp is stored in Settings table (local operation).
  // ========================================================================

  /// Get stored ETag for a document on a specific remote.
  ///
  /// Used for conditional GET requests to avoid re-downloading unchanged documents.
  /// Returns null if no ETag is stored for this document/remote combination.
  ///
  /// Parameters:
  /// - [remoteId]: The remote endpoint identifier
  /// - [documentIri]: The document IRI to look up
  Future<String?> getRemoteETag(RemoteId remoteId, IriTerm documentIri);

  /// Get stored ETags for multiple documents on a specific remote.
  ///
  /// Default implementation delegates to [getRemoteETag] per document.
  /// Storage backends may override this with optimized batch queries.
  Future<Map<IriTerm, String?>> getRemoteETags(
      RemoteId remoteId, Iterable<IriTerm> documentIris) async {
    final result = <IriTerm, String?>{};
    for (final documentIri in documentIris) {
      result[documentIri] = await getRemoteETag(remoteId, documentIri);
    }
    return result;
  }

  /// Store ETag for a document on a specific remote.
  ///
  /// Called after successful download or upload to cache the current version.
  /// Updates both ETag and last sync timestamp for the document/remote pair.
  ///
  /// Parameters:
  /// - [remoteId]: The remote endpoint identifier
  /// - [documentIri]: The document IRI
  /// - [etag]: The ETag value from HTTP response headers
  Future<void> setRemoteETag(
      RemoteId remoteId, IriTerm documentIri, String etag);

  /// Store ETags for multiple documents on a specific remote.
  ///
  /// Default implementation delegates to [setRemoteETag] per document.
  /// Storage backends may override this with optimized batch writes.
  Future<void> setRemoteETags(
      RemoteId remoteId, Map<IriTerm, String> etagsByDocument) async {
    for (final entry in etagsByDocument.entries) {
      await setRemoteETag(remoteId, entry.key, entry.value);
    }
  }

  /// Clear ETag for a document on a specific remote.
  ///
  /// Called when local changes invalidate the cached remote state, or when
  /// explicitly resetting sync state for a document.
  ///
  /// Parameters:
  /// - [remoteId]: The remote endpoint identifier
  /// - [documentIri]: The document IRI
  Future<void> clearRemoteETag(RemoteId remoteId, IriTerm documentIri);

  /// Upserts the sync lifecycle state for a specific index instance and remote.
  ///
  /// Implementations should treat this as the canonical state record for
  /// per-index-instance sync tracking and preserve [lastSuccessfulSyncAt]
  /// across subsequent error transitions.
  Future<void> upsertIndexInstanceSyncState({
    required IriTerm indexInstanceIri,
    required RemoteId remoteId,
    required RemoteSyncPhase phase,
    DateTime? lastSuccessfulSyncAt,
    DateTime? lastAttemptStartedAt,
    DateTime? lastAttemptFinishedAt,
    String? lastErrorMessage,
  });

  /// Returns the current sync snapshot for a specific index instance.
  ///
  /// If no state has been persisted yet, this returns an empty snapshot for
  /// the provided [indexInstanceIri].
  Future<IndexInstanceSyncState> getIndexInstanceSyncState(
      IriTerm indexInstanceIri);

  /// Watches sync state updates for a specific index instance.
  ///
  /// **Contract**: Implementations must provide replay semantics — the current
  /// snapshot is emitted synchronously as the first event upon subscription,
  /// before any `await` point in the subscriber. This guarantees that callers
  /// using `.first` or `.firstWhere` will never miss a state that was already
  /// current at the time of subscription, regardless of async scheduling.
  ///
  /// Subsequent emissions occur on every state transition. The stream is
  /// infinite; it completes only when the underlying storage is closed.
  Stream<IndexInstanceSyncState> watchIndexInstanceSyncState(
      IriTerm indexInstanceIri);

  /// Returns all configured remotes known to storage.
  Future<List<RemoteId>> getConfiguredRemoteIds();

  /// Watches the set of configured remotes.
  ///
  /// **Contract**: Same replay semantics as [watchIndexInstanceSyncState] —
  /// the current set is emitted synchronously as the first event upon
  /// subscription. Subsequent emissions occur whenever a remote is added or
  /// removed.
  Stream<Set<RemoteId>> watchConfiguredRemoteIds();

  Future<int> getLastRemoteSyncTimestamp(RemoteId remoteId);
  Future<void> updateLastRemoteSyncTimestamp(RemoteId remoteId, int timestamp);
}

/// Sync phase for a single remote × index instance combination.
enum RemoteSyncPhase {
  notSynced,
  syncPlanned,
  syncing,
  ready,
  error,
}

/// Per-remote sync snapshot for one index instance.
class RemoteSyncEntry {
  final RemoteId remoteId;
  final RemoteSyncPhase phase;
  final DateTime? lastSuccessfulSyncAt;
  final DateTime? lastAttemptStartedAt;
  final DateTime? lastAttemptFinishedAt;
  final String? lastErrorMessage;

  const RemoteSyncEntry({
    required this.remoteId,
    required this.phase,
    this.lastSuccessfulSyncAt,
    this.lastAttemptStartedAt,
    this.lastAttemptFinishedAt,
    this.lastErrorMessage,
  });

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }

    return other is RemoteSyncEntry &&
        other.remoteId == remoteId &&
        other.phase == phase &&
        other.lastSuccessfulSyncAt == lastSuccessfulSyncAt &&
        other.lastAttemptStartedAt == lastAttemptStartedAt &&
        other.lastAttemptFinishedAt == lastAttemptFinishedAt &&
        other.lastErrorMessage == lastErrorMessage;
  }

  @override
  int get hashCode => Object.hash(
        remoteId,
        phase,
        lastSuccessfulSyncAt,
        lastAttemptStartedAt,
        lastAttemptFinishedAt,
        lastErrorMessage,
      );
}

/// Aggregate snapshot for one index instance across remotes.
class IndexInstanceSyncState {
  final IriTerm indexInstanceIri;
  final Map<RemoteId, RemoteSyncEntry> perRemote;

  IndexInstanceSyncState({
    required this.indexInstanceIri,
    required Map<RemoteId, RemoteSyncEntry> perRemote,
  }) : perRemote = Map.unmodifiable(perRemote);

  factory IndexInstanceSyncState.empty(IriTerm indexInstanceIri) {
    return IndexInstanceSyncState(
      indexInstanceIri: indexInstanceIri,
      perRemote: const {},
    );
  }

  /// Any remote is actively transferring or queued.
  bool get isSyncing => perRemote.values.any(
        (entry) =>
            entry.phase == RemoteSyncPhase.syncing ||
            entry.phase == RemoteSyncPhase.syncPlanned,
      );

  /// All remotes are in the `ready` phase — no errors and no pending work.
  bool get isReady =>
      perRemote.isNotEmpty &&
      perRemote.values.every((entry) => entry.phase == RemoteSyncPhase.ready);

  /// True if every configured remote has synced at least once.
  ///
  /// Vacuously true when no backend is configured.
  bool get hasCompletedInitialSync =>
      perRemote.values.every((entry) => entry.lastSuccessfulSyncAt != null);

  /// True if any remote is currently in error state.
  bool get hasError =>
      perRemote.values.any((entry) => entry.phase == RemoteSyncPhase.error);

  /// True if any remote has an error after a previous successful sync.
  bool get hasStaleError => perRemote.values.any(
        (entry) =>
            entry.phase == RemoteSyncPhase.error &&
            entry.lastSuccessfulSyncAt != null,
      );

  /// True if any remote errored before initial sync completion.
  bool get hasInitialSyncError => perRemote.values.any(
        (entry) =>
            entry.phase == RemoteSyncPhase.error &&
            entry.lastSuccessfulSyncAt == null,
      );

  /// True if at least one configured remote has never synced successfully.
  bool get hasUnsyncedRemote =>
      perRemote.values.any((entry) => entry.lastSuccessfulSyncAt == null);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! IndexInstanceSyncState) {
      return false;
    }
    if (indexInstanceIri != other.indexInstanceIri ||
        perRemote.length != other.perRemote.length) {
      return false;
    }

    for (final entry in perRemote.entries) {
      if (other.perRemote[entry.key] != entry.value) {
        return false;
      }
    }

    return true;
  }

  @override
  int get hashCode {
    final sortedEntries = perRemote.entries.toList()
      ..sort((left, right) {
        final backendCompare = left.key.backend.compareTo(right.key.backend);
        if (backendCompare != 0) {
          return backendCompare;
        }
        return left.key.id.compareTo(right.key.id);
      });

    return Object.hash(
      indexInstanceIri,
      Object.hashAll(
        sortedEntries.map((entry) => Object.hash(entry.key, entry.value)),
      ),
    );
  }
}

/// Index entry with resolved resource IRI.
///
/// Represents a lightweight index entry containing only indexed properties,
/// not the full resource document.
class IndexEntryWithIri {
  /// The resource IRI this entry points to
  final IriTerm resourceIri;

  /// Clock hash from the resource's CRDT metadata
  final String clockHash;

  /// Indexed properties as RDF graph.
  /// Contains the indexed properties for this entry (e.g., schema:title, schema:datePublished).
  /// null if no header properties configured for this index.
  final RdfGraph? headerProperties;

  /// Timestamp when this entry was last updated (milliseconds since epoch, for cursor-based pagination)
  final int updatedAt;
  final int ourPhysicalClock;

  /// Tombstone marker - true if entry was removed from index
  final bool isDeleted;

  IndexEntryWithIri({
    required this.resourceIri,
    required this.clockHash,
    this.headerProperties,
    required this.updatedAt,
    required this.ourPhysicalClock,
    required this.isDeleted,
  });
}

/// Page of index entries with pagination info.
class IndexEntriesPage {
  final List<IndexEntryWithIri> entries;
  final bool hasMore;
  final int? lastCursor;

  IndexEntriesPage({
    required this.entries,
    required this.hasMore,
    required this.lastCursor,
  });
}

/// Document with content and metadata retrieved from storage.
class StoredDocument {
  final IriTerm documentIri;
  final RdfGraph document;
  final DocumentMetadata metadata;

  StoredDocument(
      {required this.documentIri,
      required this.document,
      required this.metadata});
}

/// Result of saving a document, including cursor information for gap detection.
class SaveDocumentResult {
  final String?
      previousCursor; // The highest cursor for this type before this save (null if first)
  final String currentCursor; // The cursor for this save operation

  SaveDocumentResult({
    required this.previousCursor,
    required this.currentCursor,
  });
}

/// Request descriptor for document batch writes.
class SaveDocumentRequest {
  final IriTerm documentIri;
  final IriTerm typeIri;
  final RdfGraph document;
  final DocumentMetadata metadata;
  final List<PropertyChange> changes;
  final int? ifMatchUpdatedAt;

  const SaveDocumentRequest({
    required this.documentIri,
    required this.typeIri,
    required this.document,
    required this.metadata,
    required this.changes,
    this.ifMatchUpdatedAt,
  });
}

/// Request descriptor for index entry batch writes.
class SaveIndexEntryRequest {
  final IriTerm shardIri;
  final IriTerm indexIri;
  final IriTerm resourceIri;
  final IriTerm resourceType;
  final String clockHash;
  final RdfGraph? headerProperties;
  final bool isDeleted;
  final int ourPhysicalClock;
  final int updatedAt;

  const SaveIndexEntryRequest({
    required this.shardIri,
    required this.indexIri,
    required this.resourceIri,
    required this.resourceType,
    required this.clockHash,
    this.headerProperties,
    this.isDeleted = false,
    required this.ourPhysicalClock,
    required this.updatedAt,
  });

  /// Returns a copy with [updatedAt] replaced.
  ///
  /// Used by Stage 9 to stamp entries built in Stage 7c with the actual
  /// DB commit timestamp.
  SaveIndexEntryRequest withUpdatedAt(int updatedAt) => SaveIndexEntryRequest(
        shardIri: shardIri,
        indexIri: indexIri,
        resourceIri: resourceIri,
        resourceType: resourceType,
        clockHash: clockHash,
        headerProperties: headerProperties,
        isDeleted: isDeleted,
        ourPhysicalClock: ourPhysicalClock,
        updatedAt: updatedAt,
      );
}

/// Result of querying documents with pagination support.
class DocumentsResult {
  final List<StoredDocument> documents;

  /// The cursor representing the current position in the document stream.
  /// This represents how far we've processed and should be used to resume
  /// hydration after app restart.
  ///
  /// - If documents were returned: cursor of the last document
  /// - If no documents were returned: the minCursor that was passed in (never goes backwards)
  /// - Never null after initialization (represents "beginning" as empty string if needed)
  final String? currentCursor;

  /// Whether there are more documents available for pagination.
  /// True means another batch should be fetched with the currentCursor.
  /// False means all documents have been loaded.
  final bool hasNext;

  DocumentsResult({
    required this.documents,
    required this.currentCursor,
    required this.hasNext,
  });
}

/// Document metadata managed by sync layer and storage.
class DocumentMetadata {
  final int
      ourPhysicalClock; // When we last changed this document (from sync layer)
  final int
      updatedAt; // When document was last updated - local or remote (set by storage)

  DocumentMetadata({required this.ourPhysicalClock, required this.updatedAt});
}

/// Property-level change information for fine-grained conflict resolution.
class PropertyChange {
  final IriTerm
      resourceIri; // Resource within the document (e.g., doc#it, doc#nutrition)
  final RdfPredicate propertyIri; // Property that changed (e.g., schema:name)
  final int changedAtMs; // Real timestamp when change was made
  final int changeLogicalClock; // Logical clock assigned to this change
  final bool
      isFrameworkProperty; // Whether this is a framework metadata property (sync:logicalTime, sync:resourceHash, etc.) or app data property

  PropertyChange({
    required this.resourceIri,
    required this.propertyIri,
    required this.changedAtMs,
    required this.changeLogicalClock,
    this.isFrameworkProperty = false,
  });
}
