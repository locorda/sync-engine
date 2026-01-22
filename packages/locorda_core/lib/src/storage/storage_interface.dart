/// Abstract storage interface for CRDT sync operations.
///
/// This interface defines the contract for local storage backends
/// that support CRDT synchronization with offline-first capabilities.
library;

import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_rdf_core/core.dart';

abstract interface class Storage {
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

  /// Get document with content and metadata by IRI.
  Future<StoredDocument?> getDocument(
    IriTerm documentIri, {
    int? ifChangedSincePhysicalClock = 0,
  });

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
    required ItemFetchPolicy itemFetchPolicy,
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
  Future<List<(IriTerm groupIndexIri, IriTerm indexedType, ItemFetchPolicy)>>
      getSubscribedGroupIndices(IriTerm indexedType);

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
  /// - [headerProperties]: Turtle-encoded indexed properties (nullable)
  /// - [isDeleted]: Whether this entry is marked as deleted (tombstone)
  ///
  /// Timestamps (updatedAt, ourPhysicalClock) are set automatically by storage.
  Future<void> saveIndexEntry({
    required IriTerm shardIri,
    required IriTerm indexIri,
    required IriTerm resourceIri,
    required IriTerm resourceType,
    required String clockHash,
    String? headerProperties,
    bool isDeleted = false,
    required int ourPhysicalClock,
    required int updatedAt,
  });

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

  /// Clear ETag for a document on a specific remote.
  ///
  /// Called when local changes invalidate the cached remote state, or when
  /// explicitly resetting sync state for a document.
  ///
  /// Parameters:
  /// - [remoteId]: The remote endpoint identifier
  /// - [documentIri]: The document IRI
  Future<void> clearRemoteETag(RemoteId remoteId, IriTerm documentIri);

  Future<int> getLastRemoteSyncTimestamp(RemoteId remoteId);
  Future<void> updateLastRemoteSyncTimestamp(RemoteId remoteId, int timestamp);
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

  /// Turtle-encoded header properties as RDF triples.
  /// Contains the indexed properties for this entry (e.g., schema:title, schema:datePublished).
  /// null if no header properties configured for this index.
  final String? headerProperties;

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
