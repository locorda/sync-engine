/// Drift-based implementation of Storage interface.
library;

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:locorda_core/locorda_core.dart' as core;
import 'package:locorda_core/src/util/lru_cache.dart';
//import 'package:locorda_core/src/storage/storage_interface.dart' as storage;
import 'rdf/rdf_extensions.dart';
import 'package:locorda_rdf_core/core.dart';

import 'drift_options.dart';
import 'sync_database.dart';
import 'sync_database_impl_flutter.dart'
    if (dart.library.html) 'sync_database_impl_web.dart';

/// Drift-based implementation of the Storage interface.
///
/// Provides cross-platform SQLite storage for RDF documents, CRDT metadata,
/// and property-level change tracking using the Drift ORM.
class DriftStorage implements core.Storage, core.TransactionalStorage {
  final SyncDocumentDao documentDao;
  final SyncPropertyChangeDao propertyChangeDao;
  final IndexDao indexDao;
  final RemoteSyncStateDao remoteSyncStateDao;
  final SyncDatabase _database;
  final RdfGraphCodec _codec;
  final IriTermFactory _iriTermFactory;
  final core.Perflog _perflog;
  final LRUCache<String, int> _iriIdCache;
  final LRUCache<String, int> _shardIriIdCache;

  static const int _iriIdCacheSize = 20000;
  static const int _shardIriIdCacheSize = 50000;

  bool _initialized = false;
  bool _didLogActiveShardQueryPlan = false;

  DriftStorage._({
    required this.documentDao,
    required this.propertyChangeDao,
    required this.indexDao,
    required this.remoteSyncStateDao,
    required SyncDatabase database,
    required core.Perflog perflog,
    IriTermFactory iriTermFactory = IriTerm.validated,
  })  : _database = database,
        _iriTermFactory = iriTermFactory,
        _perflog = perflog.create('Storage', 'DriftStorage'),
        _iriIdCache = LRUCache<String, int>(maxCacheSize: _iriIdCacheSize),
        _shardIriIdCache =
            LRUCache<String, int>(maxCacheSize: _shardIriIdCacheSize),
        _codec = TurtleCodec(iriTermFactory: iriTermFactory);

  /// Create DriftStorage with automatic platform detection.
  ///
  /// Uses conditional imports to select the right implementation:
  /// - Native platforms: Uses drift_flutter with sqlite3_flutter_libs
  /// - Web: Uses drift/wasm with WasmDatabase
  ///
  /// Example:
  /// ```dart
  /// final storage = await DriftStorage.create(
  ///   web: LocordaDriftWebOptions(
  ///     sqlite3Wasm: Uri.parse('sqlite3.wasm'),
  ///     driftWorker: Uri.parse('drift_worker.js'),
  ///   ),
  /// );
  /// ```
  static Future<DriftStorage> create({
    LocordaDriftWebOptions? web,
    LocordaDriftNativeOptions? native,
    required core.Perflog perflog,
    IriTermFactory iriTermFactory = IriTerm.validated,
  }) async {
    final database = await SyncDatabaseImpl.create(web: web, native: native);

    return DriftStorage._(
        documentDao: database.syncDocumentDao,
        propertyChangeDao: database.syncPropertyChangeDao,
        indexDao: database.indexDao,
        remoteSyncStateDao: database.remoteSyncStateDao,
        database: database,
        perflog: perflog,
        iriTermFactory: iriTermFactory);
  }

  /// Create DriftStorage with custom database instance (for testing)
  factory DriftStorage.withDatabase(
    SyncDatabase database, {
    core.Perflog perflog = core.Perflog.disabled,
    IriTermFactory iriTermFactory = IriTerm.validated,
  }) {
    return DriftStorage._(
      documentDao: database.syncDocumentDao,
      propertyChangeDao: database.syncPropertyChangeDao,
      indexDao: database.indexDao,
      remoteSyncStateDao: database.remoteSyncStateDao,
      database: database,
      perflog: perflog,
      iriTermFactory: iriTermFactory,
    );
  }

