import 'dart:async';

import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_support.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:logging/logging.dart';
import 'package:rxdart/rxdart.dart';

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
  final BehaviorSubject<List<RemoteStorage>> _remotesChangedSubject;
  final IriTranslator? iriTranslator;

  InMemoryBackend({bool useShardDatasets = false, this.iriTranslator})
      : _remotes = [
          InMemoryRemoteStorage(
            RemoteId('in-memory', 'default'),
            useShardDatasets: useShardDatasets,
            iriTranslator: iriTranslator,
          )
        ],
        _remotesChangedSubject = BehaviorSubject<List<RemoteStorage>>() {
    // Emit initial state
    _remotesChangedSubject.add(_remotes);
  }

  @override
  List<InMemoryRemoteStorage> get remotes => _remotes;

  @override
  Stream<List<RemoteStorage>> get remotesChanged =>
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
class InMemoryRemoteStorage implements RemoteStorage {
  @override
  final RemoteId remoteId;
  @override
  final bool useShardDatasets;
  final IriTranslator? iriTranslator;

  /// Storage: documentIri -> (graph, etag)
  late final _Store _store = _Store();

  InMemoryRemoteStorage(this.remoteId,
      {this.useShardDatasets = false, this.iriTranslator});

  /// Returns a stored graph for testing purposes.
  ///
  /// This bypasses remote sync semantics and should only be used in tests.
  RdfGraph? getStoredGraph(IriTerm documentIri) {
    return _store.getDocument<RdfGraph>(documentIri)?.data;
  }

  /// Returns a stored dataset for testing purposes.
  ///
  /// This bypasses remote sync semantics and should only be used in tests.
  RdfDataset? getStoredDataset(IriTerm documentIri) {
    return _store.getDocument<RdfDataset>(documentIri)?.data;
  }

  /// Returns all stored documents for testing purposes.
  ///
  /// This bypasses remote sync semantics and should only be used in tests.
  List<RemoteStoredDocument> getStoredDocumentsForTesting() {
    return _store
        .getAllDocuments()
        .entries
        .map((entry) => RemoteStoredDocument(
            documentIri: entry.key, data: entry.value.data))
        .toList();
  }

  @override
  Future<bool> isAvailable() async {
    // In-memory storage is always available
    return true;
  }

  @override
  Future<RemoteSyncStorage> createSyncStorage(SyncEngineConfig config) async {
    // In-memory backend needs no initialization, just wrap access
    final storage = InMemorySyncStorage(storage: _store);

    return iriTranslator == null
        ? storage
        : IriTranslatingRemoteSyncStorage(
            storage: storage, iriTranslator: iriTranslator!);
  }

  /// Clear all stored documents (for testing)
  void clear() {
    _store.clear();
  }

  @override
  Future<void> dispose() async {
    // No resources to dispose in in-memory backend
  }
}

class _Store {
  /// Counter for generating unique ETags
  int _etagCounter = 0;

  /// Storage: documentIri -> (graph, etag)
  final Map<String, _StoredDocument> _documents = {};

  _Store();

  /// Clear all stored documents (for testing)
  void clear() {
    _etagCounter = 0;
    _documents.clear();
  }

  /// Generate a new unique ETag
  String _generateETag() => '"etag-${++_etagCounter}"';

  /// Returns a snapshot of all documents for testing purposes.
  Map<IriTerm, _StoredDocument> getAllDocuments() {
    return _documents.map(
      (key, value) => MapEntry(IriTerm(key), value),
    );
  }

  //Map<String, _StoredDocument<T>> get documents => _documents;
  _StoredDocument<T>? getDocument<T>(IriTerm documentIri) {
    return _documents[documentIri.value] as _StoredDocument<T>?;
  }

  void deleteDocument(IriTerm documentIri) {
    _documents.remove(documentIri.value);
  }

