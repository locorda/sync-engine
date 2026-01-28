import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_rdf_core/core.dart';

/// Result of a remote download operation with ETag support.
class RemoteDownloadResult {
  final RdfGraph? graph;
  final String? etag;
  final bool notModified; // true if 304 Not Modified

  RemoteDownloadResult({
    required this.graph,
    required this.etag,
    this.notModified = false,
  });

  RemoteDownloadResult.notModified({required this.etag})
      : graph = null,
        notModified = true;
}

/// Result of a remote upload operation with ETag support.
sealed class RemoteUploadResult {
  const RemoteUploadResult();

  factory RemoteUploadResult.conflict() {
    return const ConflictUploadResult();
  }
  factory RemoteUploadResult.success(String etag) {
    return SuccessUploadResult(etag);
  }
}

final class ConflictUploadResult extends RemoteUploadResult {
  const ConflictUploadResult();
}

final class SuccessUploadResult extends RemoteUploadResult {
  final String etag;
  const SuccessUploadResult(this.etag);
}

/// Session-specific sync storage with cached state.
///
/// Created per sync session by [RemoteStorage.createSyncStorage].
/// Holds configuration-derived state (e.g., type mappings, folder IDs) for
/// efficient document operations during sync.
///
/// **Lifecycle:**
/// 1. Created before sync via [RemoteStorage.createSyncStorage]
/// 2. Used for all [upload]/[download] operations during sync
/// 3. [finalizeSync] called after sync completion (success or failure)
/// 4. Discarded after sync
///
/// **Important IRI Semantics:**
/// All operations work with **Locorda internal resource IRIs** using the
/// `tag:locorda.org,2025:l:` URI scheme. These are framework-standardized
/// identifiers used throughout Locorda for resource identification, hash
/// calculations, and CRDT operations.
///
/// Backend implementations may or may not transform these internal IRIs to
/// backend-specific locations (e.g., Solid backends transform to Pod-specific URLs)
/// internally. When transformation occurs, the RdfGraph content uses the same
/// internal IRIs and must also be transformed accordingly.
///
/// **Transformation Contract (when applicable):**
/// - **Upload**: Transform internal tag IRIs → backend-specific IRIs before sending
/// - **Download**: Transform backend-specific IRIs → internal tag IRIs before returning
/// - **Round-trip guarantee**: Data flowing in/out ALWAYS uses internal tag IRIs
///
/// **HTTP Semantics:**
/// Implementations should support:
/// - Conditional GET (If-None-Match header for ETags)
/// - Conditional PUT (If-Match header for ETags)
/// - HTTP status codes: 200, 304 Not Modified, 412 Precondition Failed
abstract interface class RemoteSyncStorage {
  /// Upload a document to remote storage.
  ///
  /// The implementation may transform the internal document IRI and RDF graph
  /// to backend-specific format before uploading.
  ///
  /// **Conditional Upload Semantics:**
  /// - `ifMatch: null` → Use "If-None-Match: *" (create only, fail if exists)
  /// - `ifMatch: "<etag>"` → Use "If-Match: <etag>" (update only, fail if changed)
  ///
  /// Parameters:
  /// - [documentIri]: Internal Locorda document IRI (tag:locorda.org,2025:l:...)
  /// - [graph]: RDF graph using internal IRIs
  /// - [ifMatch]: ETag for conditional upload, or null for create-only semantics
  ///
  /// Returns upload result with new ETag, or conflict=true on 409/412.
  Future<RemoteUploadResult> upload(IriTerm documentIri, RdfGraph graph,
      {String? ifMatch});

  /// Download a document from remote storage.
  ///
  /// The implementation may transform backend-specific IRIs back to internal
  /// Locorda document IRIs before returning the graph.
  ///
  /// Parameters:
  /// - [documentIri]: Internal Locorda document IRI (tag:locorda.org,2025:l:...)
  /// - [ifNoneMatch]: Optional ETag for conditional download (304 if unchanged)
  ///
  /// Returns download result with graph using internal IRIs, plus ETag.
  Future<RemoteDownloadResult> download(IriTerm documentIri,
      {String? ifNoneMatch});

  /// Finalize sync operations and perform cleanup.
  ///
  /// Called after sync completion (success or failure). Implementations can:
  /// - Flush pending operations
  /// - Update metadata or statistics
  /// - Release resources
  ///
  /// This is optional - default implementation does nothing.
  Future<void> finalizeSync() async {}
}

/// Abstract interface for remote storage backend setup.
///
/// **Lifecycle:**
/// 1. [isAvailable] - Check if backend is accessible/authenticated
/// 2. [createSyncStorage] - Create session-specific storage before each sync
///
/// **Purpose:**
/// This interface handles backend initialization and creates stateful
/// [RemoteSyncStorage] instances that cache configuration-derived state
/// (e.g., type index mappings, folder IDs) for efficient sync operations.
abstract interface class RemoteStorage {
  /// Remote endpoint identifier for this storage backend
  RemoteId get remoteId;

  /// Check if remote storage is available/authenticated.
  ///
  /// Called before sync to determine if sync should be attempted.
  /// Returns false if backend is offline, unauthenticated, or unavailable.
  Future<bool> isAvailable();

  /// Create a new sync storage session with cached configuration state.
  ///
  /// Called once at the start of each sync cycle. The returned [RemoteSyncStorage]
  /// can cache configuration-derived state for efficient document operations.
  ///
  /// **Backend-specific setup examples:**
  /// - **GDrive**: Load/update gdrive-index.ttl, cache folder ID mappings
  /// - **Solid**: Verify Pod access, prepare IRI translators
  /// - **InMemory**: No setup needed, return lightweight wrapper
  ///
  /// The [config] provides access to all registered resource types and their
  /// index configurations.
  ///
  /// Throws if backend cannot be initialized (e.g., auth failure, missing config).
  Future<RemoteSyncStorage> createSyncStorage(SyncEngineConfig config);
}