  @override
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
  }

  @override
  Future<void> close() async {
    if (_initialized) {
      await _database.close();
      _initialized = false;
    }
  }

  @override
  Future<T> inTransaction<T>(Future<T> Function() action) {
    return _database.transaction(action);
  }

  /// Throws [ConcurrentUpdateException] on optimistic lock failure.
  @override
  Future<core.SaveDocumentResult> saveDocument(
      IriTerm documentIri,
      IriTerm typeIri,
      RdfGraph document,
      core.DocumentMetadata metadata,
      List<core.PropertyChange> changes,
      {int? ifMatchUpdatedAt}) async {
    final results = await saveDocuments([
      core.SaveDocumentRequest(
        documentIri: documentIri,
        typeIri: typeIri,
        document: document,
        metadata: metadata,
        changes: changes,
        ifMatchUpdatedAt: ifMatchUpdatedAt,
      ),
    ]);
    return results.single;
  }

  @override
  Future<List<core.SaveDocumentResult>> saveDocuments(
      Iterable<core.SaveDocumentRequest> requests) async {
    final requestList = requests.toList(growable: false);
    if (requestList.isEmpty) {
      return const [];
    }

    final documentIriValues = requestList
        .map((request) => request.documentIri.value)
        .toList(growable: false);
    final typeIriValues = requestList
        .map((request) => request.typeIri.value)
        .toList(growable: false);

    final allIriValues = {
      ...documentIriValues,
      ...typeIriValues,
    };

    // Pre-encode all documents BEFORE the transaction —
    // pure CPU work that shouldn't hold a DB lock
    final encodedContents = await _perflog.measure(
      'saveDocuments.encode',
      () async => requestList
          .map((r) => _codec.encode(r.document, baseUri: r.documentIri.value))
          .toList(growable: false),
      args: ['count=${requestList.length}'],
      minDurationMs: 5,
    );

    return _database.transaction(() async {
      final iriIdByValue = await _perflog.measure(
        'saveDocuments.tx.iriLookup',
        () => documentDao.getOrCreateIriIdsBatch(allIriValues),
        args: ['count=${allIriValues.length}'],
        minDurationMs: 5,
      );

      // Populate _iriIdCache so subsequent saveIndexEntries gets cache hits
      for (final entry in iriIdByValue.entries) {
        _iriIdCache[entry.key] = entry.value;
      }

      final documentIriIds = documentIriValues
          .map((iri) => iriIdByValue[iri]!)
          .toList(growable: false);
      final typeIriIds = typeIriValues
          .map((iri) => iriIdByValue[iri]!)
          .toList(growable: false);

      final maxUpdatedAtByTypeId = await _perflog.measure(
        'saveDocuments.tx.maxUpdatedAt',
        () => documentDao.getMaxUpdatedAtForTypeIds(typeIriIds),
        args: ['typeCount=${typeIriIds.toSet().length}'],
        minDurationMs: 5,
      );
      final runningMaxUpdatedAtByTypeId = <int, int?>{
        for (final entry in maxUpdatedAtByTypeId.entries)
          entry.key: entry.value,
      };

      final results = <core.SaveDocumentResult>[];
      final operations = <BatchDocumentSaveOperation>[];
      final changesByDocumentIriId = <int, List<core.PropertyChange>>{};

      for (var index = 0; index < requestList.length; index++) {
        final request = requestList[index];
        final typeIriId = typeIriIds[index];
        final documentIriId = documentIriIds[index];
        final previousTimestamp = runningMaxUpdatedAtByTypeId[typeIriId];

        if (previousTimestamp != null &&
            request.metadata.updatedAt < previousTimestamp) {
          throw ArgumentError(
              'New document updatedAt (${request.metadata.updatedAt}) must be greater than (or equal to) '
              'existing max updatedAt ($previousTimestamp) for document ${request.documentIri.debug} of type ${request.typeIri.value}');
        }

        operations.add(
          BatchDocumentSaveOperation(
            documentIriId: documentIriId,
            typeIriId: typeIriId,
            content: encodedContents[index],
            ourPhysicalClock: request.metadata.ourPhysicalClock,
            updatedAt: request.metadata.updatedAt,
            ifMatchUpdatedAt: request.ifMatchUpdatedAt,
          ),
        );

        if (request.changes.isNotEmpty) {
          changesByDocumentIriId[documentIriId] = request.changes;
        }

        final nextMax = previousTimestamp == null
            ? request.metadata.updatedAt
            : (request.metadata.updatedAt > previousTimestamp
                ? request.metadata.updatedAt
                : previousTimestamp);
        runningMaxUpdatedAtByTypeId[typeIriId] = nextMax;

        results.add(
          core.SaveDocumentResult(
            previousCursor: previousTimestamp?.toString(),
            currentCursor: request.metadata.updatedAt.toString(),
          ),
        );
      }

      await _perflog.measure(
        'saveDocuments.tx.batchSave',
        () => documentDao.saveDocumentsBatch(operations),
        args: ['count=${operations.length}'],
        minDurationMs: 5,
      );

      if (changesByDocumentIriId.isNotEmpty) {
        await _perflog.measure(
          'saveDocuments.tx.propertyChanges',
          () async {
            final persistedByDocumentIriId = await documentDao
                .getDocumentsByDocumentIriIds(changesByDocumentIriId.keys);
            final changesByDocumentId = <int, List<core.PropertyChange>>{};

            for (final entry in changesByDocumentIriId.entries) {
              final persisted = persistedByDocumentIriId[entry.key];
              if (persisted == null) {
                throw StateError(
                    'Missing persisted document after batch save for documentIriId=${entry.key}.');
              }
              changesByDocumentId[persisted.id] = entry.value;
            }

            await propertyChangeDao
                .recordPropertyChangesForDocumentsBatch(changesByDocumentId);
          },
          args: ['count=${changesByDocumentIriId.length}'],
          minDurationMs: 5,
        );
      }

      return results;
    });
  }

  @override
  Future<core.StoredDocument?> getDocument(
    IriTerm documentIri, {
    int? ifChangedSincePhysicalClock,
  }) async {
    final document = await documentDao.getDocument(
      documentIri.value,
      ifChangedSincePhysicalClock: ifChangedSincePhysicalClock,
    );
    if (document == null) return null;

    // Parse RDF content
    final graph =
        _codec.decode(document.documentContent, documentUrl: documentIri.value);

    return core.StoredDocument(
      documentIri: documentIri,
      document: graph,
      metadata: core.DocumentMetadata(
        ourPhysicalClock: document.ourPhysicalClock,
        updatedAt: document.updatedAt,
      ),
    );
  }

  @override
  Future<Map<IriTerm, core.StoredDocument?>> getDocumentsByIri(
    Iterable<IriTerm> documentIris, {
    int? ifChangedSincePhysicalClock,
  }) async {
    final iris = documentIris.toList(growable: false);
    if (iris.isEmpty) {
      return const {};
    }

    final documents = await documentDao.getDocumentsByIri(
      iris.map((iri) => iri.value),
      ifChangedSincePhysicalClock: ifChangedSincePhysicalClock,
    );

    final byIri = {
      for (final document in documents) document.iri: document.document,
    };

    final result = <IriTerm, core.StoredDocument?>{};
    for (final documentIri in iris) {
      final document = byIri[documentIri.value];
      if (document == null) {
        result[documentIri] = null;
        continue;
      }

      final graph = _codec.decode(document.documentContent,
          documentUrl: documentIri.value);

      result[documentIri] = core.StoredDocument(
        documentIri: documentIri,
        document: graph,
        metadata: core.DocumentMetadata(
          ourPhysicalClock: document.ourPhysicalClock,
          updatedAt: document.updatedAt,
        ),
      );
    }

    return result;
  }

  @override
  Future<List<core.PropertyChange>> getPropertyChanges(IriTerm documentIri,
      {int? sinceLogicalClock}) async {
    final documentId = await documentDao.getDocumentId(documentIri.value);
    if (documentId == null) return [];

    final changes = await propertyChangeDao.getPropertyChanges(
      documentId,
      sinceLogicalClock: sinceLogicalClock,
    );

    return changes
        .map((change) => core.PropertyChange(
              resourceIri: _iriTermFactory(change.resourceIri),
              propertyIri: _iriTermFactory(change.propertyIri),
              changedAtMs: change.changedAtMs,
              changeLogicalClock: change.changeLogicalClock,
              isFrameworkProperty: change.isFrameworkProperty,
            ))
        .toList();
  }

  @override
  Future<core.DocumentsResult> getDocumentsModifiedSince(
      IriTerm typeIri, String? minCursor,
      {required int limit}) async {
    final documents = await documentDao
        .getDocumentsModifiedSince(typeIri.value, minCursor, limit: limit);
    final storedDocuments = _convertToStoredDocuments(documents);

    // currentCursor: last document's timestamp, or minCursor if no documents found
    // This ensures the cursor never goes backwards
    final currentCursor = storedDocuments.isNotEmpty
        ? storedDocuments.last.metadata.updatedAt.toString()
        : minCursor;

    // hasNext: true if we got a full batch (might be more data available)
    final hasNext = documents.length >= limit;

    return core.DocumentsResult(
      documents: storedDocuments,
      currentCursor: currentCursor,
      hasNext: hasNext,
    );
  }

  @override
  Future<core.DocumentsResult> getDocumentsChangedByUsSince(
      IriTerm typeIri, String? minCursor,
      {required int limit}) async {
    final documents = await documentDao
        .getDocumentsChangedByUsSince(typeIri.value, minCursor, limit: limit);
    final storedDocuments = _convertToStoredDocuments(documents);

    // currentCursor: last document's timestamp, or minCursor if no documents found
    // This ensures the cursor never goes backwards
    final currentCursor = storedDocuments.isNotEmpty
        ? storedDocuments.last.metadata.ourPhysicalClock.toString()
        : minCursor;

    // hasNext: true if we got a full batch (might be more data available)
    final hasNext = documents.length >= limit;

    return core.DocumentsResult(
      documents: storedDocuments,
      currentCursor: currentCursor,
      hasNext: hasNext,
    );
  }

  @override
  Stream<core.DocumentsResult> watchDocumentsModifiedSince(
      IriTerm typeIri, String? minCursor) {
    return documentDao
        .watchDocumentsModifiedSince(typeIri.value, minCursor)
        .map((documents) {
      final storedDocuments = _convertToStoredDocuments(documents);

      // For watch streams: currentCursor is the latest data, or minCursor if no docs
      // hasNext is always false for streams (they don't paginate)
      final cursor = storedDocuments.isNotEmpty
          ? storedDocuments.last.metadata.updatedAt.toString()
          : minCursor;

      return core.DocumentsResult(
        documents: storedDocuments,
        currentCursor: cursor,
        hasNext: false,
      );
    });
  }

  @override
  Stream<core.DocumentsResult> watchDocumentsChangedByUsSince(
      IriTerm typeIri, String? minCursor) async* {
    await for (final documents in documentDao.watchDocumentsChangedByUsSince(
        typeIri.value, minCursor)) {
      final storedDocuments = _convertToStoredDocuments(documents);

      // For watch streams: currentCursor is the latest data, or minCursor if no docs
      // hasNext is always false for streams (they don't paginate)
      final cursor = storedDocuments.isNotEmpty
          ? storedDocuments.last.metadata.ourPhysicalClock.toString()
          : minCursor;

      yield core.DocumentsResult(
        documents: storedDocuments,
        currentCursor: cursor,
        hasNext: false,
      );
    }
  }

  @override
  Future<Map<String, String>> getSettings(Iterable<String> keys) async {
    if (keys.isEmpty) return {};

    final results = await (_database.select(_database.syncSettings)
          ..where((s) => s.key.isIn(keys.toList())))
        .get();

    return {for (final setting in results) setting.key: setting.value};
  }

  @override
  Future<void> setSetting(String key, String value) async {
    await _database
        .into(_database.syncSettings)
        .insertOnConflictUpdate(SyncSettingsCompanion.insert(
          key: key,
          value: value,
        ));
  }

  @override
  Future<void> warmupIriIds(Iterable<IriTerm> iris) async {
    final iriValues = iris.map((iri) => iri.value).toSet();
    if (iriValues.isEmpty) {
      return;
    }

    final resolveResult = await _perflog.measure(
      'storage.iri.warmup',
      () => indexDao.getOrCreateIriIdsBatchWithStats(iriValues),
      args: ['requestCount=${iriValues.length}'],
      resultArgsBuilder: (stats) => [
        'existingCount=${stats.existingCount}',
        'createdCount=${stats.createdCount}',
      ],
      minDurationMs: 5,
    );

    for (final entry in resolveResult.ids.entries) {
      _iriIdCache[entry.key] = entry.value;
      _shardIriIdCache[entry.key] = entry.value;
    }
  }

  // ========================================================================
  // Index Management
  // ========================================================================

  /// Internal helper: Get or create IRI ID from SyncIris table
  /// IndexDao has IriBatchLoader mixin which provides these methods
  Future<int> _getOrCreateIriId(String iri) async {
    final result = await _getOrCreateIriIdsMap([iri]);
    return result[iri]!;
  }

  /// Internal helper: Batch get IRI IDs

  Future<Set<int>> _getOrCreateIriIds(Iterable<String> iris) async {
    return (await _getOrCreateIriIdsMap(iris)).values.toSet();
  }

  Future<Map<String, int>> _getOrCreateIriIdsMap(Iterable<String> iris) async {
    final uniqueIris = iris.toSet();
    if (uniqueIris.isEmpty) {
      return const {};
    }

    final result = <String, int>{};
    final misses = <String>{};

    for (final iri in uniqueIris) {
      final cached = _iriIdCache[iri];
      if (cached != null) {
        result[iri] = cached;
      } else {
        misses.add(iri);
      }
    }

    if (misses.isNotEmpty) {
      final resolveResult = await _perflog.measure(
        'storage.iri.getOrCreateBatch',
        () => indexDao.getOrCreateIriIdsBatchWithStats(misses),
        args: ['requestCount=${misses.length}'],
        resultArgsBuilder: (stats) => [
          'existingCount=${stats.existingCount}',
          'createdCount=${stats.createdCount}',
        ],
        minDurationMs: 5,
      );
      final loaded = resolveResult.ids;
      for (final entry in loaded.entries) {
        _iriIdCache[entry.key] = entry.value;
      }
      result.addAll(loaded);
    }

    final hitCount = result.length - misses.length;
    if (hitCount > 0 || misses.isNotEmpty) {
      _perflog.measure(
        'storage.iri.cacheStats',
        () async => null,
        args: [
          'requestCount=${uniqueIris.length}',
          'cacheHitCount=$hitCount',
          'cacheMissCount=${misses.length}',
        ],
        minDurationMs: 0,
      );
    }

    return result;
  }

  Future<({int shardIriId, bool fromShardCache})> _resolveShardIriId(
      IriTerm shardIri) async {
    final shardIriValue = shardIri.value;
    final cachedShardId = _shardIriIdCache[shardIriValue];
    if (cachedShardId != null) {
      _perflog.measure(
        'storage.iri.shard.cacheStats',
        () async => null,
        args: const [
          'requestCount=1',
          'cacheHitCount=1',
          'cacheMissCount=0',
        ],
        minDurationMs: 0,
      );
      return (shardIriId: cachedShardId, fromShardCache: true);
    }

    final resolveResult = await _perflog.measure(
      'storage.iri.shard.getOrCreateBatch',
      () => indexDao.getOrCreateIriIdsBatchWithStats([shardIriValue]),
      args: const ['requestCount=1'],
      resultArgsBuilder: (stats) => [
        'existingCount=${stats.existingCount}',
        'createdCount=${stats.createdCount}',
      ],
      minDurationMs: 5,
    );

    final shardIriId = resolveResult.ids[shardIriValue]!;
    _shardIriIdCache[shardIriValue] = shardIriId;
    _iriIdCache[shardIriValue] = shardIriId;

    _perflog.measure(
      'storage.iri.shard.cacheStats',
      () async => null,
      args: const [
        'requestCount=1',
        'cacheHitCount=0',
        'cacheMissCount=1',
      ],
      minDurationMs: 0,
    );

    return (shardIriId: shardIriId, fromShardCache: false);
  }

  Future<void> _logActiveShardQueryPlanOnce(int shardIriId) async {
    if (_didLogActiveShardQueryPlan) {
      return;
    }
    _didLogActiveShardQueryPlan = true;

    try {
      final rows = await _database.customSelect(
        '''
      EXPLAIN QUERY PLAN
      SELECT e.resource_iri_id
      FROM index_entries e
      JOIN sync_iris i ON i.id = e.resource_iri_id
      WHERE e.shard_iri = ? AND e.is_deleted = 0
      ''',
        variables: [Variable.withInt(shardIriId)],
      ).get();

      final planDetails = rows
          .map((row) => row.data['detail']?.toString() ?? 'unknown')
          .join(' || ');

      _perflog.measure(
        'storage.getActiveIndexEntriesForShard.queryPlan',
        () async => null,
        args: [
          'shardIriId=$shardIriId',
          'plan=$planDetails',
        ],
        minDurationMs: 0,
      );
    } catch (_) {
      _didLogActiveShardQueryPlan = false;
      rethrow;
    }
  }

  Future<int> _measureDbProbeMs() async {
    final stopwatch = Stopwatch()..start();
    await _database.customSelect('SELECT 1').getSingle();
    stopwatch.stop();
    return stopwatch.elapsedMilliseconds;
  }

  /// Internal helper: Batch get IRIs from IDs
  Future<Map<int, String>> _getIris(Set<int> ids) async {
    return await indexDao.getIrisBatch(ids);
  }

  @override
  Future<core.IndexEntriesPage> getIndexEntries({
    required Iterable<IriTerm> indexIris,
    int? cursorTimestamp,
    int limit = 100,
  }) async {
    // Translate index IRIs to IDs internally
    final indexIds = await _getOrCreateIriIds(
      indexIris.map((iri) => iri.value),
    );

    // Query directly by index IDs
    final page = await indexDao.getIndexEntries(
      indexIds: indexIds,
      cursorTimestamp: cursorTimestamp,
      limit: limit,
    );

    return core.IndexEntriesPage(
      entries: page.entries
          .map((e) => core.IndexEntryWithIri(
                resourceIri: _iriTermFactory(e.resourceIri),
                clockHash: e.entry.clockHash,
                headerProperties: e.entry.headerProperties,
                updatedAt: e.entry.updatedAt,
                isDeleted: e.entry.isDeleted,
                ourPhysicalClock: e.entry.ourPhysicalClock,
              ))
          .toList(),
      hasMore: page.hasMore,
      lastCursor: page.lastCursor,
    );
  }

  @override
  Stream<List<core.IndexEntryWithIri>> watchIndexEntries({
    required Iterable<IriTerm> indexIris,
    int? cursorTimestamp,
  }) async* {
    // Translate index IRIs to IDs internally
    final indexIds = await _getOrCreateIriIds(
      indexIris.map((iri) => iri.value),
    );

    // Watch using internal IDs
    yield* indexDao
        .watchIndexEntries(
          indexIds: indexIds,
          cursorTimestamp: cursorTimestamp,
        )
        .map((entries) => entries
            .map((e) => core.IndexEntryWithIri(
                  resourceIri: _iriTermFactory(e.resourceIri),
                  clockHash: e.entry.clockHash,
                  headerProperties: e.entry.headerProperties,
                  updatedAt: e.entry.updatedAt,
                  ourPhysicalClock: e.entry.ourPhysicalClock,
                  isDeleted: e.entry.isDeleted,
                ))
            .toList());
  }

  @override
  Future<void> saveGroupIndexSubscription({
    required IriTerm groupIndexIri,
    required IriTerm groupIndexTemplateIri,
    required IriTerm indexedType,
    required core.RootResourceFetchPolicy rootResourceFetchPolicy,
    required int createdAt,
  }) async {
    // Translate IRIs to IDs internally
    final ids = await _getOrCreateIriIdsMap(
      [groupIndexIri.value, groupIndexTemplateIri.value, indexedType.value],
    );
    final groupIndexIriId = ids[groupIndexIri.value]!;
    final groupIndexTemplateIriId = ids[groupIndexTemplateIri.value]!;
    final indexedTypeIriId = ids[indexedType.value]!;
    return indexDao.saveGroupIndexSubscription(
      groupIndexIriId: groupIndexIriId,
      groupIndexTemplateIriId: groupIndexTemplateIriId,
      indexedTypeIriId: indexedTypeIriId,
      rootResourceFetchPolicy: json.encode(rootResourceFetchPolicy.toMap()),
      createdAt: createdAt,
    );
  }

  @override
  Future<List<(IriTerm, IriTerm, core.RootResourceFetchPolicy)>>
      getSubscribedGroupIndices(IriTerm indexedType) async {
    final subscriptions =
        await indexDao.getSubscribedGroupIndices(indexedType.value);

    return subscriptions.map((subscription) {
      final groupIndexIri = _iriTermFactory(subscription.groupIndexIri);
      final indexedTypeIri = _iriTermFactory(subscription.indexedTypeIri);
      final fetchPolicy = core.RootResourceFetchPolicy.fromMap(
        json.decode(subscription.rootResourceFetchPolicy),
      );
      return (groupIndexIri, indexedTypeIri, fetchPolicy);
    }).toList();
  }

  @override
  Stream<Set<IriTerm>> watchSubscribedGroupIndexIris(
      IriTerm templateIri) async* {
    // Translate template IRI to ID
    final templateId = await _getOrCreateIriId(templateIri.value);

    // Watch subscribed index IDs from DAO
    await for (final indexIds
        in indexDao.watchSubscribedGroupIndexIds(templateId)) {
      // Translate IDs back to IRIs
      if (indexIds.isEmpty) {
        yield const {};
      } else {
        final idToIri = await _getIris(indexIds);
        yield idToIri.values.map((iri) => _iriTermFactory(iri)).toSet();
      }
    }
  }

  @override
  Future<int> ensureIndexSetVersion({
    required Set<IriTerm> indexIris,
    required int createdAt,
  }) async {
    // Translate index IRIs to IDs internally
    final indexIds = await _getOrCreateIriIds(
      indexIris.map((iri) => iri.value),
    );

    // Store version with IDs (implementation detail)
    return indexDao.ensureIndexIdSetVersion(
      indexIds: indexIds,
      createdAt: createdAt,
    );
  }

  @override
  Future<Set<IriTerm>> getIndexIrisForVersion(int versionId) async {
    // Get index IDs from DAO
    final indexIds = await indexDao.getIndexIriIdsForVersion(versionId);

    // Translate IDs back to IRIs
    if (indexIds.isEmpty) return const {};

    final idToIri = await _getIris(indexIds.toSet());
    return idToIri.values.map((iri) => _iriTermFactory(iri)).toSet();
  }

  @override
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
  }) async {
    // Translate IRIs to IDs
    final iriIds = await _getOrCreateIriIdsMap([
      shardIri.value,
      indexIri.value,
      resourceIri.value,
      resourceType.value,
    ]);

    final shardIriId = iriIds[shardIri.value]!;
    final indexIriId = iriIds[indexIri.value]!;
    final resourceIriId = iriIds[resourceIri.value]!;
    final resourceTypeIriId = iriIds[resourceType.value]!;

    // Save entry to database
    await indexDao.saveIndexEntry(
      shardIriId: shardIriId,
      indexIriId: indexIriId,
      resourceIriId: resourceIriId,
      resourceTypeIriId: resourceTypeIriId,
      clockHash: clockHash,
      headerProperties: headerProperties,
      isDeleted: isDeleted,
      ourPhysicalClock: ourPhysicalClock,
      updatedAt: updatedAt,
    );
  }

  @override
  Future<void> saveIndexEntries(
      Iterable<core.SaveIndexEntryRequest> requests) async {
    final requestList = requests.toList(growable: false);
    if (requestList.isEmpty) {
      return;
    }

    final allIris = <String>{};
    for (final request in requestList) {
      allIris.add(request.shardIri.value);
      allIris.add(request.indexIri.value);
      allIris.add(request.resourceIri.value);
      allIris.add(request.resourceType.value);
    }

    final iriIds = await _getOrCreateIriIdsMap(allIris);

    final operations = requestList
        .map(
          (request) => BatchIndexEntrySaveOperation(
            shardIriId: iriIds[request.shardIri.value]!,
            indexIriId: iriIds[request.indexIri.value]!,
            resourceIriId: iriIds[request.resourceIri.value]!,
            resourceTypeIriId: iriIds[request.resourceType.value]!,
            clockHash: request.clockHash,
            headerProperties: request.headerProperties,
            isDeleted: request.isDeleted,
            ourPhysicalClock: request.ourPhysicalClock,
            updatedAt: request.updatedAt,
          ),
        )
        .toList(growable: false);

    await indexDao.saveIndexEntriesBatch(operations);
  }

  @override
  Future<List<core.IndexEntryWithIri>> getActiveIndexEntriesForShard(
      IriTerm shardIri) async {
    final shardResolution = await _perflog.measure(
      'storage.getActiveIndexEntriesForShard.resolveShardIriId',
      () => _resolveShardIriId(shardIri),
      args: ['shard=${shardIri.debug}'],
      resultArgsBuilder: (resolution) => [
        'shardIriId=${resolution.shardIriId}',
        'cacheSource=${resolution.fromShardCache ? 'shardCache' : 'db'}',
      ],
      minDurationMs: 5,
    );
    final shardIriId = shardResolution.shardIriId;

    await _logActiveShardQueryPlanOnce(shardIriId);
    final dbProbeBeforeMs = await _measureDbProbeMs();
    final queryStopwatch = Stopwatch()..start();

    final driftEntries = await _perflog.measure(
      'storage.getActiveIndexEntriesForShard.query',
      () => indexDao.getActiveIndexEntriesForShard(shardIriId),
      args: [
        'shardIriId=$shardIriId',
        'dbProbeBeforeMs=$dbProbeBeforeMs',
      ],
      resultArgsBuilder: (entries) => ['resultCount=${entries.length}'],
      minDurationMs: 5,
    );
    queryStopwatch.stop();
    final dbProbeAfterMs = await _measureDbProbeMs();

    _perflog.measure(
      'storage.getActiveIndexEntriesForShard.contentionProbe',
      () async => null,
      args: [
        'shardIriId=$shardIriId|||queryMs=${queryStopwatch.elapsedMilliseconds}|||dbProbeBeforeMs=$dbProbeBeforeMs|||dbProbeAfterMs=$dbProbeAfterMs',
        'resultCount=${driftEntries.length}',
      ],
      minDurationMs: 0,
    );

    return _perflog.measure(
      'storage.getActiveIndexEntriesForShard.mapResults',
      () async => driftEntries
          .map((driftEntry) => core.IndexEntryWithIri(
                resourceIri: _iriTermFactory(driftEntry.resourceIri),
                clockHash: driftEntry.entry.clockHash,
                headerProperties: driftEntry.entry.headerProperties,
                updatedAt: driftEntry.entry.updatedAt,
                ourPhysicalClock: driftEntry.entry.ourPhysicalClock,
                isDeleted: driftEntry.entry.isDeleted,
              ))
          .toList(growable: false),
      resultArgsBuilder: (entries) => ['resultCount=${entries.length}'],
      minDurationMs: 5,
    );
  }

  @override
  Future<
      List<
          ({
            IriTerm shardIri,
            IriTerm resourceTypeIri,
            IriTerm indexIri,
            int maxPhysicalClock
          })>> getShardsToUpdate(int sinceTimestamp) async {
    final shardIris = await indexDao.getShardsToUpdate(sinceTimestamp);
    return shardIris
        .map((iri) => (
              shardIri: _iriTermFactory(iri.shardIri),
              resourceTypeIri: _iriTermFactory(iri.resourceTypeIri),
              indexIri: _iriTermFactory(iri.indexIri),
              maxPhysicalClock: iri.maxPhysicalClock,
            ))
        .toList();
  }

  @override
  Future<Map<IriTerm, Map<IriTerm, Map<IriTerm, String>>>>
      getForeignIndexShardsToSync({
    required IriTerm resourceType,
    required int sinceTimestamp,
    required Set<IriTerm> excludeIndexIris,
  }) async {
    // Convert IRIs to IDs for efficient querying
    final resourceTypeIriId = await _getOrCreateIriId(resourceType.value);

    final excludeIndexIriIds = excludeIndexIris.isEmpty
        ? <int>{}
        : (await _getOrCreateIriIdsMap(
                excludeIndexIris.map((iri) => iri.value).toList()))
            .values
            .toSet();

    final result = await indexDao.getForeignIndexShardsToSync(
      resourceTypeIriId: resourceTypeIriId,
      sinceTimestamp: sinceTimestamp,
      excludeIndexIriIds: excludeIndexIriIds,
    );

    // Convert back to IRI terms
    final iriMap = <IriTerm, Map<IriTerm, Map<IriTerm, String>>>{};
    for (final indexEntry in result.entries) {
      final indexIri = _iriTermFactory(indexEntry.key);
      final shardMap = <IriTerm, Map<IriTerm, String>>{};

      for (final shardEntry in indexEntry.value.entries) {
        final shardIri = _iriTermFactory(shardEntry.key);
        final resourceMap = <IriTerm, String>{};
        for (final resourceEntry in shardEntry.value.entries) {
          resourceMap[_iriTermFactory(resourceEntry.key)] = resourceEntry.value;
        }
        shardMap[shardIri] = resourceMap;
      }

      iriMap[indexIri] = shardMap;
    }

    return iriMap;
  }

  // Note: Sync timestamp helpers are provided by SyncTimestampStorage extension
  // from locorda_core. No need to duplicate them here.

  // ========================================================================
  // Remote ETag Management (Multi-Remote Support)
  // ========================================================================
  // All methods take RemoteId parameter to enable synchronization with
  // multiple remote endpoints simultaneously.

  @override
  Future<String?> getRemoteETag(
      core.RemoteId remoteId, IriTerm documentIri) async {
    final documentIriId = await _getOrCreateIriId(documentIri.value);
    final remoteIdInt = await remoteSyncStateDao.getOrCreateRemoteId(
        remoteId.backend, remoteId.id);

    return await remoteSyncStateDao.getETag(
      documentIriId: documentIriId,
      remoteId: remoteIdInt,
    );
  }

  @override
  Future<Map<IriTerm, String?>> getRemoteETags(
      core.RemoteId remoteId, Iterable<IriTerm> documentIris) async {
    final iris = documentIris.toList(growable: false);
    if (iris.isEmpty) {
      return const {};
    }

    final iriIdByIriValue = await _getOrCreateIriIdsMap(
      iris.map((iri) => iri.value),
    );
    final remoteIdInt = await remoteSyncStateDao.getOrCreateRemoteId(
      remoteId.backend,
      remoteId.id,
    );
    final etagByDocumentId = await remoteSyncStateDao.getETags(
      documentIriIds: iriIdByIriValue.values,
      remoteId: remoteIdInt,
    );

    final result = <IriTerm, String?>{};
    for (final iri in iris) {
      final iriId = iriIdByIriValue[iri.value]!;
      result[iri] = etagByDocumentId[iriId];
    }
    return result;
  }

  @override
  Future<void> setRemoteETag(
      core.RemoteId remoteId, IriTerm documentIri, String etag) async {
    final documentIriId = await _getOrCreateIriId(documentIri.value);
    final remoteIdInt = await remoteSyncStateDao.getOrCreateRemoteId(
        remoteId.backend, remoteId.id);

    await remoteSyncStateDao.setETag(
      documentIriId: documentIriId,
      remoteId: remoteIdInt,
      etag: etag,
    );
  }

  @override
  Future<void> setRemoteETags(
      core.RemoteId remoteId, Map<IriTerm, String> etagsByDocument) async {
    if (etagsByDocument.isEmpty) {
      return;
    }

    final iriIdByIriValue = await _getOrCreateIriIdsMap(
      etagsByDocument.keys.map((iri) => iri.value),
    );
    final remoteIdInt = await remoteSyncStateDao.getOrCreateRemoteId(
      remoteId.backend,
      remoteId.id,
    );

    final etagsByDocumentIriId = <int, String>{};
    for (final entry in etagsByDocument.entries) {
      etagsByDocumentIriId[iriIdByIriValue[entry.key.value]!] = entry.value;
    }

    await remoteSyncStateDao.setETags(
      remoteId: remoteIdInt,
      etagsByDocumentIriId: etagsByDocumentIriId,
    );
  }

  @override
  Future<void> clearRemoteETag(
      core.RemoteId remoteId, IriTerm documentIri) async {
    final documentIriId = await _getOrCreateIriId(documentIri.value);
    final remoteIdInt = await remoteSyncStateDao.getOrCreateRemoteId(
        remoteId.backend, remoteId.id);

    await remoteSyncStateDao.clearETag(
      documentIriId: documentIriId,
      remoteId: remoteIdInt,
    );
  }

  List<core.StoredDocument> _convertToStoredDocuments(
      List<DocumentWithIri> documents) {
    return documents.map((doc) {
      final graph =
          _codec.decode(doc.document.documentContent, documentUrl: doc.iri);

      return core.StoredDocument(
        documentIri: _iriTermFactory(doc.iri),
        document: graph,
        metadata: core.DocumentMetadata(
          ourPhysicalClock: doc.document.ourPhysicalClock,
          updatedAt: doc.document.updatedAt,
        ),
      );
    }).toList();
  }

  @override
  Future<int> getLastRemoteSyncTimestamp(core.RemoteId remoteId) async {
    final id = await remoteSyncStateDao.getOrCreateRemoteId(
        remoteId.backend, remoteId.id);
    return remoteSyncStateDao.getRemoteLastSyncTimestamp(id);
  }

  @override
  Future<void> updateLastRemoteSyncTimestamp(
      core.RemoteId remoteId, int timestamp) async {
    final id = await remoteSyncStateDao.getOrCreateRemoteId(
        remoteId.backend, remoteId.id);
    await remoteSyncStateDao.updateRemoteLastSyncTimestamp(id, timestamp);
  }

  @override
  Future<List<IriTerm>> getMissingDocumentsForIndexEntries(
      {IriTerm? resourceType}) async {
    // Get resource type IRI ID if filtering
    int? resourceTypeIriId;
    if (resourceType != null) {
      resourceTypeIriId = await _getOrCreateIriId(resourceType.value);
    }

    // Query DAO for missing document IRI IDs
    final missingIriIds = await indexDao.getMissingDocumentResourceIriIds(
      resourceTypeIriId: resourceTypeIriId,
    );

    if (missingIriIds.isEmpty) return [];

    // Convert IRI IDs back to IriTerms
    final idToIri = await _getIris(missingIriIds);
    return idToIri.values.map((iri) => _iriTermFactory(iri)).toList();
  }

  DateTime? _fromUtcMs(int? value) {
    if (value == null) {
      return null;
    }
    return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
  }

  core.RemoteSyncEntry _toRemoteIndexSyncStateSnapshot(
    IndexInstanceSyncState state,
    RemoteSetting remote,
  ) {
    return core.RemoteSyncEntry(
      remoteId: core.RemoteId(remote.remoteType, remote.remoteId),
      phase: core.RemoteSyncPhase.values.firstWhere(
        (candidate) => candidate.name == state.phase,
        orElse: () => core.RemoteSyncPhase.notSynced,
      ),
      lastSuccessfulSyncAt: _fromUtcMs(state.lastSuccessfulSyncAtMs),
      lastAttemptStartedAt: _fromUtcMs(state.lastAttemptStartedAtMs),
      lastAttemptFinishedAt: _fromUtcMs(state.lastAttemptFinishedAtMs),
      lastErrorMessage: state.lastErrorMessage,
    );
  }

  @override
  Future<void> upsertIndexInstanceSyncState({
    required IriTerm indexInstanceIri,
    required core.RemoteId remoteId,
    required core.RemoteSyncPhase phase,
    DateTime? lastSuccessfulSyncAt,
    DateTime? lastAttemptStartedAt,
    DateTime? lastAttemptFinishedAt,
    String? lastErrorMessage,
  }) async {
    final indexInstanceIriId = await _getOrCreateIriId(indexInstanceIri.value);
    final remoteSettingId = await remoteSyncStateDao.getOrCreateRemoteId(
      remoteId.backend,
      remoteId.id,
    );

    final lastSuccessfulSyncAtMs =
        lastSuccessfulSyncAt?.toUtc().millisecondsSinceEpoch;

    await _database.into(_database.indexInstanceSyncStates).insert(
          IndexInstanceSyncStatesCompanion.insert(
            indexInstanceIriId: indexInstanceIriId,
            remoteSettingId: remoteSettingId,
            phase: phase.name,
            lastSuccessfulSyncAtMs: Value(lastSuccessfulSyncAtMs),
            lastAttemptStartedAtMs:
                Value(lastAttemptStartedAt?.toUtc().millisecondsSinceEpoch),
            lastAttemptFinishedAtMs:
                Value(lastAttemptFinishedAt?.toUtc().millisecondsSinceEpoch),
            lastErrorMessage: Value(lastErrorMessage),
          ),
          onConflict: DoUpdate(
            (_) => IndexInstanceSyncStatesCompanion(
              phase: Value(phase.name),
              lastSuccessfulSyncAtMs: lastSuccessfulSyncAtMs != null
                  ? Value(lastSuccessfulSyncAtMs)
                  : const Value.absent(),
              lastAttemptStartedAtMs:
                  Value(lastAttemptStartedAt?.toUtc().millisecondsSinceEpoch),
              lastAttemptFinishedAtMs:
                  Value(lastAttemptFinishedAt?.toUtc().millisecondsSinceEpoch),
              lastErrorMessage: Value(lastErrorMessage),
            ),
            target: [
              _database.indexInstanceSyncStates.indexInstanceIriId,
              _database.indexInstanceSyncStates.remoteSettingId,
            ],
          ),
        );
  }

  @override
  Future<core.IndexInstanceSyncState> getIndexInstanceSyncState(
      IriTerm indexInstanceIri) async {
    final query = _buildIndexSyncStateQuery(indexInstanceIri);
    final rows = await query.get();

    return _rowsToIndexSyncState(rows, indexInstanceIri);
  }

  core.IndexInstanceSyncState _rowsToIndexSyncState(
      List<TypedResult> rows, IriTerm indexInstanceIri) {
    final perRemote = <core.RemoteId, core.RemoteSyncEntry>{};
    for (final row in rows) {
      final snapshot = _toRemoteIndexSyncStateSnapshot(
        row.readTable(_database.indexInstanceSyncStates),
        row.readTable(_database.remoteSettings),
      );
      assert(
        !perRemote.containsKey(snapshot.remoteId),
        'Duplicate sync-state rows for indexInstanceIri=${indexInstanceIri.value} and remote=${snapshot.remoteId}.',
      );
      perRemote[snapshot.remoteId] = snapshot;
    }

    return core.IndexInstanceSyncState(
      indexInstanceIri: indexInstanceIri,
      perRemote: perRemote,
    );
  }

  Selectable<TypedResult> _buildIndexSyncStateQuery(IriTerm indexInstanceIri) {
    final indexIriTable = _database.syncIris.createAlias('index_iri');
    final query = _database.select(_database.indexInstanceSyncStates).join([
      innerJoin(
        indexIriTable,
        indexIriTable.id
            .equalsExp(_database.indexInstanceSyncStates.indexInstanceIriId),
      ),
      innerJoin(
        _database.remoteSettings,
        _database.remoteSettings.id
            .equalsExp(_database.indexInstanceSyncStates.remoteSettingId),
      ),
    ])
      ..where(indexIriTable.iri.equals(indexInstanceIri.value));
    return query;
  }

  @override
  Stream<core.IndexInstanceSyncState> watchIndexInstanceSyncState(
      IriTerm indexInstanceIri) {
    final query = _buildIndexSyncStateQuery(indexInstanceIri);
    return query
        .watch()
        .map((rows) => _rowsToIndexSyncState(rows, indexInstanceIri));
  }

  @override
  Future<List<core.RemoteId>> getConfiguredRemoteIds() async {
    final rows = await _database.select(_database.remoteSettings).get();
    return rows
        .map((row) => core.RemoteId(row.remoteType, row.remoteId))
        .toList(growable: false);
  }

  @override
  Stream<Set<core.RemoteId>> watchConfiguredRemoteIds() {
    return _database.select(_database.remoteSettings).watch().map(
          (rows) => rows
              .map((row) => core.RemoteId(row.remoteType, row.remoteId))
              .toSet(),
        );
  }
}
