import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:logging/logging.dart';

final _logger = Logger('InMemoryBackend');

/// In-memory backend implementation for testing, prototyping, and demos.
///
/// Provides a simple [Backend] with an in-memory [RemoteStorage] that simulates
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
class InMemoryBackend implements Backend {
  @override
  String get name => 'in-memory';

  final List<InMemoryRemoteStorage> _remotes;

  InMemoryBackend()
      : _remotes = [InMemoryRemoteStorage(RemoteId('in-memory', 'default'))];

  @override
  List<InMemoryRemoteStorage> get remotes => _remotes;

  @override
  Future<void> dispose() async {
    // No resources to clean up for in-memory backend
  }
}

/// In-memory implementation of RemoteStorage for testing.
///
/// Provides full ETag support with correct HTTP conditional request semantics:
/// - If-None-Match: * (create only)
/// - If-Match: <etag> (update only if unchanged)
/// - If-None-Match: <etag> (download only if changed)
class InMemoryRemoteStorage implements RemoteStorage {
  @override
  final RemoteId remoteId;

  /// Storage: documentIri -> (graph, etag)
  final Map<String, _StoredDocument> _documents = {};

  /// Counter for generating unique ETags
  int _etagCounter = 0;

  InMemoryRemoteStorage(this.remoteId);

  @override
  Future<bool> isAvailable() async {
    // In-memory storage is always available
    return true;
  }

  @override
  Future<RemoteSyncStorage> createSyncStorage(SyncEngineConfig config) async {
    // In-memory backend needs no initialization, just wrap access
    return InMemorySyncStorage(this);
  }

  /// Generate a new unique ETag
  String _generateETag() {
    return '"etag-${++_etagCounter}"';
  }

  /// Clear all stored documents (for testing)
  void clear() {
    _documents.clear();
    _etagCounter = 0;
  }

  Map<String, _StoredDocument> get documents => _documents;

  /// Check if document exists (for testing)
  bool hasDocument(IriTerm documentIri) {
    return _documents.containsKey(documentIri.value);
  }

  /// Get stored ETag for document (for testing)
  String? getETag(IriTerm documentIri) {
    return _documents[documentIri.value]?.etag;
  }
}

/// Per-sync-session storage for in-memory backend.
///
/// Lightweight wrapper around [InMemoryRemoteStorage] providing upload/download
/// access during sync operations.
class InMemorySyncStorage extends RemoteSyncStorage {
  final InMemoryRemoteStorage _storage;

  InMemorySyncStorage(this._storage);

  @override
  Future<RemoteDownloadResult> download(IriTerm documentIri,
      {String? ifNoneMatch}) async {
    _logger.fine(
        'Downloading document: ${documentIri.debug}, ifNoneMatch:$ifNoneMatch');
    final iri = documentIri.value;
    final stored = _storage._documents[iri];

    // Document doesn't exist
    if (stored == null) {
      _logger.fine('Document not found: ${documentIri.debug}');
      return RemoteDownloadResult(
        dataset: null,
        etag: null,
        notModified: false,
      );
    }

    // If-None-Match: check if document changed
    if (ifNoneMatch != null && ifNoneMatch == stored.etag) {
      _logger.fine('Document not modified: ${documentIri.debug}');
      // 304 Not Modified
      return RemoteDownloadResult.notModified(etag: stored.etag);
    }

    _logger.fine(
        'Document downloaded: ${documentIri.debug}, etag:${stored.etag}, ifNoneMatch:$ifNoneMatch');
    // 200 OK - return document
    return RemoteDownloadResult(
      dataset: stored.dataset,
      etag: stored.etag,
      notModified: false,
    );
  }

  @override
  Future<RemoteUploadResult> upload(IriTerm documentIri, RdfDataset dataset,
      {String? ifMatch}) async {
    _logger.fine(
        'Uploading document: ${documentIri.debug}, ifMatch:$ifMatch, default graph size: ${dataset.defaultGraph.triples.length}');
    final iri = documentIri.value;
    final stored = _storage._documents[iri];

    // ifMatch: null → If-None-Match: * (create only)
    if (ifMatch == null) {
      if (stored != null) {
        _logger.fine(
            'Document already exists: ${documentIri.debug}, cannot create (ifMatch: $ifMatch)');
        // 409 Conflict - document already exists
        return RemoteUploadResult.conflict();
      }

      // Create new document with new ETag
      final newEtag = _storage._generateETag();
      _storage._documents[iri] =
          _StoredDocument(dataset: dataset, etag: newEtag);
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
    final newEtag = _storage._generateETag();
    _storage._documents[iri] = _StoredDocument(dataset: dataset, etag: newEtag);
    _logger.fine('Document updated: ${documentIri.debug}, new etag:$newEtag');
    return RemoteUploadResult.success(newEtag);
  }

  @override
  Future<void> finalizeSync() async {
    // In-memory backend needs no finalization
  }

  Future<void> delete(IriTerm documentIri, {String? ifMatch}) async {
    final iri = documentIri.value;
    final stored = _storage._documents[iri];

    // If document doesn't exist, delete is idempotent (no-op)
    if (stored == null) {
      return;
    }

    // If-Match provided: check ETag
    if (ifMatch != null && stored.etag != ifMatch) {
      throw Exception('412 Precondition Failed - ETag mismatch on delete');
    }

    // Delete document
    _storage._documents.remove(iri);
  }
}

/// Internal storage structure for documents
class _StoredDocument {
  final RdfDataset dataset;
  final String etag;

  _StoredDocument({
    required this.dataset,
    required this.etag,
  });
}
