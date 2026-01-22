import 'dart:async';

import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/storage/storage_interface.dart';
import 'package:logging/logging.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:rxdart/rxdart.dart';

final _logger = Logger('InMemoryStorage');

class _WatchController<T> {
  final BehaviorSubject<T> _controller;
  final Future<T> Function() _query;
  final Iterable<IriTerm> triggers;

  _WatchController(this.triggers, this._query)
      : _controller = BehaviorSubject<T>();

  Stream<T> get stream => _controller.stream;

  bool get isClosed => _controller.isClosed;

  Future<void> trigger() async {
    final data = await _query();
    _controller.add(data);
  }

  Future<void> close() async {
    await _controller.close();
  }
}

/// In-memory storage implementation for testing, prototyping, and demos.
///
/// Provides a complete [Storage] implementation that keeps all data in memory
/// with full support for reactive streams, ETags, and index management.
///
/// ## Use Cases
///
/// ✅ **Testing** - Fast, isolated tests without database setup
/// ✅ **Prototyping** - Quick experimentation without infrastructure
/// ✅ **Demos** - Browser demos without backend dependencies
///
/// ⚠️ **Not for production use!** All data is lost when the application closes.
///
/// ## Example
///
/// ```dart
/// final locorda = await Locorda.create(
///   storage: InMemoryStorage(),
///   backends: [InMemoryBackend()],
///   config: LocordaConfig(resources: [...]),
/// );
/// ```
///
/// For persistent storage, use [DriftStorage] from the `locorda_drift` package.
class InMemoryStorage implements Storage {
  final Map<IriTerm, StoredDocument> _documents = {};
  final Map<IriTerm, IriTerm> _documentTypes = {}; // documentIri -> typeIri
  final Map<IriTerm, List<PropertyChange>> _propertyChanges = {};
  final Map<String, String> _settings = {};

  // Index entry storage
  final Map<String, _IndexEntry> _indexEntries =
      {}; // key: "$shardIri|$resourceIri"

  // Note: Sync timestamps now stored in _settings via SyncTimestampStorage extension
  // Remote ETags also stored in _settings

  // Group index subscription storage
  final Map<IriTerm, _GroupIndexSubscription> _groupIndexSubscriptions = {};

  // Index set version storage
  final Map<int, Set<IriTerm>> _indexSetVersions =
      {}; // versionId -> Set<IriTerm>
  final Map<String, int> _indexSetVersionKeys =
      {}; // sorted iris key -> versionId
  int _nextVersionId = 1;

  // Reactive streams for watch operations
  final Map<IriTerm, Set<_WatchController>> _watchControllersByTrigger = {};
  final List<_WatchController> _watchControllers = [];

  @override
  Future<void> initialize() async {
    _logger.fine(
        'InMemoryStorage.initialize() called on instance ${identityHashCode(this)}');
    // No-op for in-memory storage
  }

  @override
  Future<void> close() async {
    // Close all stream controllers
    for (final controller in _watchControllers) {
      await controller.close();
    }
    _watchControllersByTrigger.clear();
    _watchControllers.clear();
  }

  @override
  Future<StoredDocument?> getDocument(IriTerm documentIri,
      {int? ifChangedSincePhysicalClock}) async {
    final doc = _documents[documentIri];
    if (doc == null) return null;
    if (ifChangedSincePhysicalClock != null &&
        doc.metadata.ourPhysicalClock <= ifChangedSincePhysicalClock) {
      return null;
    }
    return doc;
  }

  /// Get max updatedAt for all documents of a specific type.
  int? _getMaxUpdatedAtForType(IriTerm typeIri) {
    final docsOfType = _documentTypes.entries
        .where((e) => e.value == typeIri)
        .map((e) => _documents[e.key])
        .whereType<StoredDocument>();

    if (docsOfType.isEmpty) return null;

    return docsOfType
        .map((doc) => doc.metadata.updatedAt)
        .reduce((a, b) => a > b ? a : b);
  }

