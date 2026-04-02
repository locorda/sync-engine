import 'dart:async';

import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/storage/remote_storage.dart'
    show PipelineRemoteStorage, RemoteDownloadRequest, RemoteUploadRequest;
import 'package:locorda_core/src/sync/pipeline/backend/remote_sync_storages.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_support.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:logging/logging.dart';
import 'package:rxdart/rxdart.dart';

final _logger = Logger('InMemoryBackend');

/// In-memory backend implementation for testing, prototyping, and demos.
///
/// Provides a simple [Backend] with an in-memory [PipelineRemoteStorage] that simulates
/// remote storage operations without requiring network access or actual remote servers.
///
/// ## Use Cases
///
/// ✅ **Testing** - Test sync logic without external dependencies
/// ✅ **Prototyping** - Develop offline-first apps without backend setup
/// ✅ **Demos** - Demonstrate sync features in isolated environments
///
/// ⚠️ **Not for production use!** No actual remote persistence.
///
/// ## Example
///
/// ```dart
/// final locorda = await Locorda.createSingleThreaded(
///   storage: InMemoryStorage(),
///   backends: [InMemoryBackend()],  // Simulates remote storage
///   config: LocordaConfig(resources: [...]),
/// );
/// ```
///
/// For real remote storage, use [SolidBackend] from the `locorda_solid` package.
class InMemoryBackend implements PipelineBackend {
  @override
  String get name => 'in-memory';

  final List<InMemoryRemoteStorage> _remotes;
  final BehaviorSubject<List<InMemoryRemoteStorage>> _remotesChangedSubject;
  final IriTranslator? iriTranslator;

  InMemoryBackend({
    bool useShardDatasets = false,
    this.iriTranslator,
    required RdfCore rdfCore,
    required ResourceGraphLoader resourceGraphLoader,
    required InMemoryBackendStore store,
  })  : _remotes = [
          InMemoryRemoteStorage(
            RemoteId('in-memory', 'default'),
            useShardDatasets: useShardDatasets,
            iriTranslator: iriTranslator,
            rdfCore: rdfCore,
            resourceGraphLoader: resourceGraphLoader,
            store: store,
          )
        ],
        _remotesChangedSubject =
            BehaviorSubject<List<InMemoryRemoteStorage>>() {
    // Emit initial state
    _remotesChangedSubject.add(_remotes);
  }

  @override
  List<PipelineRemoteStorage> get pipelineRemotes => _remotes;

  @override
  Stream<List<PipelineRemoteStorage>> get pipelineRemotesChanged =>
      _remotesChangedSubject.stream;

  @override
  Future<void> dispose() async {
    await _remotesChangedSubject.close();
  }
}

/// In-memory implementation of RemoteStorage for testing.
///
/// Provides full ETag support with correct HTTP conditional request semantics:
/// - If-None-Match: * (create only)
/// - If-Match: <etag> (update only if unchanged)
/// - If-None-Match: <etag> (download only if changed)
class InMemoryRemoteStorage implements PipelineRemoteStorage {
  @override
  final RemoteId remoteId;
  @override
  final bool useShardDatasets;
  final IriTranslator? iriTranslator;
  final RdfCore _rdfCore;
  final ResourceGraphLoader _resourceGraphLoader;

  /// Storage: documentIri -> (graph, etag)
  final InMemoryBackendStore _store;

  InMemoryRemoteStorage(
    this.remoteId, {
    this.useShardDatasets = false,
    this.iriTranslator,
    required RdfCore rdfCore,
    required ResourceGraphLoader resourceGraphLoader,
    required InMemoryBackendStore store,
  })  : _rdfCore = rdfCore,
        _resourceGraphLoader = resourceGraphLoader,
        _store = store;

  @override
  Future<bool> isAvailable() async {
    // In-memory storage is always available
    return true;
  }

  @override
  Future<PipelineRemoteSyncStorage> createPipelineSyncStorage(
      SyncEngineConfig config) async {
    final backend = _InMemorySyncBackend(storage: _store, rdfCore: _rdfCore);
    final mode = useShardDatasets
        ? RemoteStorageMode.shardDataset
        : RemoteStorageMode.filePerResource;
    if (iriTranslator != null) {
      return RemoteSyncStorages.createIriTranslated(
          mode: mode,
          backend: backend,
          resourceGraphLoader: _resourceGraphLoader,
          translator: iriTranslator!,
          rdfCore: _rdfCore);
    }
    return RemoteSyncStorages.create(
        mode: mode,
        backend: backend,
        resourceGraphLoader: _resourceGraphLoader);
  }

  @override
  Future<void> dispose() async {
    // No resources to dispose in in-memory backend
  }
}

class InMemoryBackendStore {
  /// Counter for generating unique ETags
  int _etagCounter = 0;

  /// Storage: documentIri -> (graph, etag)
  final Map<String, StoredDocument> _documents = {};

  InMemoryBackendStore();

