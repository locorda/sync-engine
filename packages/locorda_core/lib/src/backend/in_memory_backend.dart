import 'dart:async';

import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/storage/remote_storage.dart'
    show PipelineRemoteStorage, RemoteDownloadRequest, RemoteUploadRequest;
import 'package:locorda_core/src/sync/pipeline/backend/remote_sync_backend.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_support.dart';
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
    final mode =
        RemoteStorageMode.fromFlags(useShardDatasets: useShardDatasets);
    final contentType = mode.defaultContentType;
    final isBinary = isBinaryContentType(contentType);
    final backend = _InMemorySyncBackend(
      storage: _store,
      rdfCore: _rdfCore,
      contentType: contentType,
      isBinary: isBinary,
    );
    if (iriTranslator != null) {
      return RemoteSyncStorages.createIriTranslated(
          mode: mode,
          contentType: contentType,
          backend: backend,
          rdfCore: _rdfCore,
          resourceGraphLoader: _resourceGraphLoader,
          translator: iriTranslator!,
          isBinary: isBinary);
    }
    return RemoteSyncStorages.create(
      mode: mode,
      backend: backend,
      rdfCore: _rdfCore,
      resourceGraphLoader: _resourceGraphLoader,
      contentType: contentType,
      isBinary: isBinary,
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
  final bool _isBinary;
  _InMemorySyncBackend({
    required InMemoryBackendStore storage,
    required RdfCore rdfCore,
    required String contentType,
    bool? isBinary,
  })  : _storage = storage,
        _rdfCore = rdfCore,
        _contentType = contentType,
        _isBinary = isBinary ?? isBinaryContentType(contentType);

  @override
  Stream<RemoteDownloadResult<RawContent>> download(
      Stream<RemoteDownloadRequest> requests) {
    return requests.asyncMap((request) async {
      _logger.fine(
          'Downloading document: ${request.documentIri.debug}, ifNoneMatch:${request.ifNoneMatch}');

      // Try as RdfGraph first (FPR mode), then as RdfDataset (SDS mode).
      final stored = _storage.getDocument(request.documentIri);

      if (stored == null) {
        _logger.fine('Document not found: ${request.documentIri.debug}');
        return RemoteDownloadResult<RawContent>(
          graph: null,
          etag: null,
          notModified: false,
        );
      }

      if (request.ifNoneMatch != null && request.ifNoneMatch == stored.etag) {
        _logger.fine('Document not modified: ${request.documentIri.debug}');
        return RemoteDownloadResult<RawContent>.notModified(etag: stored.etag);
      }

      _logger.fine(
          'Document downloaded: ${request.documentIri.debug}, etag:${stored.etag}');

      // Encode stored data to raw content for the pipeline.
      final RawContent content;
      final data = stored.data;
      if (data is RdfGraph) {
        if (_isBinary) {
          final encodedBytes =
              _rdfCore.encodeBinary(data, contentType: _contentType);
          content = BinaryContent(encodedBytes, contentType: _contentType);
        } else {
          final text = _rdfCore.encode(data, contentType: _contentType);
          content = TextContent(text, contentType: _contentType);
        }
      } else if (data is RdfDataset) {
        if (_isBinary) {
          final encodedBytes =
              _rdfCore.encodeBinaryDataset(data, contentType: _contentType);
          content = BinaryContent(encodedBytes, contentType: _contentType);
        } else {
          final text = _rdfCore.encodeDataset(data, contentType: _contentType);
          content = TextContent(text, contentType: _contentType);
        }
      } else {
        throw StateError('Unknown stored data type: ${data.runtimeType}');
      }

      return RemoteDownloadResult<RawContent>(
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
      final ct = raw.contentType;

      // Heuristic: dataset formats → RdfDataset, otherwise → RdfGraph.
      if (isDatasetContentType(ct)) {
        data = switch (raw) {
          TextContent(:final text) =>
            _rdfCore.decodeDataset(text, contentType: ct),
          BinaryContent(:final bytes) =>
            _rdfCore.decodeBinaryDataset(bytes, contentType: ct),
        };
      } else {
        data = switch (raw) {
          TextContent(:final text) => _rdfCore.decode(text, contentType: ct),
          BinaryContent(:final bytes) =>
            _rdfCore.decodeBinary(bytes, contentType: ct),
        };
      }

      return _uploadData(request.documentIri, data, ifMatch: request.ifMatch);
    });
  }

  RemoteUploadResult _uploadData(IriTerm documentIri, Object data,
      {String? ifMatch}) {
    final stored = _storage.getDocument(documentIri);

    if (ifMatch == null) {
      if (stored != null) {
        _logger.fine(
            'Document already exists: ${documentIri.debug}, cannot create');
        return RemoteUploadResult.conflict();
      }
      final newEtag = _storage.storeDocument(documentIri, data);
      _logger.fine('Document created: ${documentIri.debug}, etag:$newEtag');
      return RemoteUploadResult.success(newEtag);
    }

    if (stored == null) {
      _logger.fine('Document not found: ${documentIri.debug}, cannot update');
      return RemoteUploadResult.conflict();
    }

    if (stored.etag != ifMatch) {
      _logger.fine(
          'ETag mismatch for document: ${documentIri.debug}, cannot update (ifMatch: $ifMatch, currentEtag: ${stored.etag})');
      return RemoteUploadResult.conflict();
    }

    final newEtag = _storage.storeDocument(documentIri, data);
    _logger.fine('Document updated: ${documentIri.debug}, new etag:$newEtag');
    return RemoteUploadResult.success(newEtag);
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