  @override
  Future<SaveDocumentResult> saveDocument(
      IriTerm documentIri,
      IriTerm typeIri,
      RdfGraph document,
      DocumentMetadata metadata,
      List<PropertyChange> changes,
      {int? ifMatchUpdatedAt}) async {
    _logger.fine(
        'InMemoryStorage.saveDocument: document=${documentIri.debug}, type=${typeIri.debug}, updatedAt=${metadata.updatedAt}, ourPhysicalClock=${metadata.ourPhysicalClock}');
    // Check optimistic lock if required
    if (ifMatchUpdatedAt != null) {
      final existingDocument = _documents[documentIri];
      if (existingDocument != null &&
          existingDocument.metadata.updatedAt != ifMatchUpdatedAt) {
        // Conflict detected - document was modified since expected version
        throw ConcurrentUpdateException(
            'Optimistic concurrency check failed for document $documentIri: expected updatedAt=$ifMatchUpdatedAt, actual updatedAt=${existingDocument.metadata.updatedAt}');
      }
    }

    // Get previous max cursor for this type (not for this document!)
    final previousTimestamp = _getMaxUpdatedAtForType(typeIri);
    final previousCursor = previousTimestamp?.toString();

    _documents[documentIri] = StoredDocument(
      documentIri: documentIri,
      document: document,
      metadata: metadata,
    );
    _documentTypes[documentIri] = typeIri;

    _propertyChanges[documentIri] = [
      ...(_propertyChanges[documentIri] ?? []),
      ...changes
    ];

    // Emit to document watch streams for this type
    await _triggerWatchers([typeIri, documentIri]);

    return SaveDocumentResult(
      previousCursor: previousCursor,
      currentCursor: metadata.updatedAt.toString(),
    );
  }

  /// Emit current documents to all watch streams for a specific type.
  Future<void> _triggerWatchers(Iterable<IriTerm> typeIris) async {
    _logger.fine(
        'InMemoryStorage: Triggering watchers for types: ${typeIris.map((i) => i.debug)}');
    final controllers = typeIris
        .map((typeIri) => _watchControllersByTrigger[typeIri])
        .nonNulls
        .expand((c) => c)
        .toSet();

    if (controllers.isEmpty) return;
    for (final controller in controllers) {
      if (controller.isClosed) continue;
      await controller.trigger();
    }
  }

  @override
  Future<List<PropertyChange>> getPropertyChanges(IriTerm documentIri,
      {int? sinceLogicalClock}) async {
    final changes = _propertyChanges[documentIri] ?? [];
    if (sinceLogicalClock == null) return changes;

    return changes
        .where((c) => c.changeLogicalClock > sinceLogicalClock)
        .toList();
  }

  void resetPropertyChanges() {
    _propertyChanges.clear();
  }

  @override
  Future<DocumentsResult> getDocumentsModifiedSince(
      IriTerm typeIri, String? minCursor,
      {required int limit}) async {
    return _getDocuments(
      typeIri: typeIri,
      minCursor: minCursor,
      limit: limit,
      timestampExtractor: (doc) => doc.metadata.updatedAt,
    );
  }

  @override
  Future<DocumentsResult> getDocumentsChangedByUsSince(
      IriTerm typeIri, String? minCursor,
      {required int limit}) async {
    return _getDocuments(
      typeIri: typeIri,
      minCursor: minCursor,
      limit: limit,
      timestampExtractor: (doc) => doc.metadata.ourPhysicalClock,
    );
  }

  Stream<T> _startWatching<T>(_WatchController<T> controller) async* {
    _watchControllers.add(controller);
    for (final typeIri in controller.triggers) {
      _watchControllersByTrigger
          .putIfAbsent(
            typeIri,
            () => {},
          )
          .add(controller);
    }
    await controller.trigger();
    yield* controller.stream;
  }

  @override
  Stream<DocumentsResult> watchDocumentsModifiedSince(
          IriTerm typeIri, String? minCursor) =>
      _startWatching(_WatchController([typeIri],
          () => getDocumentsModifiedSince(typeIri, minCursor, limit: 1000)));

  @override
  Stream<DocumentsResult> watchDocumentsChangedByUsSince(
          IriTerm typeIri, String? minCursor) =>
      _startWatching(_WatchController([typeIri],
          () => getDocumentsChangedByUsSince(typeIri, minCursor, limit: 1000)));