  /// Clear all stored documents (for testing)
  void clear() {
    _etagCounter = 0;
    _documents.clear();
  }

  /// Generate a new unique ETag
  String _generateETag() => '"etag-${++_etagCounter}"';

  /// Returns a snapshot of all documents for testing purposes.
  Map<IriTerm, StoredDocument> getAllDocuments() {
    return _documents.map(
      (key, value) => MapEntry(IriTerm(key), value),
    );
  }

  /// Returns all stored documents as [RemoteStoredDocument]s for testing.
  List<RemoteStoredDocument> getStoredDocumentsForTesting() {
    return _documents.entries
        .map((entry) => RemoteStoredDocument(
            documentIri: IriTerm(entry.key), data: entry.value.data))
        .toList();
  }

  //Map<String, _StoredDocument<T>> get documents => _documents;
  StoredDocument<T>? getDocument<T>(IriTerm documentIri) {
    return _documents[documentIri.value] as StoredDocument<T>?;
  }

  void deleteDocument(IriTerm documentIri) {
    _documents.remove(documentIri.value);
  }

  String storeDocument<T>(IriTerm documentIri, T data) {
    final newEtag = _generateETag();
    _documents[documentIri.value] =
        StoredDocument<T>(data: data, etag: newEtag);
    return newEtag;
  }

  /// Check if document exists (for testing)
  bool hasDocument(IriTerm documentIri) {
    return _documents.containsKey(documentIri.value);
  }

  /// Get stored ETag for document (for testing)
  String? getETag(IriTerm documentIri) {
    return _documents[documentIri.value]?.etag;
  }
}

/// Stored remote document wrapper for testing.
class RemoteStoredDocument {
  final IriTerm documentIri;
  final Object data;

  const RemoteStoredDocument({
    required this.documentIri,
    required this.data,
  });

  bool get isDataset => data is RdfDataset;
  bool get isGraph => data is RdfGraph;
  RdfGraph get graph => data as RdfGraph;
  RdfDataset get dataset => data as RdfDataset;
}

class _InMemorySyncBackend implements RemoteSyncStorageBackend {
  final InMemoryBackendStore _storage;
  final RdfCore _rdfCore;
  _InMemorySyncBackend({
    required InMemoryBackendStore storage,
    required RdfCore rdfCore,
  })  : _rdfCore = rdfCore,
        _storage = storage;

  @override
  Future<List<RemoteDownloadResult<RdfGraphSource>>> downloadSources(
      Iterable<RemoteDownloadRequest> requests) async {
    final results = <RemoteDownloadResult<RdfGraphSource>>[];
    for (final request in requests) {
      final result = await _download<RdfGraph>(_storage, request.documentIri,
          ifNoneMatch: request.ifNoneMatch);
      // In-memory backend holds decoded graphs directly; DecodedGraphSource is
      // the correct source type — no encoding round-trip ever happened.
      results.add(RemoteDownloadResult<RdfGraphSource>(
        graph: result.graph != null ? DecodedGraphSource(result.graph!) : null,
        etag: result.etag,
        notModified: result.notModified,
      ));
    }
    return results;
  }

  Future<RemoteDownloadResult<T>> _download<T>(
      InMemoryBackendStore store, IriTerm documentIri,
      {String? ifNoneMatch}) async {
    _logger.fine(
        'Downloading document: ${documentIri.debug}, ifNoneMatch:$ifNoneMatch');
    final stored = store.getDocument<T>(documentIri);
    // Document doesn't exist
    if (stored == null) {
      _logger.fine('Document not found: ${documentIri.debug}');
      return RemoteDownloadResult<T>(
        graph: null,
        etag: null,
        notModified: false,
      );
    }

    // If-None-Match: check if document changed
    if (ifNoneMatch != null && ifNoneMatch == stored.etag) {
      _logger.fine('Document not modified: ${documentIri.debug}');
      // 304 Not Modified
      return RemoteDownloadResult<T>.notModified(etag: stored.etag);
    }

    _logger.fine(
        'Document downloaded: ${documentIri.debug}, etag:${stored.etag}, ifNoneMatch:$ifNoneMatch');
    // 200 OK - return document
    return RemoteDownloadResult<T>(
      graph: stored.data,
      etag: stored.etag,
      notModified: false,
    );
  }

  @override
  Future<List<RemoteUploadResult>> uploadSources(
      Iterable<RemoteUploadRequest<RdfGraphSource>> requests) async {
    final results = <RemoteUploadResult>[];
    for (final request in requests) {
      // CRDT merge always produces DecodedGraphSource; it is highly unlikely
      // that callers would pass an encoded source to uploadSources,
      // but if they do, play it safe and decode it first to get the graph,
      // because we store the graph in memory.
      final source = request.document.decodeWith(_rdfCore);
      results.add(await _upload(_storage, request.documentIri, source.graph,
          ifMatch: request.ifMatch));
    }
    return results;
  }