  String storeDocument<T>(IriTerm documentIri, T data) {
    final newEtag = _generateETag();
    _documents[documentIri.value] =
        _StoredDocument<T>(data: data, etag: newEtag);
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

/// Per-sync-session storage for in-memory backend.
///
/// Lightweight wrapper around [InMemoryRemoteStorage] providing upload/download
/// access during sync operations.
class InMemorySyncStorage extends RemoteSyncStorage
    implements RemoteSyncPipelineSupport {
  final _Store _storage;

  InMemorySyncStorage({required _Store storage}) : _storage = storage;

  @override
  Future<RemoteDownloadResult<RdfGraph>> download(IriTerm documentIri,
      {String? ifNoneMatch}) async {
    final result = await _download<RdfGraph>(
      _storage,
      documentIri,
      ifNoneMatch: ifNoneMatch,
    );
    return result.copyWith(
      graph: result.graph != null ? result.graph! : null,
    );
  }

  @override
  Future<RemoteDownloadResult<RdfDataset>> downloadDataset(IriTerm documentIri,
      {String? ifNoneMatch}) async {
    final result = await _download<RdfDataset>(
      _storage,
      documentIri,
      ifNoneMatch: ifNoneMatch,
    );
    return result.copyWith(
      graph: result.graph != null ? result.graph! : null,
    );
  }

  Future<RemoteDownloadResult<T>> _download<T>(
      _Store store, IriTerm documentIri,
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
  Future<RemoteUploadResult> upload(IriTerm documentIri, RdfGraph graph,
          {String? ifMatch}) =>
      _upload(
        _storage,
        documentIri,
        graph,
        ifMatch: ifMatch,
      );

  @override
  Future<RemoteUploadResult> uploadDataset(
          IriTerm documentIri, RdfDataset dataset,
          {String? ifMatch}) =>
      _upload(
        _storage,
        documentIri,
        dataset,
        ifMatch: ifMatch,
      );

  Future<RemoteUploadResult> _upload<T>(
      _Store store, IriTerm documentIri, T graph,
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

  // ---------------------------------------------------------------------------
  // RemoteSyncPipelineSupport — streaming pipeline transformers
  // ---------------------------------------------------------------------------

  @override
  StreamTransformer<Object, Object> shardFetch() =>
      _asyncSafeTransformer((event) async* {
        if (event is Boundary) {
          yield event;
          return;
        }
        final ref = event as ShardRef;
        final docIri = ref.shardIri.getDocumentIri();
        final result = await download(
          docIri,
          ifNoneMatch: ref.storedEtag,
        );

        if (result.notModified) {
          yield ShardNotModified(
              ref.shardIri, ref.shardStorageId, ref.fetchPolicy, ref.typeIri);
        } else if (result.graph == null && ref.storedEtag != null) {
          yield ShardGone(
              ref.shardIri, ref.shardStorageId, ref.fetchPolicy, ref.typeIri);
        } else if (result.graph == null) {
          yield ShardNotModified(
              ref.shardIri, ref.shardStorageId, ref.fetchPolicy, ref.typeIri,
              existsOnRemote: false);
        } else {
          yield ShardContent(
            ref.shardIri,
            ref.shardStorageId,
            ref.fetchPolicy,
            ref.typeIri,
            DecodedGraphSource(result.graph!),
            result.etag!,
          );
        }
      });

  @override
  StreamTransformer<Object, Object> resourceFetch() =>
      _asyncSafeTransformer((event) async* {
        if (event is Boundary) {
          yield event;
          return;
        }
        final candidate = event as SyncCandidate;

        if (candidate.direction == SyncDirection.localOnly ||
            candidate.direction == SyncDirection.remoteRemoved) {
          yield FetchedCandidate(candidate);
          return;
        }

        final result = await download(candidate.resourceIri.getDocumentIri());
        if (result.graph != null) {
          yield FetchedCandidate(
            candidate,
            remoteSource: DecodedGraphSource(result.graph!),
            remoteEtag: result.etag,
          );
        } else {
          yield FetchedCandidate(candidate);
        }
      });

  @override
  StreamTransformer<Object, Object> resourceUpload() =>
      _asyncSafeTransformer((event) async* {
        if (event is Boundary) {
          yield event;
          return;
        }
        final mergeResult = event as MergeResult;

        if (!mergeResult.needsUpload) {
          yield UploadResult(mergeResult);
          return;
        }

        final documentIri = mergeResult.resourceIri.getDocumentIri();
        final result = await upload(
          documentIri,
          mergeResult.mergedGraph.graph,
          ifMatch: mergeResult.resourceEtag,
        );

        if (result is SuccessUploadResult) {
          yield UploadResult(mergeResult, newRemoteEtag: result.etag);
        } else {
          _logger.warning(
              'Upload conflict for ${documentIri.debug} — skipping');
          yield UploadResult(mergeResult);
        }
      });

  @override
  StreamTransformer<Object, Object> shardUpload() =>
      _asyncSafeTransformer((event) async* {
        if (event is Boundary) {
          yield event;
          return;
        }
        final merged = event as MergedShard;

        if (!merged.needsUpload) {
          yield UploadedShard(merged.shardIri, merged);
          return;
        }

        final documentIri = merged.shardIri.getDocumentIri();
        final result = await upload(
          documentIri,
          merged.mergedGraph.graph,
          ifMatch: merged.newEtag,
        );

        if (result is SuccessUploadResult) {
          yield UploadedShard(merged.shardIri, merged,
              newRemoteEtag: result.etag);
        } else {
          _logger.warning(
              'Shard upload conflict for ${documentIri.debug} — skipping');
          yield UploadedShard(merged.shardIri, merged);
        }
      });

  @override
  Future<void> finalizeSync() async {
    // In-memory backend needs no finalization
  }

  Future<void> delete(IriTerm documentIri, {String? ifMatch}) => _delete(
        _storage,
        documentIri,
        ifMatch: ifMatch,
      );

  Future<void> _delete(_Store store, IriTerm documentIri,
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

/// Internal storage structure for documents
class _StoredDocument<T> {
  final T data;
  final String etag;

  _StoredDocument({
    required this.data,
    required this.etag,
  });
}

/// Creates a [StreamTransformer] from an asyncExpand-style handler.
///
/// Unlike [StreamTransformer.fromHandlers] with an async `handleData`,
/// this ensures each event is fully processed before the next one starts,
/// preventing boundary events from overtaking pending async results.
StreamTransformer<Object, Object> _asyncSafeTransformer(
    Stream<Object> Function(Object event) handler) {
  return StreamTransformer.fromBind(
      (stream) => stream.asyncExpand(handler));
}