  /// Shared implementation for GET operations with pagination.
  DocumentsResult _getDocuments({
    required IriTerm typeIri,
    required String? minCursor,
    required int? limit,
    required int Function(StoredDocument) timestampExtractor,
  }) {
    final cursorTimestamp = minCursor != null ? int.parse(minCursor) : 0;
    final allFiltered = _documents.values
        .where((doc) => _isType(doc, typeIri))
        .where((doc) => timestampExtractor(doc) > cursorTimestamp)
        .toList()
      ..sort((a, b) => timestampExtractor(a).compareTo(timestampExtractor(b)));

    // Apply limit for pagination
    final filtered =
        limit != null ? allFiltered.take(limit).toList() : allFiltered;

    // currentCursor: last document's timestamp, or minCursor if no documents found
    // This ensures the cursor never goes backwards
    final currentCursor = filtered.isNotEmpty
        ? timestampExtractor(filtered.last).toString()
        : minCursor;

    // hasNext: true if we got a full batch (might be more data available)
    final hasNext = limit == null ? false : filtered.length >= limit;

    return DocumentsResult(
        documents: filtered, currentCursor: currentCursor, hasNext: hasNext);
  }

  bool _isType(StoredDocument doc, IriTerm typeIri) {
    final managedResourceType = doc.document.findSingleObject<IriTerm>(
        doc.documentIri, SyncManagedDocument.managedResourceType);
    return managedResourceType == typeIri;
  }

  @override
  Future<Map<String, String>> getSettings(Iterable<String> keys) async {
    return {
      for (final key in keys)
        if (_settings.containsKey(key)) key: _settings[key]!
    };
  }

  @override
  Future<void> setSetting(String key, String value) async {
    _settings[key] = value;
  }

  // Index-related methods - stubs for basic testing
  @override
  Future<IndexEntriesPage> getIndexEntries({
    required Iterable<IriTerm> indexIris,
    int? cursorTimestamp,
    int limit = 100,
  }) async {
    _logger.fine(
        'getIndexEntries: indexIris=${indexIris.map((i) => i.debug)}, cursorTimestamp=$cursorTimestamp');
    // Filter stored index entries by requested index IRIs and cursorTimestamp
    final cursor = cursorTimestamp ?? 0;
    final filtered = _indexEntries.values
        .where((e) => indexIris.contains(e.indexIri))
        .where((e) => e.updatedAt > cursor)
        .toList()
      ..sort((a, b) => a.updatedAt.compareTo(b.updatedAt));

    final limited = filtered.take(limit).toList();

    final entries = limited
        .map((e) => IndexEntryWithIri(
              resourceIri: e.resourceIri,
              clockHash: e.clockHash,
              headerProperties: e.headerProperties,
              updatedAt: e.updatedAt,
              ourPhysicalClock: e.ourPhysicalClock,
              isDeleted: e.isDeleted,
            ))
        .toList();

    final lastCursor = entries.isNotEmpty ? entries.last.updatedAt : null;

    return IndexEntriesPage(
        entries: entries, hasMore: false, lastCursor: lastCursor);
  }

  @override
  Stream<List<IndexEntryWithIri>> watchIndexEntries({
    required Iterable<IriTerm> indexIris,
    int? cursorTimestamp,
  }) {
    _logger.fine(
        'watchIndexEntries: indexIris=${indexIris.map((i) => i.debug)}, cursorTimestamp=$cursorTimestamp');
    return _startWatching(_WatchController(
        indexIris,
        () async => (await getIndexEntries(
                indexIris: indexIris, cursorTimestamp: cursorTimestamp))
            .entries));
  }

  @override
  Future<void> saveGroupIndexSubscription({
    required int createdAt,
    required IriTerm groupIndexIri,
    required IriTerm groupIndexTemplateIri,
    required IriTerm indexedType,
    required ItemFetchPolicy itemFetchPolicy,
  }) async {
    _groupIndexSubscriptions[groupIndexIri] = _GroupIndexSubscription(
      groupIndexIri: groupIndexIri,
      groupIndexTemplateIri: groupIndexTemplateIri,
      indexedType: indexedType,
      itemFetchPolicy: itemFetchPolicy,
      createdAt: createdAt,
    );
  }

  @override
  Stream<Set<IriTerm>> watchSubscribedGroupIndexIris(IriTerm templateIri) =>
      _startWatching(_WatchController(
          [templateIri],
          () async => _groupIndexSubscriptions.values
              .where((sub) => sub.groupIndexTemplateIri == templateIri)
              .map((sub) => sub.groupIndexIri)
              .toSet()));