  @override
  Future<List<RemoteDownloadResult<RdfDataset>>> downloadDatasets(
      Iterable<RemoteDownloadRequest> requests) async {
    final results = <RemoteDownloadResult<RdfDataset>>[];
    for (final request in requests) {
      results.add(await _download<RdfDataset>(_storage, request.documentIri,
          ifNoneMatch: request.ifNoneMatch));
    }
    return results;
  }

  @override
  Future<List<RemoteUploadResult>> uploadDatasets(
      Iterable<RemoteUploadRequest<RdfDataset>> requests) async {
    final results = <RemoteUploadResult>[];
    for (final request in requests) {
      results.add(await _upload(_storage, request.documentIri, request.document,
          ifMatch: request.ifMatch));
    }
    return results;
  }

  Future<RemoteUploadResult> _upload<T>(
      InMemoryBackendStore store, IriTerm documentIri, T graph,
      {String? ifMatch}) async {
    _logger.fine('Uploading document: ${documentIri.debug}, ifMatch:$ifMatch');
    final stored = store.getDocument<T>(documentIri);
    // ifMatch: null → If-None-Match: * (create only)
    if (ifMatch == null) {
      if (stored != null) {
        _logger.fine(
            'Document already exists: ${documentIri.debug}, cannot create (ifMatch: $ifMatch)');
        // 409 Conflict - document already exists
        return RemoteUploadResult.conflict();
      }

      // Create new document with new ETag
      final newEtag = store.storeDocument<T>(documentIri, graph);
      _logger.fine('Document created: ${documentIri.debug}, etag:$newEtag');
      return RemoteUploadResult.success(newEtag);
    }

    // ifMatch: <etag> → If-Match: <etag> (update only if unchanged)
    if (stored == null) {
      _logger.fine(
          'Document not found: ${documentIri.debug}, cannot update (ifMatch: $ifMatch)');
      // 412 Precondition Failed - document doesn't exist
      return RemoteUploadResult.conflict();
    }

    if (stored.etag != ifMatch) {
      _logger.fine(
          'ETag mismatch for document: ${documentIri.debug}, cannot update (ifMatch: $ifMatch, currentEtag: ${stored.etag})');
      // 412 Precondition Failed - ETag mismatch
      return RemoteUploadResult.conflict();
    }

    // Update document with new ETag
    final newEtag = store.storeDocument<T>(documentIri, graph);
    _logger.fine('Document updated: ${documentIri.debug}, new etag:$newEtag');
    return RemoteUploadResult.success(newEtag);
  }

  Future<void> delete(IriTerm documentIri, {String? ifMatch}) => _delete(
        _storage,
        documentIri,
        ifMatch: ifMatch,
      );

  Future<void> _delete(InMemoryBackendStore store, IriTerm documentIri,
      {String? ifMatch}) async {
    final stored = store.getDocument(documentIri);

    // If document doesn't exist, delete is idempotent (no-op)
    if (stored == null) {
      return;
    }

    // If-Match provided: check ETag
    if (ifMatch != null && stored.etag != ifMatch) {
      throw Exception('412 Precondition Failed - ETag mismatch on delete');
    }

    // Delete document
    store.deleteDocument(documentIri);
  }
}

/// Per-sync-session storage for in-memory backend.
///
/// Lightweight wrapper around [InMemoryRemoteStorage] providing upload/download
/// access during sync operations.
class InMemorySyncStorage implements PipelineRemoteSyncStorage {
  late final PipelineRemoteSyncStorage _pipelineSupport =
      _pipelineSupportFactory(storage: this);

  final InMemoryBackendStore storage;

  PipelineRemoteSyncStorage Function({required InMemorySyncStorage storage})
      _pipelineSupportFactory;

  InMemorySyncStorage(
      {required this.storage,
      required PipelineRemoteSyncStorage Function(
              {required InMemorySyncStorage storage})
          pipelineSupportFactory})
      : _pipelineSupportFactory = pipelineSupportFactory;

  // ---------------------------------------------------------------------------
  // RemoteSyncPipelineSupport — streaming pipeline transformers
  // ---------------------------------------------------------------------------

  @override
  StreamTransformer<ShardRefEvent, FetchedShardEvent> shardFetch() =>
      _pipelineSupport.shardFetch();

  @override
  StreamTransformer<LoadedCandidateEvent, FetchedCandidateEvent>
      resourceFetch() => _pipelineSupport.resourceFetch();

  @override
  StreamTransformer<MergedResourceEvent, UploadedResourceEvent>
      resourceUpload() => _pipelineSupport.resourceUpload();

  @override
  StreamTransformer<MergedShardEvent, UploadedShardEvent> shardUpload() =>
      _pipelineSupport.shardUpload();

  @override
  Future<void> finalizeSync() async {
    // In-memory backend needs no finalization
  }
}

/// Internal storage structure for documents
class StoredDocument<T> {
  final T data;
  final String etag;

  StoredDocument({
    required this.data,
    required this.etag,
  });
}
