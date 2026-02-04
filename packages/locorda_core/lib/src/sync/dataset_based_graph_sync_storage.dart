import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/storage/remote_storage.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:logging/logging.dart';

final _log = Logger('DatasetBasedGraphSyncStorage');

/// In-memory GraphSyncStorage backed by RdfDataset's named graphs.
///
/// Used in file-per-shard mode to provide graph-level read/write operations
/// on resource documents stored within a dataset's named graphs.
///
/// **Usage Pattern:**
/// 1. Create storage from downloaded dataset: `DatasetBasedGraphSyncStorage(dataset.namedGraphs)`
/// 2. Sync individual resource documents using [download] and [upload]
/// 3. Extract final named graphs for dataset assembly
///
/// **Important:** All operations are in-memory. This storage does not persist
/// to any backend - it's purely a temporary workspace during shard sync.
///
/// **ClockHash-based ETags:**
/// - Uses `cm:clockHash` from documents as ETags for proper versioning
/// - Enables change detection: skip merge if clockHash matches cached value
/// - Consistent with per-resource CRDT versioning semantics
class DatasetBasedGraphSyncStorage extends GraphSyncStorage {
  /// Named graphs mapping document IRIs to their RDF graphs.
  ///
  /// This map is mutated during sync as resource documents are downloaded
  /// (from remote dataset) and uploaded (merged local changes).
  final Map<RdfGraphName, ({String etag, RdfGraph graph})> _namedGraphs;
  Map<RdfGraphName, RdfGraph> get namedGraphs =>
      {for (final entry in _namedGraphs.entries) entry.key: entry.value.graph};

  DatasetBasedGraphSyncStorage(Iterable<RdfNamedGraph> namedGraphs)
      : _namedGraphs = {
          for (final ng in namedGraphs)
            ng.name: (etag: _extractETag(ng.graph, ng.name), graph: ng.graph)
        };

  @override
  Future<RemoteUploadResult> upload(
    IriTerm documentIri,
    RdfGraph graph, {
    String? ifMatch,
  }) async {
    final existing = _namedGraphs[documentIri];

    // Optimistic locking: check ifMatch conditions
    if (ifMatch != null) {
      // Conditional update: only succeed if etag matches
      if (existing == null || existing.etag != ifMatch) {
        // ETag mismatch - document was modified concurrently
        return ConflictUploadResult();
      }
    } else {
      // No ifMatch means we expect to create new document (got 404 on download)
      // If it exists now, it was created concurrently - conflict
      if (existing != null) {
        return ConflictUploadResult();
      }
    }

    // Extract clockHash from uploaded graph to use as ETag
    String etag = _extractETag(graph, documentIri);

    // Store/update the graph in the named graphs map
    _namedGraphs[documentIri] = (etag: etag, graph: graph);

    // Return clockHash as ETag
    return SuccessUploadResult(etag);
  }

  static String _extractETag(RdfGraph graph, RdfSubject documentIri) {
    // Extract clockHash from uploaded graph to use as ETag
    final clockHash = graph
        .expectSingleObject<LiteralTerm>(
          documentIri,
          SyncManagedDocument.crdtClockHash,
        )
        ?.value;

    if (clockHash == null) {
      _log.warning(
          'Document ${documentIri.debug} has no cm:clockHash - this should not happen for managed documents');
    }
    final effectiveClockHash = clockHash ?? 'no-clock-hash';
    return effectiveClockHash;
  }

  @override
  Future<RemoteDownloadResult<RdfGraph>> download(
    IriTerm documentIri, {
    String? ifNoneMatch,
  }) async {
    final res = _namedGraphs[documentIri];

    if (res == null) {
      // Document not found in dataset - equivalent to 404
      return RemoteDownloadResult(graph: null, etag: null, notModified: false);
    }

    // Extract clockHash from the graph to use as ETag
    final etag = res.etag;

    // Check if cached clockHash (ifNoneMatch) matches current clockHash
    // If identical, document hasn't changed - return 304 Not Modified
    if (ifNoneMatch != null && etag == ifNoneMatch) {
      return RemoteDownloadResult(
        graph: null,
        etag: etag,
        notModified: true,
      );
    }

    // Return the graph with its clockHash as ETag
    return RemoteDownloadResult(
      graph: res.graph,
      etag: etag,
      notModified: false,
    );
  }
}