  @override
  Future<List<(IriTerm, IriTerm, ItemFetchPolicy)>> getSubscribedGroupIndices(
      IriTerm indexedType) async {
    return _groupIndexSubscriptions.values
        .where((sub) => sub.indexedType == indexedType)
        .map((sub) => (sub.groupIndexIri, sub.indexedType, sub.itemFetchPolicy))
        .toList();
  }

  @override
  Future<int> ensureIndexSetVersion({
    required Set<IriTerm> indexIris,
    required int createdAt,
  }) async {
    // Sort IRIs for consistent key generation
    final sortedIris = indexIris.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    final key = sortedIris.map((iri) => iri.value).join(',');

    // Check if this set already has a version
    if (_indexSetVersionKeys.containsKey(key)) {
      return _indexSetVersionKeys[key]!;
    }

    // Create new version
    final versionId = _nextVersionId++;
    _indexSetVersions[versionId] = indexIris;
    _indexSetVersionKeys[key] = versionId;

    return versionId;
  }

  @override
  Future<Set<IriTerm>> getIndexIrisForVersion(int versionId) async {
    return _indexSetVersions[versionId] ?? {};
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
    required int updatedAt,
    required int ourPhysicalClock,
  }) async {
    final key = '${shardIri.value}|${resourceIri.value}';
    _logger.fine(
        'InMemoryStorage.saveIndexEntry: shard=${shardIri.debug}, resource=${resourceIri.debug}, clock=$ourPhysicalClock');
    _indexEntries[key] = _IndexEntry(
      shardIri: shardIri,
      indexIri: indexIri,
      resourceType: resourceType,
      resourceIri: resourceIri,
      clockHash: clockHash,
      headerProperties: headerProperties,
      isDeleted: isDeleted,
      updatedAt: updatedAt,
      ourPhysicalClock: ourPhysicalClock,
    );

    // Emit to all watch streams that include this index
    await _triggerWatchers([indexIri, shardIri, resourceIri]);
  }

  @override
  Future<List<IndexEntryWithIri>> getActiveIndexEntriesForShard(
      IriTerm shardIri) async {
    _logger.finer(
        'InMemoryStorage.getActiveIndexEntriesForShard: looking for shard=${shardIri.debug}');
    _logger.finest(
        'InMemoryStorage: Total entries in storage: ${_indexEntries.length}');
    for (final entry in _indexEntries.values) {
      _logger.finest(
          '  - shard=${entry.shardIri.debug}, resource=${entry.resourceIri.debug}, deleted=${entry.isDeleted}');
    }
    final result = _indexEntries.values
        .where(
            (entry) => entry.shardIri == shardIri && entry.isDeleted == false)
        .map((entry) => IndexEntryWithIri(
              resourceIri: entry.resourceIri,
              clockHash: entry.clockHash,
              headerProperties: entry.headerProperties,
              updatedAt: entry.updatedAt,
              ourPhysicalClock: entry.ourPhysicalClock,
              isDeleted: entry.isDeleted,
            ))
        .toList();
    _logger.finer(
        'InMemoryStorage: Found ${result.length} active entries for this shard');
    return result;
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
    // Find max(ourPhysicalClock) per shard, then filter shards where max > sinceTimestamp
    final shardMaxClocks = <IriTerm,
        ({IriTerm resourceTypeIri, IriTerm indexIri, int maxPhysicalClock})>{};

    // Calculate max physical clock for each shard
    for (final entry in _indexEntries.values) {
      final currentMax = shardMaxClocks[entry.shardIri]?.maxPhysicalClock ?? 0;
      if (entry.ourPhysicalClock > currentMax) {
        shardMaxClocks[entry.shardIri] = (
          resourceTypeIri: entry.resourceType,
          indexIri: entry.indexIri,
          maxPhysicalClock: entry.ourPhysicalClock,
        );
      }
    }

    // Filter shards where max > sinceTimestamp and return as list of tuples
    return shardMaxClocks.entries
        .where((entry) => entry.value.maxPhysicalClock > sinceTimestamp)
        .map((entry) => (
              shardIri: entry.key,
              resourceTypeIri: entry.value.resourceTypeIri,
              indexIri: entry.value.indexIri,
              maxPhysicalClock: entry.value.maxPhysicalClock
            ))
        .toList();
  }

  @override
  Future<Map<IriTerm, Map<IriTerm, Map<IriTerm, String>>>>
      getForeignIndexShardsToSync({
    required int sinceTimestamp,
    required Set<IriTerm> excludeIndexIris,
    required IriTerm resourceType,
  }) async {
    final result = <IriTerm, Map<IriTerm, Map<IriTerm, String>>>{};

    // Build set of covered resources from configured indices
    final coveredResources = _indexEntries.values
        .where((entry) => excludeIndexIris.contains(entry.indexIri))
        .where((entry) => entry.resourceType == resourceType)
        .map((entry) => entry.resourceIri)
        .toSet();

    // Find foreign index entries that are either dirty or uncovered
    for (final entry in _indexEntries.values) {
      // Skip excluded (configured) indices
      if (excludeIndexIris.contains(entry.indexIri) ||
          entry.resourceType != resourceType) continue;

      // Check if entry is dirty (modified since timestamp)
      final isDirty = entry.ourPhysicalClock > sinceTimestamp;

      // Check if resource is uncovered (not in any configured index)
      final isUncovered = !coveredResources.contains(entry.resourceIri);

      // Include tombstones - they need to be synced for proper CRDT merge
      if (isDirty || isUncovered) {
        result.putIfAbsent(entry.indexIri, () => {}).putIfAbsent(
            entry.shardIri, () => {})[entry.resourceIri] = entry.clockHash;
      }
    }

    return result;
  }

  // Sync timestamps now handled by SyncTimestampStorage extension using _settings

  // ========================================================================
  // Remote ETag Management (Multi-Remote Support)
  // ========================================================================

  @override
  Future<String?> getRemoteETag(RemoteId remoteId, IriTerm documentIri) async {
    _logger.fine(
        'InMemoryStorage.getRemoteETag: remote=${remoteId}, document=${documentIri.debug}');
    return _settings[
        'remote.etag.${remoteId.backend}.${remoteId.id}.${documentIri.value}'];
  }

  @override
  Future<void> setRemoteETag(
      RemoteId remoteId, IriTerm documentIri, String etag) async {
    _logger.fine(
        'InMemoryStorage.setRemoteETag: remote=${remoteId}, document=${documentIri.debug}, etag=$etag');
    _settings[
            'remote.etag.${remoteId.backend}.${remoteId.id}.${documentIri.value}'] =
        etag;
  }

  @override
  Future<void> clearRemoteETag(RemoteId remoteId, IriTerm documentIri) async {
    _settings.remove(
        'remote.etag.${remoteId.backend}.${remoteId.id}.${documentIri.value}');
  }

  @override
  Future<int> getLastRemoteSyncTimestamp(RemoteId remoteId) async {
    final lastSyncTimestamp =
        _settings['sync.lastRemote.${remoteId.backend}.${remoteId.id}'];
    return lastSyncTimestamp != null ? int.parse(lastSyncTimestamp) : 0;
  }

  @override
  Future<void> updateLastRemoteSyncTimestamp(
      RemoteId remoteId, int timestamp) async {
    _settings['sync.lastRemote.${remoteId.backend}.${remoteId.id}'] =
        timestamp.toString();
  }
}

/// Internal class to store index entries in memory.
class _IndexEntry {
  final IriTerm shardIri;
  final IriTerm indexIri;
  final IriTerm resourceIri;
  final IriTerm resourceType;
  final String clockHash;
  final String? headerProperties;
  final bool isDeleted;
  final int updatedAt;
  final int ourPhysicalClock;

  _IndexEntry({
    required this.shardIri,
    required this.indexIri,
    required this.resourceIri,
    required this.resourceType,
    required this.clockHash,
    this.headerProperties,
    required this.isDeleted,
    required this.updatedAt,
    required this.ourPhysicalClock,
  });
}

/// Internal class to store group index subscriptions in memory.
class _GroupIndexSubscription {
  final IriTerm groupIndexIri;
  final IriTerm groupIndexTemplateIri;
  final IriTerm indexedType;
  final ItemFetchPolicy itemFetchPolicy;
  final int createdAt;

  _GroupIndexSubscription({
    required this.groupIndexIri,
    required this.groupIndexTemplateIri,
    required this.indexedType,
    required this.itemFetchPolicy,
    required this.createdAt,
  });
}
