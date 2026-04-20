/// Drift database schema for Locorda sync storage.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:locorda_rdf_jelly/jelly.dart';

part 'sync_database.g.dart';

/// IRI lookup table for normalized storage
class SyncIris extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get iri => text().unique()();
}

/// Document storage table
class SyncDocuments extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get documentIriId => integer().references(SyncIris, #id).unique()();

  @ReferenceName('typeIri')
  IntColumn get typeIriId => integer().references(SyncIris, #id)();

  BlobColumn get documentContent => blob()();
  IntColumn get ourPhysicalClock => integer()();
  IntColumn get updatedAt => integer()();
}

/// Property-level change tracking table
class SyncPropertyChanges extends Table {
  IntColumn get documentId => integer().references(SyncDocuments, #id)();

  @ReferenceName('resourceIri')
  IntColumn get resourceIriId => integer().references(SyncIris, #id)();

  @ReferenceName('propertyIri')
  IntColumn get propertyIriId => integer().references(SyncIris, #id)();

  IntColumn get changedAtMs => integer()();
  IntColumn get changeLogicalClock => integer()();
  BoolColumn get isFrameworkProperty =>
      boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey =>
      {documentId, resourceIriId, propertyIriId, changeLogicalClock};
}

/// Settings storage table for framework configuration
class SyncSettings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

/// Individual index entries within shards
/// These are lightweight representations of resources with only indexed properties
class IndexEntries extends Table {
  @ReferenceName('shardIri')
  IntColumn get shardIri => integer().references(SyncIris, #id)();

  /// Direct reference to the index this entry belongs to.
  /// This is immutable - an entry never changes which index it belongs to.
  @ReferenceName('indexIri')
  IntColumn get indexIriId => integer().references(SyncIris, #id)();

  /// The resource IRI this entry points to (e.g., /notes/note-123#note)
  @ReferenceName('indexResourceIri')
  IntColumn get resourceIriId => integer().references(SyncIris, #id)();

  /// The type IRI of the resource (e.g., schema:Note)
  @ReferenceName('resourceTypeIri')
  IntColumn get resourceTypeIriId => integer().references(SyncIris, #id)();

  /// Clock hash from the resource's CRDT metadata
  TextColumn get clockHash => text()();

  /// application specific RDF payload in jelly binary format
  BlobColumn get headerProperties => blob().nullable()();

  /// When this entry was last updated (milliseconds since epoch)
  IntColumn get updatedAt => integer()();

  /// Physical clock for cursor-based pagination
  IntColumn get ourPhysicalClock => integer()();

  /// Tombstone marker - true if entry was removed from index
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();

  /// Placeholder flag — true when this entry was observed in the remote shard
  /// but not yet fetched locally (onRequest / unmatched PrefetchFiltered).
  /// Prevents shard regeneration from tombstoning entries we haven't downloaded.
  BoolColumn get isRemoteOnly => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {shardIri, resourceIriId};
}

/// Group index subscriptions
/// Tracks which group indices the user has explicitly subscribed to
class GroupIndexSubscriptions extends Table {
  IntColumn get groupIndexIriId => integer().references(SyncIris, #id)();

  @ReferenceName('groupIndexTemplateIriId')
  IntColumn get groupIndexTemplateIriId =>
      integer().references(SyncIris, #id)();

  /// The type IRI that this group index is indexing
  @ReferenceName('indexedTypeIriId')
  IntColumn get indexedTypeIriId => integer().references(SyncIris, #id)();

  /// Fetch policy: 'onRequest' or 'prefetch'
  /// TODO: could be renamed to rootResourceFetchPolicy to be more explicit, but
  /// this column is older that that name and we did not want to change it yet
  TextColumn get itemFetchPolicy => text()();

  /// Timestamp when this subscription was created (milliseconds since epoch)
  IntColumn get createdAt => integer()();

  @override
  Set<Column> get primaryKey => {groupIndexIriId};
}

/// Per-index-instance sync state by remote.
///
/// Stores the latest synchronization phase and timestamps for a specific
/// index instance (`index_instance_iri_id`) and remote (`remote_setting_id`).
class IndexInstanceSyncStates extends Table {
  @ReferenceName('indexInstanceIri')
  IntColumn get indexInstanceIriId => integer().references(SyncIris, #id)();

  @ReferenceName('remoteSetting')
  IntColumn get remoteSettingId => integer().references(RemoteSettings, #id)();

  /// Phase name from [RemoteSyncPhase].
  TextColumn get phase => text()();

  /// Last successful sync completion timestamp (UTC milliseconds since epoch).
  IntColumn get lastSuccessfulSyncAtMs => integer().nullable()();

  /// Last sync attempt start timestamp (UTC milliseconds since epoch).
  IntColumn get lastAttemptStartedAtMs => integer().nullable()();

  /// Last sync attempt finish timestamp (UTC milliseconds since epoch).
  IntColumn get lastAttemptFinishedAtMs => integer().nullable()();

  /// Last sync error message for this index-instance/remote pair.
  TextColumn get lastErrorMessage => text().nullable()();

  @override
  Set<Column> get primaryKey => {indexInstanceIriId, remoteSettingId};
}

/// Sync metadata for tracking last sync timestamps
///
/// Singleton table (only one row) that tracks when we last synchronized
/// shard documents. Used to determine which shards need updating.
/// Remote synchronization state per document and remote.
///
/// Tracks sync metadata (ETags, timestamps) for each document on each remote.
/// Remote configuration and metadata storage.
///
/// Normalizes remote URLs (e.g., Solid Pod URLs) with integer IDs for efficient
/// storage and queries. Tracks per-remote sync state like last sync timestamp.
class RemoteSettings extends Table {
  /// Auto-incrementing primary key
  IntColumn get id => integer().autoIncrement()();

  /// Remote ID (e.g., 'https://alice.pod.example/')
  /// Combined with remoteType must be unique per backend.
  TextColumn get remoteId => text()();

  /// Type of remote (e.g., 'solid-pod', 'generic-http')
  /// Allows future extensibility for different remote types
  TextColumn get remoteType => text()();

  /// Timestamp of last successful sync with this remote (milliseconds since epoch)
  /// Used for tracking overall remote sync progress
  IntColumn get lastSyncTimestamp => integer().withDefault(const Constant(0))();

  /// When this remote was first configured (milliseconds since epoch)
  IntColumn get createdAt => integer()();

  @override
  List<Set<Column>> get uniqueKeys => [
        {remoteType, remoteId}
      ];
}

/// Per-document remote sync state tracking.
///
/// Tracks ETag and sync status for each document with each remote.
/// This enables:
/// - Multiple remotes/pods per backend (multi-remote support)
/// - Conditional GET/PUT operations via ETags
/// - Per-document sync timestamps
/// - Type-safe IRI references via foreign keys
class RemoteSyncState extends Table {
  /// Foreign key to SyncIris table for the document IRI
  IntColumn get documentIriId => integer().references(SyncIris, #id)();

  /// Foreign key to RemoteSettings for efficient storage
  /// Normalized reference instead of repeating URLs
  IntColumn get remoteId => integer().references(RemoteSettings, #id)();

  /// ETag from last GET/PUT for conditional requests
  /// NULL if never synced or ETag not supported by remote
  TextColumn get etag => text().nullable()();

  /// Timestamp of last successful sync (milliseconds since epoch)
  /// Used for tracking when document was last synced with this remote
  IntColumn get lastSyncedAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {documentIriId, remoteId};

  @override
  List<Set<Column>> get uniqueKeys => [];
}

/// Index Iri set versions for cursor tracking
///
/// Tracks unique combinations of (usually subscribed) group index IDs for a template.
/// Used to enable correct cursor semantics when the set of index IDs change:
/// - New subscriptions must load historical data (cursor=0 → current)
/// - Old subscriptions continue from their last cursor position
///
/// Each unique set of index IRI IDs gets a version ID that can be
/// embedded in the cursor string (e.g., "100@42" = timestamp 100, set version 42).
class IndexIriIdSetVersions extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// Comma-separated, sorted list of index IRI IDs (e.g., "5,7,9")
  /// Always sorted ascending to ensure consistent hashing
  TextColumn get indexIriIds => text()();

  /// When this version was created (milliseconds since epoch)
  IntColumn get createdAt => integer()();

  @override
  List<Set<Column>> get uniqueKeys => [
        {indexIriIds}
      ];
}

/// Extension for reactive stream queries with progressive cursor tracking.
///
/// Provides `watchWithCursor` for watch queries that only emit
/// entries/documents that have changed since the last emission.
extension WatchWithCursorExtension<T extends HasResultSet, D>
    on SimpleSelectStatement<T, D> {
  /// Watch query results with progressive cursor tracking.
  ///
  /// Only emits results that are newer than the last emission, preventing
  /// re-emission of already processed data. Combines with asyncMap for
  /// domain-specific post-processing.
  ///
  /// Parameters:
  /// - [getCursor]: Function to extract timestamp from a result
  /// - [initialCursor]: Starting cursor position (0 = from beginning)
  Stream<List<D>> watchWithCursor({
    required int Function(D result) getCursor,
    required int initialCursor,
  }) {
    final controller = StreamController<List<D>>();
    var currentCursor = initialCursor;

    final subscription = watch().listen((allEntries) async {
      // Progressive in-memory filter: only emit entries newer than last emission
      // This is the key optimization: prevents re-emitting already processed entries
      final newEntries =
          allEntries.where((e) => getCursor(e) > currentCursor).toList();

      if (newEntries.isEmpty) {
        // No new entries - skip this emission
        return;
      }

      // Update cursor to the latest timestamp we're emitting
      // This ensures next emission only includes entries changed after this point
      currentCursor =
          newEntries.map((e) => getCursor(e)).reduce((a, b) => a > b ? a : b);

      controller.add(newEntries);
    });

    // Cleanup: cancel drift watch subscription when stream is cancelled
    controller.onCancel = () => subscription.cancel();

    return controller.stream;
  }
}

/// Mixin for efficient IRI batch loading and creation
///
/// TODO: can we optimize this further by caching recently used IRIs in memory?
mixin IriBatchLoader on DatabaseAccessor<SyncDatabase> {
  /// Efficiently load multiple IRIs by their IDs with automatic batching
  Future<Map<int, String>> getIrisBatch(Set<int> iriIds) async {
    if (iriIds.isEmpty) return {};

    const batchSize = 999; // SQLite's default SQLITE_MAX_VARIABLE_NUMBER - 1
    final result = <int, String>{};

    // Process in batches
    final iriIdsList = iriIds.toList();
    for (int i = 0; i < iriIdsList.length; i += batchSize) {
      final batch =
          iriIdsList.sublist(i, math.min(i + batchSize, iriIdsList.length));

      final iris =
          await (select(db.syncIris)..where((iri) => iri.id.isIn(batch))).get();
      result.addAll({for (final iri in iris) iri.id: iri.iri});
    }

    return result;
  }

  /// Efficiently get/create multiple IRI IDs in batch
  Future<Map<String, int>> getOrCreateIriIdsBatch(Iterable<String> iris) async {
    final result = await getOrCreateIriIdsBatchWithStats(iris);
    return result.ids;
  }

  /// Efficiently get/create multiple IRI IDs in batch with diagnostics.
  ///
  /// Returns IRI -> ID map plus counters useful for performance tracing.
  Future<
      ({
        Map<String, int> ids,
        int existingCount,
        int createdCount,
      })> getOrCreateIriIdsBatchWithStats(Iterable<String> iris) async {
    if (iris.isEmpty) {
      return (ids: const <String, int>{}, existingCount: 0, createdCount: 0);
    }

    // 1. First try to get all existing IRIs
    final existing = await _getExistingIriIds(iris);
    final result = Map<String, int>.from(existing);

    // 2. Find IRIs that don't exist yet
    final missing = iris.where((iri) => !existing.containsKey(iri)).toSet();

    // 3. Batch create missing IRIs
    if (missing.isNotEmpty) {
      final created = await _createMissingIris(missing);
      result.addAll(created);
    }

    return (
      ids: result,
      existingCount: existing.length,
      createdCount: missing.length,
    );
  }

  /// Get existing IRI → ID mappings for the given IRIs
  Future<Map<String, int>> _getExistingIriIds(Iterable<String> iris) async {
    if (iris.isEmpty) return {};

    const batchSize = 999;
    final result = <String, int>{};

    // Process in batches
    final irisList = iris.toList();
    for (int i = 0; i < irisList.length; i += batchSize) {
      final batch =
          irisList.sublist(i, math.min(i + batchSize, irisList.length));

      final existingIris = await (select(db.syncIris)
            ..where((iri) => iri.iri.isIn(batch)))
          .get();
      result.addAll({for (final iri in existingIris) iri.iri: iri.id});
    }

    return result;
  }

  /// Get existing IRI ID for a single IRI, or null if not found
  Future<int?> _getExistingIriId(String iri) async {
    final result = await _getExistingIriIds({iri});
    return result[iri];
  }

  Future<int> getOrCreateIriId(String iri) async {
    final result = await getOrCreateIriIdsBatch({iri});
    return result[iri]!;
  }

  /// Create missing IRIs and return their IDs
  Future<Map<String, int>> _createMissingIris(Set<String> iris) async {
    if (iris.isEmpty) return {};

    final result = <String, int>{};

    // Create IRIs one by one to get their auto-generated IDs
    // Note: Drift doesn't support batch insert with returning IDs easily
    for (final iri in iris) {
      final id =
          await into(db.syncIris).insert(SyncIrisCompanion(iri: Value(iri)));
      result[iri] = id;
    }

    return result;
  }
}

/// Data Access Object for document storage
@DriftAccessor(tables: [SyncDocuments, SyncIris])
class SyncDocumentDao extends DatabaseAccessor<SyncDatabase>
    with _$SyncDocumentDaoMixin, IriBatchLoader {
  SyncDocumentDao(super.db);

  Future<Map<int, SyncDocument>> getDocumentsByDocumentIriIds(
      Iterable<int> documentIriIds) async {
    final ids = documentIriIds.toSet();
    if (ids.isEmpty) {
      return const {};
    }

    final rows = await (select(syncDocuments)
          ..where((d) => d.documentIriId.isIn(ids)))
        .get();
    return {
      for (final row in rows) row.documentIriId: row,
    };
  }

  Future<Map<int, int?>> getMaxUpdatedAtForTypeIds(
      Iterable<int> typeIriIds) async {
    final ids = typeIriIds.toSet();
    if (ids.isEmpty) {
      return const {};
    }

    final rows = await customSelect(
      '''
      SELECT type_iri_id, MAX(updated_at) AS max_updated_at
      FROM sync_documents
      WHERE type_iri_id IN (${ids.join(',')})
      GROUP BY type_iri_id
      ''',
      readsFrom: {syncDocuments},
    ).get();

    final result = <int, int?>{for (final id in ids) id: null};
    for (final row in rows) {
      result[row.read<int>('type_iri_id')] = row.read<int?>('max_updated_at');
    }
    return result;
  }

  /// Lightweight existence check — returns only id + updatedAt, no content.
  /// Avoids transferring document content over Drift isolate boundary.
  Future<Map<int, ({int id, int updatedAt})>>
      getDocumentExistenceByDocumentIriIds(Iterable<int> documentIriIds) async {
    final ids = documentIriIds.toSet();
    if (ids.isEmpty) return const {};

    const batchSize = 999;
    final result = <int, ({int id, int updatedAt})>{};
    final idsList = ids.toList();

    for (int i = 0; i < idsList.length; i += batchSize) {
      final batchIds =
          idsList.sublist(i, math.min(i + batchSize, idsList.length));
      final rows = await customSelect(
        'SELECT id, document_iri_id, updated_at FROM sync_documents '
        'WHERE document_iri_id IN (${List.filled(batchIds.length, '?').join(',')})',
        variables: [for (final id in batchIds) Variable.withInt(id)],
        readsFrom: {syncDocuments},
      ).get();

      for (final row in rows) {
        final iriId = row.read<int>('document_iri_id');
        result[iriId] = (
          id: row.read<int>('id'),
          updatedAt: row.read<int>('updated_at'),
        );
      }
    }

    return result;
  }

  Future<void> saveDocumentsBatch(
      List<BatchDocumentSaveOperation> operations) async {
    if (operations.isEmpty) {
      return;
    }

    final existingByDocumentIriId = await getDocumentExistenceByDocumentIriIds(
      operations.map((operation) => operation.documentIriId),
    );

    for (final operation in operations) {
      final existing = existingByDocumentIriId[operation.documentIriId];
      if (existing == null && operation.ifMatchUpdatedAt != null) {
        throw ConcurrentUpdateException(
            'Trying to conditionally update a non-existent document');
      }
      if (existing != null &&
          operation.ifMatchUpdatedAt != null &&
          existing.updatedAt != operation.ifMatchUpdatedAt) {
        throw ConcurrentUpdateException(
            "Conflict: document exists but updatedAt didn't match");
      }
    }

    await batch((batch) {
      for (final operation in operations) {
        final existing = existingByDocumentIriId[operation.documentIriId];
        final companion = SyncDocumentsCompanion(
          documentIriId: Value(operation.documentIriId),
          typeIriId: Value(operation.typeIriId),
          documentContent: Value(operation.content),
          ourPhysicalClock: Value(operation.ourPhysicalClock),
          updatedAt: Value(operation.updatedAt),
        );

        if (existing != null) {
          batch.update(
            syncDocuments,
            companion,
            where: (table) => table.id.equals(existing.id),
          );
        } else {
          batch.insert(syncDocuments, companion);
        }
      }
    });
  }

  /// Save a document with content and timestamps, returning the document ID.
  ///
  /// Supports optimistic locking via [ifMatchUpdatedAt]:
  /// - If null: unconditional save (no conflict check)
  /// - If non-null: save only if current updatedAt matches expected value
  /// - Returns null on conflict (optimistic lock failed)
  ///
  /// Uses updatedAt (not ourPhysicalClock) as the version marker because:
  /// - updatedAt is updated on every save (local and remote)
  /// - ourPhysicalClock only changes when we make local modifications
  /// - updatedAt provides true monotonic versioning
  ///
  /// Throws [ConcurrentUpdateException] on optimistic lock failure.
  Future<int> saveDocument({
    required String documentIri,
    required String typeIri,
    required Uint8List content,
    required int ourPhysicalClock,
    required int updatedAt,
    int? ifMatchUpdatedAt,
  }) async {
    // Use the mixin for consistency
    final iriToIdMap = await getOrCreateIriIdsBatch({documentIri, typeIri});
    final documentIriId = iriToIdMap[documentIri]!;
    final typeIriId = iriToIdMap[typeIri]!;

    // Try to get existing document first
    final existingDocument = await (select(syncDocuments)
          ..where((d) => d.documentIriId.equals(documentIriId)))
        .getSingleOrNull();

    if (existingDocument != null) {
      // Update existing document with optimistic locking in WHERE clause
      // Include ifMatchUpdatedAt in the WHERE condition for atomic check-and-set
      final updateQuery = update(syncDocuments)
        ..where((d) => d.id.equals(existingDocument.id));

      if (ifMatchUpdatedAt != null) {
        updateQuery.where((d) => d.updatedAt.equals(ifMatchUpdatedAt));
      }

      final rowsAffected = await updateQuery.write(SyncDocumentsCompanion(
        typeIriId: Value(typeIriId),
        documentContent: Value(content),
        ourPhysicalClock: Value(ourPhysicalClock),
        updatedAt: Value(updatedAt),
      ));

      // If optimistic lock was requested and update affected 0 rows, conflict detected
      if (ifMatchUpdatedAt != null && rowsAffected == 0) {
        // Conflict: document exists but updatedAt didn't match
        throw ConcurrentUpdateException(
            "Conflict: document exists but updatedAt didn't match");
      }

      return existingDocument.id;
    } else {
      // Insert new document
      // For new documents, ifMatchUpdatedAt should be null (no previous version exists)
      if (ifMatchUpdatedAt != null) {
        // Trying to conditionally update a non-existent document
        throw ConcurrentUpdateException(
            "Trying to conditionally update a non-existent document");
      }

      return await into(syncDocuments).insert(
        SyncDocumentsCompanion(
          documentIriId: Value(documentIriId),
          typeIriId: Value(typeIriId),
          documentContent: Value(content),
          ourPhysicalClock: Value(ourPhysicalClock),
          updatedAt: Value(updatedAt),
        ),
      );
    }
  }

  /// Get document content by IRI
  Future<Uint8List?> getDocumentContent(String documentIri) async {
    // For read operations, we should only get existing IRIs, not create them
    final documentIriId = await _getExistingIriId(documentIri);
    if (documentIriId == null) return null;

    final document = await (select(syncDocuments)
          ..where((d) => d.documentIriId.equals(documentIriId)))
        .getSingleOrNull();

    return document?.documentContent;
  }

  /// Get document with metadata by IRI
  Future<SyncDocument?> getDocument(String documentIri,
      {int? ifChangedSincePhysicalClock}) async {
    // For read operations, we should only get existing IRIs, not create them
    final documentIriId = await _getExistingIriId(documentIri);
    if (documentIriId == null) return null;
    final query = select(syncDocuments)
      ..where((d) => d.documentIriId.equals(documentIriId));
    if (ifChangedSincePhysicalClock != null &&
        ifChangedSincePhysicalClock > 0) {
      query.where((d) =>
          d.ourPhysicalClock.isBiggerThanValue(ifChangedSincePhysicalClock));
    }
    return await query.getSingleOrNull();
  }

  /// Get multiple documents with metadata by IRI.
  Future<List<DocumentWithIri>> getDocumentsByIri(Iterable<String> documentIris,
      {int? ifChangedSincePhysicalClock}) async {
    final iris = documentIris.toSet();
    if (iris.isEmpty) return [];

    final existingIriIds = await _getExistingIriIds(iris);
    if (existingIriIds.isEmpty) return [];

    final query = select(syncDocuments)
      ..where((d) => d.documentIriId.isIn(existingIriIds.values.toList()));
    if (ifChangedSincePhysicalClock != null &&
        ifChangedSincePhysicalClock > 0) {
      query.where((d) =>
          d.ourPhysicalClock.isBiggerThanValue(ifChangedSincePhysicalClock));
    }

    final documents = await query.get();
    if (documents.isEmpty) return [];

    final idToIri = {
      for (final entry in existingIriIds.entries) entry.value: entry.key,
    };

    return documents
        .map((document) => DocumentWithIri(
              iri: idToIri[document.documentIriId]!,
              document: document,
            ))
        .toList(growable: false);
  }

  /// Get document ID by IRI (for property changes)
  Future<int?> getDocumentId(String documentIri) async {
    // For read operations, we should only get existing IRIs, not create them
    final documentIriId = await _getExistingIriId(documentIri);
    if (documentIriId == null) return null;

    final document = await (select(syncDocuments)
          ..where((d) => d.documentIriId.equals(documentIriId)))
        .getSingleOrNull();

    return document?.id;
  }

  /// Get documents of a specific type modified since cursor with pagination support.
  ///
  /// Returns a batch of documents for initial loading before switching to reactive watch.
  /// Used for paginated loading of existing documents.
  Future<List<DocumentWithIri>> getDocumentsModifiedSince(
      String typeIri, String? minCursor,
      {required int limit}) async {
    final typeIriId = await _getExistingIriId(typeIri);
    if (typeIriId == null) return [];

    final timestamp = minCursor != null ? int.parse(minCursor) : 0;

    final documents = await (select(syncDocuments)
          ..where((d) =>
              d.typeIriId.equals(typeIriId) &
              d.updatedAt.isBiggerThanValue(timestamp))
          ..orderBy([(d) => OrderingTerm(expression: d.updatedAt)])
          ..limit(limit))
        .get();

    return _convertDocumentsWithIris(documents);
  }

  /// Get documents of a specific type changed by us since cursor with pagination support.
  ///
  /// Returns a batch of documents for initial sync before switching to reactive watch.
  /// Used for paginated loading of local changes.
  Future<List<DocumentWithIri>> getDocumentsChangedByUsSince(
      String typeIri, String? minCursor,
      {required int limit}) async {
    final typeIriId = await _getExistingIriId(typeIri);
    if (typeIriId == null) return [];

    final timestamp = minCursor != null ? int.parse(minCursor) : 0;

    final documents = await (select(syncDocuments)
          ..where((d) =>
              d.typeIriId.equals(typeIriId) &
              d.ourPhysicalClock.isBiggerThanValue(timestamp))
          ..orderBy([(d) => OrderingTerm(expression: d.ourPhysicalClock)])
          ..limit(limit))
        .get();

    return _convertDocumentsWithIris(documents);
  }

  /// Watch documents of a specific type modified since cursor, ordered by updatedAt ascending.
  ///
  /// Automatically emits updates whenever documents of the given type change in the database.
  /// Uses progressive cursor tracking to emit only documents that have changed since the last emission.
  /// Combines WHERE clause filtering (DB-level efficiency) with in-memory progressive filtering (avoiding re-emissions).
  /// This leverages Drift's reactive query support for efficient change detection.
  Stream<List<DocumentWithIri>> watchDocumentsModifiedSince(
      String typeIri, String? minCursor) async* {
    // for watch we need to do getOrCreate to ensure typeIri exists
    // because there might be no documents of this type yet but later
    final typeIriId = await getOrCreateIriId(typeIri);
    final initialCursor = minCursor != null ? int.parse(minCursor) : 0;

    // WHERE clause filters at DB level for efficiency (static, uses initial cursor)
    // This prevents loading documents that are clearly before our starting point
    final query = select(syncDocuments)
      ..where((d) =>
          d.typeIriId.equals(typeIriId) &
          d.updatedAt.isBiggerThanValue(initialCursor))
      ..orderBy([(d) => OrderingTerm(expression: d.updatedAt)]);

    yield* query
        .watchWithCursor(
          getCursor: (d) => d.updatedAt,
          initialCursor: initialCursor,
        )
        .asyncMap((newDocuments) => _convertDocumentsWithIris(newDocuments));
  }

  /// Watch documents of a specific type changed by us since cursor, ordered by ourPhysicalClock ascending.
  ///
  /// Automatically emits updates whenever documents that we changed are modified in the database.
  /// Uses progressive cursor tracking to emit only documents that have changed since the last emission.
  /// Combines WHERE clause filtering (DB-level efficiency) with in-memory progressive filtering (avoiding re-emissions).
  /// This leverages Drift's reactive query support for efficient change detection.
  Stream<List<DocumentWithIri>> watchDocumentsChangedByUsSince(
      String typeIri, String? minCursor) async* {
    final typeIriId = await getOrCreateIriId(typeIri);
    final initialCursor = minCursor != null ? int.parse(minCursor) : 0;

    // WHERE clause filters at DB level for efficiency (static, uses initial cursor)
    // This prevents loading documents that are clearly before our starting point
    final query = select(syncDocuments)
      ..where((d) =>
          d.typeIriId.equals(typeIriId) &
          d.ourPhysicalClock.isBiggerThanValue(initialCursor))
      ..orderBy([(d) => OrderingTerm(expression: d.ourPhysicalClock)]);

    yield* query
        .watchWithCursor(
          getCursor: (d) => d.ourPhysicalClock,
          initialCursor: initialCursor,
        )
        .asyncMap((newDocuments) => _convertDocumentsWithIris(newDocuments));
  }

  /// Get the highest updatedAt timestamp for a specific type (for cursor management)
  Future<int?> getMaxUpdatedAtForType(String typeIri) async {
    final typeIriId = await _getExistingIriId(typeIri);
    if (typeIriId == null) return null;

    final result = await (selectOnly(syncDocuments)
          ..where(syncDocuments.typeIriId.equals(typeIriId))
          ..addColumns([syncDocuments.updatedAt.max()]))
        .getSingleOrNull();

    return result?.read(syncDocuments.updatedAt.max());
  }

  /// Convert documents with IRI resolution using batching
  Future<List<DocumentWithIri>> _convertDocumentsWithIris(
      List<SyncDocument> documents) async {
    if (documents.isEmpty) return [];

    // Batch load all document IRIs
    final iriIds = documents.map((d) => d.documentIriId).toSet();
    final iriMap = await getIrisBatch(iriIds);

    return documents
        .map((doc) => DocumentWithIri(
              iri: iriMap[doc.documentIriId]!,
              document: doc,
            ))
        .toList();
  }
}

/// Data Access Object for property change tracking
@DriftAccessor(tables: [SyncPropertyChanges, SyncIris])
class SyncPropertyChangeDao extends DatabaseAccessor<SyncDatabase>
    with _$SyncPropertyChangeDaoMixin, IriBatchLoader {
  SyncPropertyChangeDao(super.db);

  /// Record multiple property changes efficiently in batch
  Future<void> recordPropertyChangesBatch({
    required int documentId,
    required List<PropertyChange> changes,
  }) async {
    if (changes.isEmpty) return;

    // Collect all unique IRIs that need IDs
    final allIris = changes
        .expand((change) => [
              change.resourceIri.value,
              predicateValue(change.propertyIri),
            ])
        .toSet();

    // Batch get/create all IRI IDs using the mixin
    final iriToIdMap = await getOrCreateIriIdsBatch(allIris);

    // Batch insert all property changes
    final companions = changes
        .map((change) => SyncPropertyChangesCompanion(
              documentId: Value(documentId),
              resourceIriId: Value(iriToIdMap[change.resourceIri.value]!),
              propertyIriId:
                  Value(iriToIdMap[predicateValue(change.propertyIri)]!),
              changedAtMs: Value(change.changedAtMs),
              changeLogicalClock: Value(change.changeLogicalClock),
              isFrameworkProperty: Value(change.isFrameworkProperty),
            ))
        .toList();

    await batch((batch) {
      batch.insertAll(syncPropertyChanges, companions);
    });
  }

  Future<void> recordPropertyChangesForDocumentsBatch(
      Map<int, List<PropertyChange>> changesByDocumentId) async {
    if (changesByDocumentId.isEmpty) {
      return;
    }

    final allChanges = changesByDocumentId.values.expand((value) => value);
    final allIris = allChanges
        .expand((change) => [
              change.resourceIri.value,
              predicateValue(change.propertyIri),
            ])
        .toSet();
    final iriToIdMap = await getOrCreateIriIdsBatch(allIris);

    final companions = <SyncPropertyChangesCompanion>[];
    for (final entry in changesByDocumentId.entries) {
      for (final change in entry.value) {
        companions.add(
          SyncPropertyChangesCompanion(
            documentId: Value(entry.key),
            resourceIriId: Value(iriToIdMap[change.resourceIri.value]!),
            propertyIriId:
                Value(iriToIdMap[predicateValue(change.propertyIri)]!),
            changedAtMs: Value(change.changedAtMs),
            changeLogicalClock: Value(change.changeLogicalClock),
            isFrameworkProperty: Value(change.isFrameworkProperty),
          ),
        );
      }
    }

    if (companions.isEmpty) {
      return;
    }

    await batch((batch) {
      batch.insertAll(syncPropertyChanges, companions);
    });
  }

  String predicateValue(RdfPredicate predicate) =>
      switch (predicate) { IriTerm iri => iri.value };

  /// Get property changes for a document, optionally filtered by logical clock
  Future<List<PropertyChangeInfo>> getPropertyChanges(int documentId,
      {int? sinceLogicalClock}) async {
    // 1. Get all property changes
    var query = select(syncPropertyChanges)
      ..where((c) => c.documentId.equals(documentId));
    if (sinceLogicalClock != null) {
      query = query
        ..where(
            (c) => c.changeLogicalClock.isBiggerThanValue(sinceLogicalClock));
    }
    final changes = await query.get();

    // 2. Collect all unique IRI IDs that need resolution
    final iriIds = <int>{};
    for (final change in changes) {
      iriIds.add(change.resourceIriId);
      iriIds.add(change.propertyIriId);
    }

    // 3. Batch load all IRIs in one query
    final iriMap = await getIrisBatch(iriIds);

    // 4. Build results using the cached IRI map
    return changes
        .map((change) => PropertyChangeInfo(
              resourceIri: iriMap[change.resourceIriId]!,
              propertyIri: iriMap[change.propertyIriId]!,
              changedAtMs: change.changedAtMs,
              changeLogicalClock: change.changeLogicalClock,
              isFrameworkProperty: change.isFrameworkProperty,
            ))
        .toList();
  }
}

/// Property change information
class PropertyChangeInfo {
  final String resourceIri;
  final String propertyIri;
  final int changedAtMs;
  final int changeLogicalClock;
  final bool isFrameworkProperty;

  PropertyChangeInfo({
    required this.resourceIri,
    required this.propertyIri,
    required this.changedAtMs,
    required this.changeLogicalClock,
    required this.isFrameworkProperty,
  });
}

/// Data Access Object for index management
@DriftAccessor(tables: [
  IndexEntries,
  GroupIndexSubscriptions,
  SyncIris,
  IndexIriIdSetVersions,
  IndexShards,
])
class IndexDao extends DatabaseAccessor<SyncDatabase>
    with _$IndexDaoMixin, IriBatchLoader {
  IndexDao(super.db);

  /// Get index entries for hydration (cursor-based, excluding deleted)
  Future<IndexEntriesPage> getIndexEntries({
    required Iterable<int> indexIds,
    int? cursorTimestamp,
    int limit = 100,
  }) async {
    // Direct query without joins - indexId is denormalized on index_entries
    var query = select(db.indexEntries)
      ..where((e) => e.indexIriId.isIn(indexIds));

    // Apply cursor based on updatedAt timestamp (milliseconds since epoch)
    if (cursorTimestamp != null) {
      query = query
        ..where((e) => e.updatedAt.isBiggerThanValue(cursorTimestamp));
    }

    // Order by update timestamp
    query = query
      ..orderBy([(e) => OrderingTerm.asc(e.updatedAt)])
      ..limit(limit);

    final entries = await query.get();

    if (entries.isEmpty) {
      return IndexEntriesPage(entries: [], hasMore: false, lastCursor: null);
    }

    final lastCursor = entries.last.updatedAt;
    final hasMore = entries.length == limit;

    return IndexEntriesPage(
      entries: entries,
      hasMore: hasMore,
      lastCursor: lastCursor,
    );
  }

  /// Watch index entries for reactive hydration with progressive cursor tracking.
  ///
  /// Uses entry-level change tracking to emit only entries that have changed
  /// since the last emission. The [cursorTimestamp] acts as the initial baseline,
  /// and subsequent emissions only include entries with updatedAt > last emitted cursor.
  /// Combines WHERE clause filtering (DB-level efficiency) with in-memory progressive filtering (avoiding re-emissions).
  ///
  /// This minimizes the number of entries re-emitted when a single entry in a shard changes.
  Stream<List<IndexEntry>> watchIndexEntries({
    required Iterable<int> indexIds,
    int? cursorTimestamp,
  }) {
    final initialCursor = cursorTimestamp ?? 0;

    // WHERE clause filters at DB level for efficiency (static, uses initial cursor)
    // This prevents loading entries that are clearly before our starting point
    var query = select(db.indexEntries)
      ..where((e) => e.indexIriId.isIn(indexIds));

    if (initialCursor > 0) {
      query = query..where((e) => e.updatedAt.isBiggerThanValue(initialCursor));
    }

    query = query..orderBy([(e) => OrderingTerm.asc(e.updatedAt)]);

    return query.watchWithCursor(
      getCursor: (e) => e.updatedAt,
      initialCursor: initialCursor,
    );
  }

  /// Save or update a group index subscription
  Future<void> saveGroupIndexSubscription({
    required int groupIndexIriId,
    required int groupIndexTemplateIriId,
    required int indexedTypeIriId,
    required String rootResourceFetchPolicy,
    required int createdAt,
  }) async {
    await into(db.groupIndexSubscriptions).insert(
      GroupIndexSubscriptionsCompanion.insert(
        groupIndexIriId: Value(groupIndexIriId),
        groupIndexTemplateIriId: groupIndexTemplateIriId,
        indexedTypeIriId: indexedTypeIriId,
        itemFetchPolicy: rootResourceFetchPolicy,
        createdAt: createdAt,
      ),
      onConflict: DoUpdate(
        (_) => GroupIndexSubscriptionsCompanion(
          groupIndexTemplateIriId: Value(groupIndexTemplateIriId),
          indexedTypeIriId: Value(indexedTypeIriId),
          itemFetchPolicy: Value(rootResourceFetchPolicy),
        ),
        target: [db.groupIndexSubscriptions.groupIndexIriId],
      ),
    );
  }

  /// Get subscribed group index IDs for a template
  Future<Set<int>> getSubscribedGroupIndexIds(
      int groupIndexTemplateIriId) async {
    final results = await (select(db.groupIndexSubscriptions)
          ..where(
              (s) => s.groupIndexTemplateIriId.equals(groupIndexTemplateIriId)))
        .get();

    return results.map((row) => row.groupIndexIriId).toSet();
  }

  /// Watch subscribed group index IDs for reactive updates
  Stream<Set<int>> watchSubscribedGroupIndexIds(int templateId) {
    return (select(db.groupIndexSubscriptions)
          ..where((s) => s.groupIndexTemplateIriId.equals(templateId)))
        .watch()
        .map((results) => results.map((row) => row.groupIndexIriId).toSet());
  }

  /// Get subscribed group indices for a specific indexed type.
  ///
  /// Returns records containing group/indexed type IRI IDs and item fetch
  /// policy for all group indices that index the given type.
  /// Used during remote sync to determine which indices need synchronization.
  Future<List<SubscribedGroupIndexData>> getSubscribedGroupIndices(
      int indexedTypeIriId) async {
    final subscriptions = await (select(db.groupIndexSubscriptions)
          ..where((s) => s.indexedTypeIriId.equals(indexedTypeIriId)))
        .get();
    if (subscriptions.isEmpty) return const [];

    return subscriptions
        .map((subscription) => SubscribedGroupIndexData(
              groupIndexIriId: subscription.groupIndexIriId,
              indexedTypeIriId: indexedTypeIriId,
              rootResourceFetchPolicy: subscription.itemFetchPolicy,
            ))
        .toList();
  }

  /// Batch variant of [getSubscribedGroupIndices] for a set of indexed type IDs.
  ///
  /// Issues a single `WHERE indexedTypeIriId IN (...)` query instead of one
  /// query per type. Returns all matching rows; callers group by type as needed.
  Future<List<SubscribedGroupIndexData>> getAllSubscribedGroupIndices(
      Set<int> typeIriIds) async {
    if (typeIriIds.isEmpty) return const [];

    final subscriptions = await (select(db.groupIndexSubscriptions)
          ..where((s) => s.indexedTypeIriId.isIn(typeIriIds.toList())))
        .get();
    if (subscriptions.isEmpty) return const [];

    return subscriptions
        .map((subscription) => SubscribedGroupIndexData(
              groupIndexIriId: subscription.groupIndexIriId,
              indexedTypeIriId: subscription.indexedTypeIriId,
              rootResourceFetchPolicy: subscription.itemFetchPolicy,
            ))
        .toList();
  }

  ///
  /// Returns the version ID that can be used in cursor strings.
  /// Index IDs are automatically sorted to ensure consistent hashing.
  Future<int> ensureIndexIdSetVersion({
    required Set<int> indexIds,
    required int createdAt,
  }) async {
    // Sort IDs to ensure consistent representation
    final sortedIds = indexIds.toList()..sort();
    final idsStr = sortedIds.join(',');

    // Try to find existing version
    final existing = await (select(db.indexIriIdSetVersions)
          ..where((v) => v.indexIriIds.equals(idsStr)))
        .getSingleOrNull();

    if (existing != null) {
      return existing.id;
    }

    // Create new version
    return await into(db.indexIriIdSetVersions).insert(
      IndexIriIdSetVersionsCompanion.insert(
        indexIriIds: idsStr,
        createdAt: createdAt,
      ),
    );
  }

  /// Get the index IDs for a given set version.
  ///
  /// Returns empty list if version not found.
  Future<List<int>> getIndexIriIdsForVersion(int versionId) async {
    final version = await (select(db.indexIriIdSetVersions)
          ..where((v) => v.id.equals(versionId)))
        .getSingleOrNull();

    if (version == null) return [];

    if (version.indexIriIds.isEmpty) return [];
    return version.indexIriIds.split(',').map(int.parse).toList();
  }

  /// Looks up the stored `indexIriId` for each given shard from the
  /// structural [IndexShards] table (shard→index mapping).
  ///
  /// Returns a map from shardIriId to indexIriId. Shards not found are omitted.
  Future<Map<int, int>> getIndexIriIdsForShards(List<int> shardIriIds) async {
    if (shardIriIds.isEmpty) return const {};

    final query = select(db.indexShards)
      ..where((s) => s.shardIriId.isIn(shardIriIds));

    final rows = await query.get();
    return {for (final row in rows) row.shardIriId: row.indexIriId};
  }

  /// Save or update an index entry (overwrites existing entry).
  Future<void> saveIndexEntry({
    required int shardIriId,
    required int indexIriId,
    required int resourceIriId,
    required int resourceTypeIriId,
    required String clockHash,
    Uint8List? headerProperties,
    bool isDeleted = false,
    bool isRemoteOnly = false,
    required int ourPhysicalClock,
    required int updatedAt,
  }) async {
    await into(db.indexEntries).insertOnConflictUpdate(
      IndexEntriesCompanion.insert(
        shardIri: shardIriId,
        indexIriId: indexIriId,
        resourceIriId: resourceIriId,
        resourceTypeIriId: resourceTypeIriId,
        clockHash: clockHash,
        headerProperties: Value(headerProperties),
        updatedAt: updatedAt,
        ourPhysicalClock: ourPhysicalClock,
        isDeleted: Value(isDeleted),
        isRemoteOnly: Value(isRemoteOnly),
      ),
    );
  }

  /// Save or update multiple index entries.
  Future<void> saveIndexEntriesBatch(
      Iterable<BatchIndexEntrySaveOperation> operations) async {
    final operationList = operations.toList(growable: false);
    if (operationList.isEmpty) {
      return;
    }

    await batch((batch) {
      for (final operation in operationList) {
        batch.insert(
          db.indexEntries,
          IndexEntriesCompanion.insert(
            shardIri: operation.shardIriId,
            indexIriId: operation.indexIriId,
            resourceIriId: operation.resourceIriId,
            resourceTypeIriId: operation.resourceTypeIriId,
            clockHash: operation.clockHash,
            headerProperties: Value(operation.headerProperties),
            updatedAt: operation.updatedAt,
            ourPhysicalClock: operation.ourPhysicalClock,
            isDeleted: Value(operation.isDeleted),
            isRemoteOnly: Value(operation.isRemoteOnly),
          ),
          mode: InsertMode.insertOrReplace,
        );
      }
    });
  }

  /// Persist remote-only shard entries — entries seen in the remote shard but
  /// not yet fetched locally. Upserts [entriesToUpsert] with is_remote_only = 1
  /// (only when the row does not already exist with is_remote_only = 0),
  /// then deletes stale remote-only rows no longer present in
  /// [allCurrentRemoteIriIds].
  ///
  /// Chunked to respect SQLite's 999-variable limit.
  Future<void> syncRemoteOnlyShardEntries({
    required int shardIriId,
    required int indexIriId,
    required int typeIriId,
    required List<
            ({
              int resourceIriId,
              String clockHash,
              Uint8List? headerProperties
            })>
        entriesToUpsert,
    required List<int> allCurrentRemoteIriIds,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction(() async {
      // Upsert: insert new rows as remote-only, or update clock_hash and
      // updated_at for existing remote-only rows. Skip rows with
      // is_remote_only = 0 to protect genuinely local entries.
      // updated_at must be set to a real timestamp so watchIndexEntries
      // cursors (which filter on updated_at > lastCursor) can see the entry.
      for (final entry in entriesToUpsert) {
        // Use customUpdate (not customStatement) so Drift notifies
        // watchIndexEntries watchers when the transaction commits.
        await db.customUpdate(
          'INSERT INTO index_entries'
          ' (shard_iri, index_iri_id, resource_iri_id, resource_type_iri_id,'
          '  clock_hash, header_properties, updated_at, our_physical_clock,'
          '  is_deleted, is_remote_only)'
          ' VALUES (?, ?, ?, ?, ?, ?, ?, 0, 0, 1)'
          ' ON CONFLICT(shard_iri, resource_iri_id) DO UPDATE SET'
          '  clock_hash = excluded.clock_hash,'
          '  header_properties = excluded.header_properties,'
          '  index_iri_id = excluded.index_iri_id,'
          '  resource_type_iri_id = excluded.resource_type_iri_id,'
          '  updated_at = excluded.updated_at'
          ' WHERE is_remote_only = 1',
          variables: [
            Variable.withInt(shardIriId),
            Variable.withInt(indexIriId),
            Variable.withInt(entry.resourceIriId),
            Variable.withInt(typeIriId),
            Variable.withString(entry.clockHash),
            Variable<Uint8List>(entry.headerProperties),
            Variable.withInt(now),
          ],
          updates: {db.indexEntries},
        );
      }

      // Determine stale remote-only entries (in DB but no longer in remote shard).
      final existingRows = await db.customSelect(
        'SELECT resource_iri_id FROM index_entries'
        ' WHERE shard_iri = ? AND is_remote_only = 1',
        variables: [Variable.withInt(shardIriId)],
        readsFrom: {db.indexEntries},
      ).get();

      final currentSet = allCurrentRemoteIriIds.toSet();
      final staleIds = existingRows
          .map((r) => r.read<int>('resource_iri_id'))
          .where((id) => !currentSet.contains(id))
          .toList();

      if (staleIds.isNotEmpty) {
        // Chunk the IN-list to respect SQLite's 999-variable limit.
        // Each DELETE uses shard_iri (1 var) + chunk (N vars) = N+1 total.
        const chunkSize = 498;
        for (var i = 0; i < staleIds.length; i += chunkSize) {
          final end =
              i + chunkSize > staleIds.length ? staleIds.length : i + chunkSize;
          final chunk = staleIds.sublist(i, end);
          await (db.delete(db.indexEntries)
                ..where((e) =>
                    e.shardIri.equals(shardIriId) &
                    e.isRemoteOnly.equals(true) &
                    e.resourceIriId.isIn(chunk)))
              .go();
        }
      }
    });
  }

  /// Get all active (non-deleted) entries for a shard.
  ///
  /// Used for sync to generate shard documents.
  Future<List<IndexEntry>> getActiveIndexEntriesForShard(int shardIriId) async {
    return (select(db.indexEntries)
          ..where(
              (e) => e.shardIri.equals(shardIriId) & e.isDeleted.equals(false)))
        .get();
  }

  /// Get active entries for a shard that were locally modified after
  /// [sinceTimestamp] (i.e. `updated_at > sinceTimestamp`).
  ///
  /// Fast path for the "shard not modified" case — avoids loading unchanged
  /// entries that would be discarded by the caller.
  Future<List<IndexEntry>> getLocallyChangedEntriesForShard(
      int shardIriId, int sinceTimestamp) async {
    return (select(db.indexEntries)
          ..where((e) =>
              e.shardIri.equals(shardIriId) &
              e.isDeleted.equals(false) &
              e.isRemoteOnly.equals(false) &
              e.updatedAt.isBiggerThanValue(sinceTimestamp)))
        .get();
  }

  /// Returns shard IRI strings that contain at least one non-deleted entry
  /// with `updated_at > sinceTimestamp`, up to [limit] results.
  ///
  /// Single lightweight query used as a pre-filter to avoid per-shard
  /// roundtrips for unchanged shards in change detection. Pass `limit + 1` to
  /// allow the caller to detect overflow.
  Future<List<String>> getShardsWithLocalChangesSince(int sinceTimestamp,
      {int limit = 20}) async {
    final results = await customSelect(
      'SELECT DISTINCT s.iri FROM index_entries e '
      'INNER JOIN sync_iris s ON s.id = e.shard_iri '
      // Include deleted entries: local deletions must also trigger shard reprocessing.
      // Exclude remote-only entries: they carry no local changes.
      'WHERE e.updated_at > ? AND e.is_remote_only = 0 '
      'LIMIT ?',
      variables: [
        Variable.withInt(sinceTimestamp),
        Variable.withInt(limit),
      ],
      readsFrom: {db.indexEntries, db.syncIris},
    ).get();
    return results.map((row) => row.read<String>('iri')).toList();
  }

  /// Batch variant of [getActiveIndexEntriesForShard] for multiple shards.
  ///
  /// Executes a single `WHERE shard_iri IN (...)` query, avoiding one
  /// isolate roundtrip per shard. Returns a map keyed by shard IRI integer ID.
  /// Shards with no active entries are not present in the returned map.
  Future<Map<int, List<IndexEntry>>> getActiveIndexEntriesForShards(
      List<int> shardIriIds) async {
    if (shardIriIds.isEmpty) return {};

    final entries = await (select(db.indexEntries)
          ..where(
              (e) => e.shardIri.isIn(shardIriIds) & e.isDeleted.equals(false)))
        .get();

    final grouped = <int, List<IndexEntry>>{};
    for (final entry in entries) {
      grouped.putIfAbsent(entry.shardIri, () => []).add(entry);
    }
    return grouped;
  }

  /// Get shard IRIs that have entries modified after the given timestamp.
  ///
  /// This includes both new/updated entries and deleted entries (tombstones).
  /// Used by SyncFunction to find shards that need to be regenerated.
  ///
  /// Returns: List of tuples (shardIri, resourceTypeIri, maxPhysicalClock) for shards with modifications.
  ///
  /// Uses max(ourPhysicalClock) per shard to find shards with changes since the last sync.
  /// This ensures deletions are properly detected using the item's timestamp,
  /// not the deletion operation's timestamp.
  ///
  /// Also returns [shardIriId] (the integer PK from sync_iris) so callers can
  /// warm their IRI→ID caches without an extra round-trip per shard.
  Future<
      List<
          ({
            int shardIriId,
            String shardIri,
            String resourceTypeIri,
            String indexIri,
            int maxPhysicalClock
          })>> getShardsToUpdate(int sinceTimestamp) async {
    // Use raw SQL with HAVING clause for efficient filtering on DB level.
    // e.shard_iri is already the integer FK into sync_iris — expose it so
    // the storage layer can pre-warm its IRI→ID cache without extra queries.
    final results = await customSelect(
      '''
      SELECT e.shard_iri as shard_iri_id, s.iri as shard_iri, t.iri as resource_type_iri, i.iri as index_iri, MAX(e.our_physical_clock) as max_clock
      FROM index_entries e
      JOIN sync_iris s ON s.id = e.shard_iri
      JOIN sync_iris t ON t.id = e.resource_type_iri_id
      JOIN sync_iris i ON i.id = e.index_iri_id
      GROUP BY e.shard_iri, e.resource_type_iri_id, e.index_iri_id
      HAVING max_clock > ?
      ''',
      variables: [Variable.withInt(sinceTimestamp)],
      readsFrom: {db.indexEntries, db.syncIris},
    ).get();

    return results
        .map((row) => (
              shardIriId: row.read<int>('shard_iri_id'),
              shardIri: row.read<String>('shard_iri'),
              resourceTypeIri: row.read<String>('resource_type_iri'),
              indexIri: row.read<String>('index_iri'),
              maxPhysicalClock: row.read<int>('max_clock'),
            ))
        .toList();
  }

  /// Get foreign index shards that need partial sync.
  ///
  /// Foreign indices are those NOT explicitly configured/subscribed.
  /// We need to sync their shards when they contain resources that:
  /// 1. Were modified locally (dirty entries need upload)
  /// 2. Are not yet covered by any configured index shard (uncovered resources)
  ///
  /// Parameters:
  /// - [resourceTypeIriId]: The type IRI ID to filter entries by
  /// - [sinceTimestamp]: Physical clock timestamp - entries modified after this are dirty
  /// - [excludeIndexIriIds]: Configured/subscribed index IRI IDs to exclude from foreign sync
  ///
  /// A foreign shard needs sync if it contains ANY resource where:
  /// - Resource is dirty (our_physical_clock > sinceTimestamp), OR
  /// - Resource is not in any configured index shard (uncovered)
  ///
  /// INCLUDES deleted entries (tombstones) because:
  /// - Dirty tombstones must be pushed to remote (deletions are changes)
  /// - Uncovered tombstones must be pulled from remote (for proper CRDT merge)
  ///
  /// Performance optimization: Uses two separate queries instead of expensive NOT IN subquery:
  /// - Query 1: Dirty foreign index entries (simple timestamp filter)
  /// - Query 2: Uncovered foreign index entries (efficient LEFT JOIN with IS NULL)
  ///
  /// Returns: Map of index IRI -> Map of (shard IRI -> Map of (resource IRI -> clockHash))
  Future<Map<String, Map<String, Map<String, String>>>>
      getForeignIndexShardsToSync({
    required int resourceTypeIriId,
    required int sinceTimestamp,
    required Set<int> excludeIndexIriIds,
  }) async {
    final indexToShards = <String, Map<String, Map<String, String>>>{};

    // Query 1: Get dirty foreign index entries (fast - simple timestamp filter)
    final dirtyResults = await _queryDirtyForeignEntries(
      resourceTypeIriId: resourceTypeIriId,
      sinceTimestamp: sinceTimestamp,
      excludeIndexIriIds: excludeIndexIriIds,
    );
    _groupResults(dirtyResults, indexToShards);

    // Query 2: Get uncovered foreign index entries (optimized LEFT JOIN)
    // If no configured indices exist (excludeIndexIriIds.isEmpty), this finds ALL
    // foreign index entries since all resources are "uncovered" by definition
    final uncoveredResults = await _queryUncoveredForeignEntries(
      resourceTypeIriId: resourceTypeIriId,
      excludeIndexIriIds: excludeIndexIriIds,
    );
    _groupResults(uncoveredResults, indexToShards);

    return indexToShards;
  }

  /// Query dirty foreign index entries - modified since timestamp.
  Future<List<QueryRow>> _queryDirtyForeignEntries({
    required int resourceTypeIriId,
    required int sinceTimestamp,
    required Set<int> excludeIndexIriIds,
  }) async {
    final whereConditions = <String>[
      'e.resource_type_iri_id = ?',
      if (excludeIndexIriIds.isNotEmpty)
        'e.index_iri_id NOT IN (${excludeIndexIriIds.join(',')})',
      'e.our_physical_clock > ?',
    ];

    return await customSelect(
      '''
      SELECT 
        idx.iri as index_iri,
        shard.iri as shard_iri,
        res.iri as resource_iri,
        e.clock_hash as clock_hash
      FROM index_entries e
      JOIN sync_iris idx ON idx.id = e.index_iri_id
      JOIN sync_iris shard ON shard.id = e.shard_iri
      JOIN sync_iris res ON res.id = e.resource_iri_id
      WHERE ${whereConditions.join(' AND ')}
      ''',
      variables: [
        Variable.withInt(resourceTypeIriId),
        Variable.withInt(sinceTimestamp)
      ],
      readsFrom: {db.indexEntries, db.syncIris},
    ).get();
  }

  /// Query uncovered foreign index entries - not in any configured index.
  /// If excludeIndexIriIds is empty, all entries are uncovered (no configured indices exist).
  /// Uses LEFT JOIN for better performance than NOT IN subquery.
  Future<List<QueryRow>> _queryUncoveredForeignEntries({
    required int resourceTypeIriId,
    required Set<int> excludeIndexIriIds,
  }) async {
    if (excludeIndexIriIds.isEmpty) {
      // No configured indices - all entries are uncovered
      return await customSelect(
        '''
        SELECT 
          idx.iri as index_iri,
          shard.iri as shard_iri,
          res.iri as resource_iri,
          e.clock_hash as clock_hash
        FROM index_entries e
        JOIN sync_iris idx ON idx.id = e.index_iri_id
        JOIN sync_iris shard ON shard.id = e.shard_iri
        JOIN sync_iris res ON res.id = e.resource_iri_id
        WHERE e.resource_type_iri_id = ?
        ''',
        variables: [Variable.withInt(resourceTypeIriId)],
        readsFrom: {db.indexEntries, db.syncIris},
      ).get();
    }

    // Normal case: check which resources are not in configured indices
    return await customSelect(
      '''
      SELECT 
        idx.iri as index_iri,
        shard.iri as shard_iri,
        res.iri as resource_iri,
        e.clock_hash as clock_hash
      FROM index_entries e
      JOIN sync_iris idx ON idx.id = e.index_iri_id
      JOIN sync_iris shard ON shard.id = e.shard_iri
      JOIN sync_iris res ON res.id = e.resource_iri_id
      LEFT JOIN index_entries configured 
        ON e.resource_iri_id = configured.resource_iri_id 
        AND configured.index_iri_id IN (${excludeIndexIriIds.join(',')})
      WHERE e.resource_type_iri_id = ?
        AND e.index_iri_id NOT IN (${excludeIndexIriIds.join(',')})
        AND configured.resource_iri_id IS NULL
      ''',
      variables: [Variable.withInt(resourceTypeIriId)],
      readsFrom: {db.indexEntries, db.syncIris},
    ).get();
  }

  /// Group query results into nested map structure.
  void _groupResults(
    List<QueryRow> results,
    Map<String, Map<String, Map<String, String>>> indexToShards,
  ) {
    for (final row in results) {
      final indexIri = row.read<String>('index_iri');
      final shardIri = row.read<String>('shard_iri');
      final resourceIri = row.read<String>('resource_iri');
      final clockHash = row.read<String>('clock_hash');

      final shardMap = indexToShards.putIfAbsent(indexIri, () => {});
      shardMap.putIfAbsent(shardIri, () => <String, String>{})[resourceIri] =
          clockHash;
    }
  }

  /// Batch variant of [getForeignIndexShardsToSync] for multiple resource types.
  ///
  /// Uses a single pair of SQL queries with `IN (...)` for resource types
  /// instead of one pair per type, reducing round-trips from 2N to 2.
  Future<Map<String, Map<String, Map<String, Map<String, String>>>>>
      getForeignIndexShardsToSyncForTypes({
    required Set<int> resourceTypeIriIds,
    required int sinceTimestamp,
    required Set<int> excludeIndexIriIds,
  }) async {
    if (resourceTypeIriIds.isEmpty) return {};
    final result = <String, Map<String, Map<String, Map<String, String>>>>{};

    final dirtyResults = await _queryDirtyForeignEntriesForTypes(
      resourceTypeIriIds: resourceTypeIriIds,
      sinceTimestamp: sinceTimestamp,
      excludeIndexIriIds: excludeIndexIriIds,
    );
    _groupResultsByType(dirtyResults, result);

    final uncoveredResults = await _queryUncoveredForeignEntriesForTypes(
      resourceTypeIriIds: resourceTypeIriIds,
      excludeIndexIriIds: excludeIndexIriIds,
    );
    _groupResultsByType(uncoveredResults, result);

    return result;
  }

  Future<List<QueryRow>> _queryDirtyForeignEntriesForTypes({
    required Set<int> resourceTypeIriIds,
    required int sinceTimestamp,
    required Set<int> excludeIndexIriIds,
  }) async {
    final typeInClause = resourceTypeIriIds.join(',');
    final whereConditions = [
      'e.resource_type_iri_id IN ($typeInClause)',
      if (excludeIndexIriIds.isNotEmpty)
        'e.index_iri_id NOT IN (${excludeIndexIriIds.join(',')})',
      'e.our_physical_clock > ?',
    ];

    return customSelect(
      '''
      SELECT
        rt.iri as resource_type_iri,
        idx.iri as index_iri,
        shard.iri as shard_iri,
        res.iri as resource_iri,
        e.clock_hash as clock_hash
      FROM index_entries e
      JOIN sync_iris rt ON rt.id = e.resource_type_iri_id
      JOIN sync_iris idx ON idx.id = e.index_iri_id
      JOIN sync_iris shard ON shard.id = e.shard_iri
      JOIN sync_iris res ON res.id = e.resource_iri_id
      WHERE ${whereConditions.join(' AND ')}
      ''',
      variables: [Variable.withInt(sinceTimestamp)],
      readsFrom: {db.indexEntries, db.syncIris},
    ).get();
  }

  Future<List<QueryRow>> _queryUncoveredForeignEntriesForTypes({
    required Set<int> resourceTypeIriIds,
    required Set<int> excludeIndexIriIds,
  }) async {
    final typeInClause = resourceTypeIriIds.join(',');
    if (excludeIndexIriIds.isEmpty) {
      return customSelect(
        '''
        SELECT
          rt.iri as resource_type_iri,
          idx.iri as index_iri,
          shard.iri as shard_iri,
          res.iri as resource_iri,
          e.clock_hash as clock_hash
        FROM index_entries e
        JOIN sync_iris rt ON rt.id = e.resource_type_iri_id
        JOIN sync_iris idx ON idx.id = e.index_iri_id
        JOIN sync_iris shard ON shard.id = e.shard_iri
        JOIN sync_iris res ON res.id = e.resource_iri_id
        WHERE e.resource_type_iri_id IN ($typeInClause)
        ''',
        variables: [],
        readsFrom: {db.indexEntries, db.syncIris},
      ).get();
    }

    final excludeClause = excludeIndexIriIds.join(',');
    return customSelect(
      '''
      SELECT
        rt.iri as resource_type_iri,
        idx.iri as index_iri,
        shard.iri as shard_iri,
        res.iri as resource_iri,
        e.clock_hash as clock_hash
      FROM index_entries e
      JOIN sync_iris rt ON rt.id = e.resource_type_iri_id
      JOIN sync_iris idx ON idx.id = e.index_iri_id
      JOIN sync_iris shard ON shard.id = e.shard_iri
      JOIN sync_iris res ON res.id = e.resource_iri_id
      LEFT JOIN index_entries configured
        ON e.resource_iri_id = configured.resource_iri_id
        AND configured.index_iri_id IN ($excludeClause)
      WHERE e.resource_type_iri_id IN ($typeInClause)
        AND e.index_iri_id NOT IN ($excludeClause)
        AND configured.resource_iri_id IS NULL
      ''',
      variables: [],
      readsFrom: {db.indexEntries, db.syncIris},
    ).get();
  }

  void _groupResultsByType(
    List<QueryRow> results,
    Map<String, Map<String, Map<String, Map<String, String>>>> typeToIndex,
  ) {
    for (final row in results) {
      final resourceTypeIri = row.read<String>('resource_type_iri');
      final indexIri = row.read<String>('index_iri');
      final shardIri = row.read<String>('shard_iri');
      final resourceIri = row.read<String>('resource_iri');
      final clockHash = row.read<String>('clock_hash');
      typeToIndex
          .putIfAbsent(resourceTypeIri, () => {})
          .putIfAbsent(indexIri, () => {})
          .putIfAbsent(shardIri, () => {})[resourceIri] = clockHash;
    }
  }

  /// Get resource IRI IDs for index entries that have no corresponding document.
  ///
  /// Finds active (not deleted) index entries where no document exists in storage.
  /// This indicates incomplete storage state that's incompatible with dataset-based sync.
  ///
  /// Parameters:
  /// - [resourceTypeIriId]: Optional filter by resource type
  ///
  /// Returns: Set of resource IRI IDs that have index entries but no documents
  Future<Set<int>> getMissingDocumentResourceIriIds({
    int? resourceTypeIriId,
  }) async {
    final whereConditions = <String>[
      'e.is_deleted = 0', // Only active entries
    ];
    final variables = <Variable>[];

    if (resourceTypeIriId != null) {
      whereConditions.add('e.resource_type_iri_id = ?');
      variables.add(Variable.withInt(resourceTypeIriId));
    }

    final results = await customSelect(
      '''
      SELECT DISTINCT e.resource_iri_id
      FROM index_entries e
      LEFT JOIN sync_documents d ON d.document_iri_id = e.resource_iri_id
      WHERE ${whereConditions.join(' AND ')}
        AND d.id IS NULL
      ''',
      variables: variables,
      readsFrom: {db.indexEntries, db.syncDocuments},
    ).get();

    return results.map((row) => row.read<int>('resource_iri_id')).toSet();
  }

  // Note: Sync timestamps are now stored in SyncSettings table
  // using SyncSettingKeys constants. See DriftStorage helper methods.
}

/// Data Access Object for remote sync state management
///
/// Handles both RemoteSettings (remote configuration) and RemoteSyncState
/// (per-document sync state). Provides efficient remote ID lookup and caching.
@DriftAccessor(tables: [RemoteSettings, RemoteSyncState, SyncIris])
class RemoteSyncStateDao extends DatabaseAccessor<SyncDatabase>
    with _$RemoteSyncStateDaoMixin, IriBatchLoader {
  RemoteSyncStateDao(super.db);

  /// Get or create remote ID for a given remote URL
  ///
  /// Returns the integer ID for efficient foreign key references.
  /// Creates a new RemoteSettings entry if the remote id doesn't exist yet.
  Future<int> getOrCreateRemoteId(String remoteType, String remoteId) async {
    // Try to find existing remote
    final existing = await (select(db.remoteSettings)
          ..where((r) => r.remoteId.equals(remoteId)))
        .getSingleOrNull();

    if (existing != null) {
      return existing.id;
    }

    // Create new remote entry
    final now = DateTime.now().millisecondsSinceEpoch;
    return await into(db.remoteSettings).insert(
      RemoteSettingsCompanion.insert(
        remoteId: remoteId,
        remoteType: remoteType,
        createdAt: now,
      ),
    );
  }

  /// Get last sync timestamp for a remote
  Future<int> getRemoteLastSyncTimestamp(int remoteId) async {
    final remote = await (select(db.remoteSettings)
          ..where((r) => r.id.equals(remoteId)))
        .getSingleOrNull();

    return remote?.lastSyncTimestamp ?? 0;
  }

  /// Update last sync timestamp for a remote
  Future<void> updateRemoteLastSyncTimestamp(
      int remoteId, int timestamp) async {
    await (update(db.remoteSettings)..where((r) => r.id.equals(remoteId)))
        .write(RemoteSettingsCompanion(
      lastSyncTimestamp: Value(timestamp),
    ));
  }

  /// Get ETag for a document on a specific remote
  ///
  /// Returns null if no ETag is stored for this document/remote combination
  Future<String?> getETag({
    required int documentIriId,
    required int remoteId,
  }) async {
    final state = await (select(db.remoteSyncState)
          ..where((s) =>
              s.documentIriId.equals(documentIriId) &
              s.remoteId.equals(remoteId)))
        .getSingleOrNull();

    return state?.etag;
  }

  /// Get ETags for multiple documents on a specific remote.
  Future<Map<int, String?>> getETags({
    required Iterable<int> documentIriIds,
    required int remoteId,
  }) async {
    final ids = documentIriIds.toSet();
    if (ids.isEmpty) {
      return const {};
    }

    final rows = await (select(db.remoteSyncState)
          ..where(
              (s) => s.remoteId.equals(remoteId) & s.documentIriId.isIn(ids)))
        .get();

    final etagByDocumentId = <int, String?>{
      for (final row in rows) row.documentIriId: row.etag,
    };

    return {
      for (final id in ids) id: etagByDocumentId[id],
    };
  }

  /// Set ETag for a document on a specific remote
  ///
  /// Creates or updates the sync state entry
  Future<void> setETag({
    required int documentIriId,
    required int remoteId,
    required String etag,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;

    await into(db.remoteSyncState).insertOnConflictUpdate(
      RemoteSyncStateCompanion.insert(
        documentIriId: documentIriId,
        remoteId: remoteId,
        etag: Value(etag),
        lastSyncedAt: Value(now),
      ),
    );
  }

  /// Set ETags for multiple documents on a specific remote.
  Future<void> setETags({
    required int remoteId,
    required Map<int, String> etagsByDocumentIriId,
  }) async {
    if (etagsByDocumentIriId.isEmpty) {
      return;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    await batch((batch) {
      for (final entry in etagsByDocumentIriId.entries) {
        batch.insert(
          db.remoteSyncState,
          RemoteSyncStateCompanion.insert(
            documentIriId: entry.key,
            remoteId: remoteId,
            etag: Value(entry.value),
            lastSyncedAt: Value(now),
          ),
          mode: InsertMode.insertOrReplace,
        );
      }
    });
  }

  /// Clear ETag for a document on a specific remote
  ///
  /// Removes the entire sync state entry
  Future<void> clearETag({
    required int documentIriId,
    required int remoteId,
  }) async {
    await (delete(db.remoteSyncState)
          ..where((s) =>
              s.documentIriId.equals(documentIriId) &
              s.remoteId.equals(remoteId)))
        .go();
  }

  /// Clear all ETags for a specific remote
  ///
  /// Useful when changing remote configuration or resetting sync state
  Future<void> clearAllETagsForRemote(int remoteId) async {
    await (delete(db.remoteSyncState)
          ..where((s) => s.remoteId.equals(remoteId)))
        .go();
  }
}

/// Subscribed group index data with integer IRI IDs and fetch policy.
///
/// DriftStorage is responsible for resolving these IDs to [IriTerm] instances
/// via its LRU caches.
class SubscribedGroupIndexData {
  final int groupIndexIriId;
  final int indexedTypeIriId;
  final String rootResourceFetchPolicy;

  SubscribedGroupIndexData({
    required this.groupIndexIriId,
    required this.indexedTypeIriId,
    required this.rootResourceFetchPolicy,
  });
}

/// Page of index entries with pagination info (internal Drift representation)
class IndexEntriesPage {
  final List<IndexEntry> entries;
  final bool hasMore;
  final int? lastCursor;

  IndexEntriesPage({
    required this.entries,
    required this.hasMore,
    required this.lastCursor,
  });
}

/// Document with IRI for batch operations
class DocumentWithIri {
  final String iri;
  final SyncDocument document;

  DocumentWithIri({
    required this.iri,
    required this.document,
  });
}

class BatchDocumentSaveOperation {
  final int documentIriId;
  final int typeIriId;
  final Uint8List content;
  final int ourPhysicalClock;
  final int updatedAt;
  final int? ifMatchUpdatedAt;

  BatchDocumentSaveOperation({
    required this.documentIriId,
    required this.typeIriId,
    required this.content,
    required this.ourPhysicalClock,
    required this.updatedAt,
    required this.ifMatchUpdatedAt,
  });
}

class BatchIndexEntrySaveOperation {
  final int shardIriId;
  final int indexIriId;
  final int resourceIriId;
  final int resourceTypeIriId;
  final String clockHash;
  final Uint8List? headerProperties;
  final bool isDeleted;
  final bool isRemoteOnly;
  final int ourPhysicalClock;
  final int updatedAt;

  BatchIndexEntrySaveOperation({
    required this.shardIriId,
    required this.indexIriId,
    required this.resourceIriId,
    required this.resourceTypeIriId,
    required this.clockHash,
    required this.headerProperties,
    required this.isDeleted,
    this.isRemoteOnly = false,
    required this.ourPhysicalClock,
    required this.updatedAt,
  });
}

/// Shard membership for index documents.
///
/// Populated by [DocumentSaveService] whenever an [IdxFullIndex] or
/// [IdxGroupIndex] document is saved.  Enables Stage 1 to resolve shards
/// with a single DB query instead of parsing full RDF documents.
@TableIndex(name: 'idx_index_shards_index_iri', columns: {#indexIriId})
class IndexShards extends Table {
  @ReferenceName('indexIri')
  IntColumn get indexIriId => integer().references(SyncIris, #id)();

  @ReferenceName('shardIri')
  IntColumn get shardIriId => integer().references(SyncIris, #id)();

  @override
  Set<Column> get primaryKey => {shardIriId};

  @override
  bool get withoutRowId => true;
}

/// Main sync database class
@DriftDatabase(
  tables: [
    SyncIris,
    SyncDocuments,
    SyncPropertyChanges,
    SyncSettings,
    IndexEntries,
    GroupIndexSubscriptions,
    IndexInstanceSyncStates,
    IndexIriIdSetVersions,
    RemoteSettings,
    RemoteSyncState,
    IndexShards,
  ],
  daos: [SyncDocumentDao, SyncPropertyChangeDao, IndexDao, RemoteSyncStateDao],
)
class SyncDatabase extends _$SyncDatabase {
  /// Create database with custom QueryExecutor.
  ///
  /// Pure Dart constructor - works on all platforms including web workers.
  /// For Flutter apps, use factory from sync_database_flutter.dart instead.
  SyncDatabase.forExecutor(QueryExecutor executor) : super(executor);

  @override
  int get schemaVersion => 12;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (Migrator m) async {
          await m.createAll();

          // Create indices for performance
          await m.database.customStatement('''
        CREATE INDEX IF NOT EXISTS idx_sync_documents_iri
        ON sync_documents(document_iri_id);
      ''');

          // Composite index for type-specific cursor queries
          await m.database.customStatement('''
        CREATE INDEX IF NOT EXISTS idx_sync_documents_type_updated
        ON sync_documents(type_iri_id, updated_at);
      ''');

          await m.database.customStatement('''
        CREATE INDEX IF NOT EXISTS idx_sync_iris_iri
        ON sync_iris(iri);
      ''');

          await m.database.customStatement('''
        CREATE INDEX IF NOT EXISTS idx_property_changes_document
        ON sync_property_changes(document_id);
      ''');

          // Index management table indices
          await m.database.customStatement('''
        CREATE INDEX IF NOT EXISTS idx_index_entries_shard
        ON index_entries(shard_iri);
      ''');

          await m.database.customStatement('''
        CREATE INDEX IF NOT EXISTS idx_index_entries_resource
        ON index_entries(resource_iri_id);
      ''');

          await m.database.customStatement('''
        CREATE INDEX IF NOT EXISTS idx_index_entries_clock
        ON index_entries(our_physical_clock);
      ''');

          await m.database.customStatement('''
        CREATE INDEX IF NOT EXISTS idx_index_entries_deleted
        ON index_entries(is_deleted);
      ''');

          await m.database.customStatement('''
        CREATE INDEX IF NOT EXISTS idx_index_entries_shard_active
        ON index_entries(shard_iri)
        WHERE is_deleted = 0;
      ''');

          await m.database.customStatement('''
        CREATE INDEX IF NOT EXISTS idx_index_entries_resource_type
        ON index_entries(resource_type_iri_id);
      ''');

          await m.database.customStatement('''
        CREATE INDEX IF NOT EXISTS idx_index_entries_index_updated
        ON index_entries(index_iri_id, updated_at) 
        WHERE is_deleted = 0;
      ''');

          await m.database.customStatement('''
        CREATE INDEX IF NOT EXISTS idx_index_instance_sync_states_remote
        ON index_instance_sync_states(remote_setting_id);
      ''');

          await m.database.customStatement('''
        CREATE INDEX IF NOT EXISTS idx_index_shards_index_iri
        ON index_shards(index_iri_id);
      ''');
        },
        onUpgrade: (Migrator m, int from, int to) async {
          if (from < 2) {
            // Add typeIriId column to existing documents table
            await m.database.customStatement('''
              ALTER TABLE sync_documents ADD COLUMN type_iri_id INTEGER REFERENCES sync_iris(id);
            ''');

            // Create the composite index
            await m.database.customStatement('''
              CREATE INDEX IF NOT EXISTS idx_sync_documents_type_updated
              ON sync_documents(type_iri_id, updated_at);
            ''');
          }
          if (from < 3) {
            // Create settings table
            await m.createTable(syncSettings);
          }
          if (from < 4) {
            // Create index management tables with integer timestamps
            await m.createTable(indexEntries);
            await m.createTable(groupIndexSubscriptions);
            await m.createTable(indexIriIdSetVersions);

            // Create performance indices
            await m.database.customStatement('''
              CREATE INDEX IF NOT EXISTS idx_index_entries_shard
              ON index_entries(shard_iri);
            ''');

            await m.database.customStatement('''
              CREATE INDEX IF NOT EXISTS idx_index_entries_resource
              ON index_entries(resource_iri_id);
            ''');

            await m.database.customStatement('''
              CREATE INDEX IF NOT EXISTS idx_index_entries_clock
              ON index_entries(our_physical_clock);
            ''');

            await m.database.customStatement('''
              CREATE INDEX IF NOT EXISTS idx_index_entries_deleted
              ON index_entries(is_deleted);
            ''');

            await m.database.customStatement('''
              CREATE INDEX IF NOT EXISTS idx_index_entries_index_updated
              ON index_entries(index_iri_id, updated_at) 
              WHERE is_deleted = 0;
            ''');
          }
          if (from < 5) {
            // Create remote settings and remote sync state tables
            await m.createTable(remoteSettings);
            await m.createTable(remoteSyncState);

            // Create index for efficient lookup by remote
            await m.database.customStatement('''
              CREATE INDEX IF NOT EXISTS idx_remote_sync_state_remote
              ON remote_sync_state(remote_id);
            ''');

            // Create index for remote URL lookups
            await m.database.customStatement('''
              CREATE INDEX IF NOT EXISTS idx_remote_settings_url
              ON remote_settings(remote_url);
            ''');
          }
          if (from < 6) {
            // Add resource_type_iri_id column to index_entries table
            await m.database.customStatement('''
              ALTER TABLE index_entries 
              ADD COLUMN resource_type_iri_id INTEGER REFERENCES sync_iris(id);
            ''');

            // Create index for efficient resource type filtering
            await m.database.customStatement('''
              CREATE INDEX IF NOT EXISTS idx_index_entries_resource_type
              ON index_entries(resource_type_iri_id);
            ''');
          }
          if (from < 7) {
            await m.createTable(indexInstanceSyncStates);

            await m.database.customStatement('''
              CREATE INDEX IF NOT EXISTS idx_index_instance_sync_states_remote
              ON index_instance_sync_states(remote_setting_id);
            ''');
          }
          if (from < 8) {
            await m.database.customStatement('''
              CREATE INDEX IF NOT EXISTS idx_index_entries_shard_active
              ON index_entries(shard_iri)
              WHERE is_deleted = 0;
            ''');
          }
          if (from < 9) {
            // Migrate document content from TEXT (turtle) to BLOB (jelly binary).
            // SQLite doesn't support ALTER COLUMN, so we recreate the tables.
            await _migrateDocumentsToBlob(m);
            await _migrateIndexEntriesToBlob(m);
          }
          if (from < 10) {
            await m.createTable(indexShards);
            await m.database.customStatement('''
              CREATE INDEX IF NOT EXISTS idx_index_shards_index_iri
              ON index_shards(index_iri_id);
            ''');
          }
          if (from < 11) {
            // Add is_remote_only placeholder flag to index_entries.
            await m.database.customStatement(
              'ALTER TABLE index_entries ADD COLUMN is_remote_only INTEGER NOT NULL DEFAULT 0',
            );
          }
          if (from < 12) {
            // Backfill index_shards from existing index_entries data.
            // v10 created the table but didn't populate it from pre-existing entries.
            await m.database.customStatement('''
              INSERT OR IGNORE INTO index_shards (shard_iri_id, index_iri_id)
              SELECT DISTINCT shard_iri, index_iri_id
              FROM index_entries
              WHERE is_deleted = 0
            ''');
          }
        },
      );

  /// Migrate sync_documents.document_content from TEXT (turtle) to BLOB (jelly).
  Future<void> _migrateDocumentsToBlob(Migrator m) async {
    final db = m.database;

    // Step 1: Read all rows + their document IRIs in a single query (no write lock yet).
    final rows = await db.customSelect('''
      SELECT d.id, d.document_content, d.document_iri_id, d.type_iri_id,
             d.our_physical_clock, d.updated_at, i.iri AS document_iri
      FROM sync_documents d
      JOIN sync_iris i ON d.document_iri_id = i.id
    ''').get();

    // Step 2: Re-encode all content synchronously in memory (CPU, no DB interaction).
    final turtleDecoder = TurtleCodec();
    final reencoded = rows.map((row) {
      final text = row.read<String>('document_content');
      final documentIri = row.read<String>('document_iri');
      final graph = turtleDecoder.decode(text, documentUrl: documentIri);
      final bytes = jellyGraph.encoder.convert(graph);
      return (
        id: row.read<int>('id'),
        documentIriId: row.read<int>('document_iri_id'),
        typeIriId: row.read<int?>('type_iri_id'),
        ourPhysicalClock: row.read<int>('our_physical_clock'),
        updatedAt: row.read<int>('updated_at'),
        bytes: bytes,
      );
    }).toList();

    // Step 3: Recreate table atomically inside a SAVEPOINT.
    //   - SAVEPOINT works correctly whether or not we're already in a transaction.
    //   - DROP TABLE IF EXISTS sync_documents_new handles residue from a previous
    //     failed migration attempt (avoids "duplicate column" on retry).
    await db.customStatement('SAVEPOINT mig_v9_documents;');
    try {
      await db.customStatement('DROP TABLE IF EXISTS sync_documents_new;');
      await db.customStatement('''
        CREATE TABLE sync_documents_new (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          document_iri_id INTEGER NOT NULL UNIQUE REFERENCES sync_iris(id),
          type_iri_id INTEGER REFERENCES sync_iris(id),
          document_content BLOB NOT NULL,
          our_physical_clock INTEGER NOT NULL,
          updated_at INTEGER NOT NULL
        );
      ''');

      for (final row in reencoded) {
        await db.customStatement(
          'INSERT INTO sync_documents_new'
          ' (id, document_iri_id, type_iri_id, document_content, our_physical_clock, updated_at)'
          ' VALUES (?, ?, ?, ?, ?, ?)',
          [
            row.id,
            row.documentIriId,
            row.typeIriId,
            row.bytes,
            row.ourPhysicalClock,
            row.updatedAt,
          ],
        );
      }

      await db.customStatement('DROP TABLE sync_documents;');
      await db.customStatement(
          'ALTER TABLE sync_documents_new RENAME TO sync_documents;');
      await db.customStatement('''
        CREATE INDEX IF NOT EXISTS idx_sync_documents_iri
        ON sync_documents(document_iri_id);
      ''');
      await db.customStatement('''
        CREATE INDEX IF NOT EXISTS idx_sync_documents_type_updated
        ON sync_documents(type_iri_id, updated_at);
      ''');

      await db.customStatement('RELEASE mig_v9_documents;');
    } catch (e) {
      await db.customStatement('ROLLBACK TO mig_v9_documents;');
      await db.customStatement('RELEASE mig_v9_documents;');
      rethrow;
    }
  }

  /// Migrate index_entries.header_properties from TEXT (turtle) to BLOB (jelly).
  Future<void> _migrateIndexEntriesToBlob(Migrator m) async {
    final db = m.database;

    // Step 1: Read all rows with non-null header_properties (no write lock yet).
    final allRows = await db.customSelect('''
      SELECT shard_iri, index_iri_id, resource_iri_id, resource_type_iri_id,
             clock_hash, header_properties, updated_at, our_physical_clock, is_deleted
      FROM index_entries
    ''').get();

    // Step 2: Re-encode non-null header_properties synchronously in memory.
    final turtleDecoder = TurtleCodec();
    final reencoded = allRows.map((row) {
      final turtleText = row.read<String?>('header_properties');
      final Uint8List? bytes;
      if (turtleText != null) {
        final graph = turtleDecoder.decode(turtleText);
        bytes = jellyGraph.encoder.convert(graph);
      } else {
        bytes = null;
      }
      return (
        shardIri: row.read<int>('shard_iri'),
        indexIriId: row.read<int>('index_iri_id'),
        resourceIriId: row.read<int>('resource_iri_id'),
        resourceTypeIriId: row.read<int?>('resource_type_iri_id'),
        clockHash: row.read<String>('clock_hash'),
        headerProperties: bytes,
        updatedAt: row.read<int>('updated_at'),
        ourPhysicalClock: row.read<int>('our_physical_clock'),
        isDeleted: row.read<int>('is_deleted'),
      );
    }).toList();

    // Step 3: Recreate table atomically inside a SAVEPOINT.
    await db.customStatement('SAVEPOINT mig_v9_index_entries;');
    try {
      await db.customStatement('DROP TABLE IF EXISTS index_entries_new;');
      await db.customStatement('''
        CREATE TABLE index_entries_new (
          shard_iri INTEGER NOT NULL REFERENCES sync_iris(id),
          index_iri_id INTEGER NOT NULL REFERENCES sync_iris(id),
          resource_iri_id INTEGER NOT NULL REFERENCES sync_iris(id),
          resource_type_iri_id INTEGER REFERENCES sync_iris(id),
          clock_hash TEXT NOT NULL,
          header_properties BLOB,
          updated_at INTEGER NOT NULL,
          our_physical_clock INTEGER NOT NULL,
          is_deleted INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (shard_iri, resource_iri_id)
        );
      ''');

      for (final row in reencoded) {
        await db.customStatement(
          'INSERT INTO index_entries_new'
          ' (shard_iri, index_iri_id, resource_iri_id, resource_type_iri_id,'
          '  clock_hash, header_properties, updated_at, our_physical_clock, is_deleted)'
          ' VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
          [
            row.shardIri,
            row.indexIriId,
            row.resourceIriId,
            row.resourceTypeIriId,
            row.clockHash,
            row.headerProperties,
            row.updatedAt,
            row.ourPhysicalClock,
            row.isDeleted,
          ],
        );
      }

      await db.customStatement('DROP TABLE index_entries;');
      await db.customStatement(
          'ALTER TABLE index_entries_new RENAME TO index_entries;');
      await db.customStatement('''
        CREATE INDEX IF NOT EXISTS idx_index_entries_shard
        ON index_entries(shard_iri);
      ''');
      await db.customStatement('''
        CREATE INDEX IF NOT EXISTS idx_index_entries_resource
        ON index_entries(resource_iri_id);
      ''');
      await db.customStatement('''
        CREATE INDEX IF NOT EXISTS idx_index_entries_clock
        ON index_entries(our_physical_clock);
      ''');
      await db.customStatement('''
        CREATE INDEX IF NOT EXISTS idx_index_entries_deleted
        ON index_entries(is_deleted);
      ''');
      await db.customStatement('''
        CREATE INDEX IF NOT EXISTS idx_index_entries_shard_active
        ON index_entries(shard_iri)
        WHERE is_deleted = 0;
      ''');
      await db.customStatement('''
        CREATE INDEX IF NOT EXISTS idx_index_entries_resource_type
        ON index_entries(resource_type_iri_id);
      ''');
      await db.customStatement('''
        CREATE INDEX IF NOT EXISTS idx_index_entries_index_updated
        ON index_entries(index_iri_id, updated_at)
        WHERE is_deleted = 0;
      ''');

      await db.customStatement('RELEASE mig_v9_index_entries;');
    } catch (e) {
      await db.customStatement('ROLLBACK TO mig_v9_index_entries;');
      await db.customStatement('RELEASE mig_v9_index_entries;');
      rethrow;
    }
  }
}
