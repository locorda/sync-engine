import 'dart:async';

import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
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
    RemoteStorageLayout layout = const FilePerResource(),
    this.iriTranslator,
    required RdfCore rdfCore,
    required BackendStorageAccessFactory storageAccessFactory,
    required InMemoryBackendStore store,
  })  : _remotes = [
          InMemoryRemoteStorage(
            RemoteId('in-memory', 'default'),
            layout: layout,
            iriTranslator: iriTranslator,
            rdfCore: rdfCore,
            storageAccessFactory: storageAccessFactory,
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

/// In-memory implementation of PipelineRemoteStorage for testing.
///
/// Provides full ETag support with correct HTTP conditional request semantics:
/// - If-None-Match: * (create only)
/// - If-Match: <etag> (update only if unchanged)
/// - If-None-Match: <etag> (download only if changed)
class InMemoryRemoteStorage implements PipelineRemoteStorage {
  @override
  final RemoteId remoteId;

  final RemoteStorageLayout _layout;
  final IriTranslator? iriTranslator;
  final RdfCore _rdfCore;
  final BackendStorageAccess _storageAccess;

  /// Storage: documentIri -> (graph, etag)
  final InMemoryBackendStore _store;

  InMemoryRemoteStorage(
    this.remoteId, {
    RemoteStorageLayout layout = const FilePerResource(),
    this.iriTranslator,
    required RdfCore rdfCore,
    required BackendStorageAccessFactory storageAccessFactory,
    required InMemoryBackendStore store,
  })  : _layout = layout,
        _rdfCore = rdfCore,
        _storageAccess = storageAccessFactory.forRemote(remoteId),
        _store = store;

  @override
  Future<bool> isAvailable() async {
    // In-memory storage is always available
    return true;
  }

  @override
  Future<PipelineRemoteSyncStorage> createPipelineSyncStorage(
      SyncEngineConfig config) async {
    final backend = _InMemorySyncBackend(
      storage: _store,
      rdfCore: _rdfCore,
      contentType: _layout.contentType,
    );
    if (iriTranslator != null) {
      return RemoteSyncStorages.createIriTranslated(
          layout: _layout,
          backend: backend,
          rdfCore: _rdfCore,
          storageAccess: _storageAccess,
          translator: iriTranslator!);
    }
    return RemoteSyncStorages.create(
      layout: _layout,
      backend: backend,
      rdfCore: _rdfCore,
      storageAccess: _storageAccess,
    );
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

class _InMemorySyncBackend implements RemoteSyncBackend {
  final InMemoryBackendStore _storage;
  final RdfCore _rdfCore;
  final String _contentType;
  final bool _isDataset;
  final bool _isBinary;
  _InMemorySyncBackend({
    required InMemoryBackendStore storage,
    required RdfCore rdfCore,
    required String contentType,
  })  : _storage = storage,
        _rdfCore = rdfCore,
        _contentType = contentType,
        _isBinary = rdfCore.contentTypeInfo(contentType)?.isBinary ?? false,
        _isDataset =
            rdfCore.contentTypeInfo(contentType)?.supportsDataset ?? false;

  @override
  Stream<RemoteDownloadResult<RawContent>> download(
      Stream<RemoteDownloadRequest> requests) {
    return requests.asyncMap((request) async {
      _logger.fine(
          'Downloading document: ${request.documentIri.debug}, ifNoneMatch:${request.ifNoneMatch}');

      final stored = _storage.getDocument(request.documentIri);

      if (stored == null) {
        _logger.fine('Document not found: ${request.documentIri.debug}');
        return RemoteDownloadResult<RawContent>(
          documentIri: request.documentIri,
          requestETag: request.ifNoneMatch,
          graph: null,
          etag: null,
          notModified: false,
        );
      }

      if (request.ifNoneMatch != null && request.ifNoneMatch == stored.etag) {
        _logger.fine('Document not modified: ${request.documentIri.debug}');
        return RemoteDownloadResult<RawContent>.notModified(
          documentIri: request.documentIri,
          requestETag: request.ifNoneMatch,
          etag: stored.etag,
        );
      }

      _logger.fine(
          'Document downloaded: ${request.documentIri.debug}, etag:${stored.etag}');

      // Encode stored data to raw content for the pipeline.
      // Real backends actually store the encoded content and not the decoded
      // graph/dataset as we do, you will probably not see any other backend than the
      // in-memory one doing this dance here.
      final RawContent content;
      final data = stored.data;
      if (_isDataset) {
        if (_isBinary) {
          final encodedBytes = _rdfCore.encodeBinaryDataset(data as RdfDataset,
              contentType: _contentType);
          content = BinaryContent(encodedBytes, contentType: _contentType);
        } else {
          final text = _rdfCore.encodeDataset(data as RdfDataset,
              contentType: _contentType);
          content = TextContent(text, contentType: _contentType);
        }
      } else {
        if (_isBinary) {
          final encodedBytes = _rdfCore.encodeBinary(data as RdfGraph,
              contentType: _contentType);
          content = BinaryContent(encodedBytes, contentType: _contentType);
        } else {
          final text =
              _rdfCore.encode(data as RdfGraph, contentType: _contentType);
          content = TextContent(text, contentType: _contentType);
        }
      }

      return RemoteDownloadResult<RawContent>(
        documentIri: request.documentIri,
        requestETag: request.ifNoneMatch,
        graph: content,
        etag: stored.etag,
        notModified: false,
      );
    });
  }

  @override
  Stream<RemoteUploadResult> upload(
      Stream<RemoteUploadRequest<RawContent>> requests) {
    return requests.asyncMap((request) async {
      _logger.fine(
          'Uploading document: ${request.documentIri.debug}, ifMatch:${request.ifMatch}');

      // Decode raw content to the appropriate type for storage.
      final raw = request.document;
      final Object data;
      if (_isDataset) {
        data = switch (raw) {
          TextContent(:final text) =>
            _rdfCore.decodeDataset(text, contentType: _contentType),
          BinaryContent(:final bytes) =>
            _rdfCore.decodeBinaryDataset(bytes, contentType: _contentType),
        };
      } else {
        data = switch (raw) {
          TextContent(:final text) =>
            _rdfCore.decode(text, contentType: _contentType),
          BinaryContent(:final bytes) =>
            _rdfCore.decodeBinary(bytes, contentType: _contentType),
        };
      }

      return _uploadData(request.documentIri, data, ifMatch: request.ifMatch);
    });
  }

  @override
  Future<void> finalize(SyncFinalizationState state,
      {PipeperfCollector? perf}) async {}

  RemoteUploadResult _uploadData(IriTerm documentIri, Object data,
      {String? ifMatch}) {
    final stored = _storage.getDocument(documentIri);

    if (ifMatch == null) {
      if (stored != null) {
        _logger.fine(
            'Document already exists: ${documentIri.debug}, cannot create');
        return RemoteUploadResult.conflict(
          documentIri: documentIri,
          requestETag: ifMatch,
        );
      }
      final newEtag = _storage.storeDocument(documentIri, data);
      _logger.fine('Document created: ${documentIri.debug}, etag:$newEtag');
      return RemoteUploadResult.success(
        newEtag,
        documentIri: documentIri,
        requestETag: ifMatch,
      );
    }

    if (stored == null) {
      _logger.fine('Document not found: ${documentIri.debug}, cannot update');
      return RemoteUploadResult.conflict(
        documentIri: documentIri,
        requestETag: ifMatch,
      );
    }

    if (stored.etag != ifMatch) {
      _logger.fine(
          'ETag mismatch for document: ${documentIri.debug}, cannot update (ifMatch: $ifMatch, currentEtag: ${stored.etag})');
      return RemoteUploadResult.conflict(
        documentIri: documentIri,
        requestETag: ifMatch,
      );
    }

    final newEtag = _storage.storeDocument(documentIri, data);
    _logger.fine('Document updated: ${documentIri.debug}, new etag:$newEtag');
    return RemoteUploadResult.success(
      newEtag,
      documentIri: documentIri,
      requestETag: ifMatch,
    );
  }

  Future<void> delete(IriTerm documentIri, {String? ifMatch}) async {
    final stored = _storage.getDocument(documentIri);
    if (stored == null) return;
    if (ifMatch != null && stored.etag != ifMatch) {
      throw Exception('412 Precondition Failed - ETag mismatch on delete');
    }
    _storage.deleteDocument(documentIri);
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
