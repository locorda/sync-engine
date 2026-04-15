/// Service that intercepts document saves for index-type resources and
/// persists shard membership to the [Storage.saveIndexShards] API.
///
/// Acts as a transparency wrapper around [Storage.saveDocument] /
/// [Storage.saveDocuments]: callers that save non-index documents see no
/// difference.  For [IdxFullIndex] and [IdxGroupIndex] documents the service
/// additionally extracts `idx:hasShard` triples from the post-merge graph and
/// calls [Storage.saveIndexShards] so that Stage 1 can resolve shards via a
/// cheap DB query instead of parsing full RDF documents at runtime.
library;

import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_rdf_core/core.dart';

/// Wraps [Storage] to automatically populate the `index_shards` table whenever
/// an [IdxFullIndex] or [IdxGroupIndex] document is saved.
///
/// The service extracts `idx:hasShard` triples from the merged RDF graph and
/// delegates to [Storage.saveIndexShards] with full-replace semantics, which
/// matches the post-CRDT-merge OR-Set state stored in the graph.
class DocumentSaveService {
  final Storage _storage;

  DocumentSaveService(this._storage);

  static bool _isIndexType(IriTerm typeIri) =>
      typeIri == IdxFullIndex.classIri || typeIri == IdxGroupIndex.classIri;

  /// Save a single document, updating the shard index table if applicable.
  Future<SaveDocumentResult> saveDocument(SaveDocumentRequest request) async {
    final result = await _storage.saveDocument(
      request.documentIri,
      request.typeIri,
      request.document,
      request.metadata,
      request.changes,
      ifMatchUpdatedAt: request.ifMatchUpdatedAt,
    );
    await _saveIndexShardsIfNeeded([request]);
    return result;
  }

  /// Save multiple documents, updating the shard index table for any index-type
  /// documents in the batch.
  Future<List<SaveDocumentResult>> saveDocuments(
    Iterable<SaveDocumentRequest> requests,
  ) async {
    final requestList = requests is List<SaveDocumentRequest>
        ? requests
        : requests.toList(growable: false);
    final results = await _storage.saveDocuments(requestList);
    await _saveIndexShardsIfNeeded(requestList);
    return results;
  }

  /// Scans [requests] for index documents and calls [Storage.saveIndexShards]
  /// once with all found entries, replacing each stored shard set atomically.
  Future<void> _saveIndexShardsIfNeeded(
      Iterable<SaveDocumentRequest> requests) async {
    final indexShards = <(IriTerm, List<IriTerm>)>[];
    for (final request in requests) {
      if (!_isIndexType(request.typeIri)) continue;
      final indexIri = request.document.getIdentifier(request.typeIri);
      final shardIris = request.document
          .getMultiValueObjectList<IriTerm>(indexIri, IdxIndex.hasShard);
      indexShards.add((indexIri, shardIris));
    }
    if (indexShards.isEmpty) return;
    await _storage.saveIndexShards(indexShards);
  }
}
