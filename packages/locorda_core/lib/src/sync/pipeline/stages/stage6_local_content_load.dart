/// Stage 6: Local Content Load — load local graph content from DB for merge.
///
/// **Implementation**: Shard-chunked batch DB reads, capped at [_kBatchSize]
/// per query to stay within SQLite's variable limit.
///
/// **Input**: `Stream<FetchedCandidateEvent>`
/// **Output**: `Stream<LoadedCandidateEvent>`
library;

import 'dart:async';

import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/storage/remote_id.dart';
import 'package:locorda_core/src/storage/storage_interface.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';

/// SQLite SQLITE_MAX_VARIABLE_NUMBER default is 999.
const _kBatchSize = 990; // 990 to leave some headroom for other query variables

/// Returns a StreamTransformer for Stage 6.
///
/// Buffers [FetchedCandidate] events per shard and flushes on each
/// [ShardComplete] / [PhaseComplete] boundary using batch DB queries
/// ([Storage.getDocumentsByIri] + [Storage.getRemoteETags]).
/// Buffers are capped at [_kBatchSize] to respect SQLite's variable limit.
StreamTransformer<FetchedCandidateEvent, LoadedCandidateEvent> localContentLoad(
  Storage storage,
  RemoteId remoteId,
) {
  return StreamTransformer.fromBind((stream) async* {
    final buffer = <FetchedCandidate>[];

    await for (final event in stream) {
      switch (event) {
        case FetchedCandidate():
          buffer.add(event);
          if (buffer.length >= _kBatchSize) {
            yield* _loadChunk(buffer, storage, remoteId);
            buffer.clear();
          }
        case ShardComplete():
          if (buffer.isNotEmpty) {
            yield* _loadChunk(buffer, storage, remoteId);
            buffer.clear();
          }
          yield event;
        case PhaseComplete():
          if (buffer.isNotEmpty) {
            yield* _loadChunk(buffer, storage, remoteId);
            buffer.clear();
          }
          yield event;
      }
    }
  });
}

/// Executes two batch DB queries for [chunk] and yields [LoadedCandidate] events.
Stream<LoadedCandidateEvent> _loadChunk(
  List<FetchedCandidate> chunk,
  Storage storage,
  RemoteId remoteId,
) async* {
  final documentIris =
      chunk.map((e) => e.candidate.resourceIri.getDocumentIri()).toList();

  final docs = await storage.getDocumentsByIri(documentIris);
  final etags = await storage.getRemoteETags(remoteId, documentIris);

  for (final event in chunk) {
    final candidate = event.candidate;
    final documentIri = candidate.resourceIri.getDocumentIri();
    final doc = docs[documentIri];
    final RdfGraphSource? localSource =
        doc != null ? DecodedGraphSource(doc.document) : null;

    switch (candidate.direction) {
      case SyncDirection.remoteRemoved:
        yield LoadedCandidate(
          candidate,
          localSource: localSource,
          localUpdatedAt: doc?.metadata.updatedAt,
        );
      default:
        // FIXME KK: does not look correct. the storage.getRemoteETags call should return the etags we give to stage 5 for fetching remote data, it must not be mixed up with the etag of the fetched remote data
        final etag = event.remoteEtag ?? etags[documentIri];
        yield LoadedCandidate(
          candidate,
          remoteSource: event.remoteSource,
          localSource: localSource,
          localUpdatedAt: doc?.metadata.updatedAt,
          remoteEtag: etag,
        );
    }
  }
}
