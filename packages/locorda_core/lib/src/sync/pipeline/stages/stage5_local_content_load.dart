/// Stage 5: Local Content Load — load local graph content and stored ETags
/// from DB.
///
/// **Implementation**: Shard-chunked batch DB reads, capped at [_kBatchSize]
/// per query to stay within SQLite's variable limit.
///
/// **Input**: `Stream<SyncCandidateEvent>`
/// **Output**: `Stream<LoadedCandidateEvent>`
library;

import 'dart:async';

import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/storage/remote_id.dart';
import 'package:locorda_core/src/storage/storage_interface.dart';
import 'package:locorda_core/src/sync/pipeline/pipeperf.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';

/// SQLite SQLITE_MAX_VARIABLE_NUMBER default is 999; [defaultPipelineBatchSize]
/// provides headroom.

/// Returns a StreamTransformer for Stage 5.
///
/// Buffers [SyncCandidate] events and flushes on each
/// [ShardComplete] / [PhaseComplete] boundary using batch DB queries
/// ([Storage.getDocumentsByIri] + [Storage.getRemoteETags]).
/// Buffers are capped at [batchSize] to respect SQLite's variable limit.
StreamTransformer<SyncCandidateEvent, LoadedCandidateEvent> localContentLoad(
  Storage storage,
  RemoteId remoteId, {
  int batchSize = defaultPipelineBatchSize,
  PipeperfCollector? perf,
  String perfStage = 'S5.LocalLoad',
}) {
  return StreamTransformer.fromBind((stream) async* {
    final buffer = <SyncCandidate>[];

    await for (final event in stream) {
      switch (event) {
        case SyncCandidate():
          buffer.add(event);
          if (buffer.length >= batchSize) {
            yield* _loadChunk(buffer, storage, remoteId, perf, perfStage);
            buffer.clear();
          }
        case ShardComplete():
          if (buffer.isNotEmpty) {
            yield* _loadChunk(buffer, storage, remoteId, perf, perfStage);
            buffer.clear();
          }
          yield event;
        case PhaseComplete():
          if (buffer.isNotEmpty) {
            yield* _loadChunk(buffer, storage, remoteId, perf, perfStage);
            buffer.clear();
          }
          yield event;
      }
    }
  });
}

/// Executes two batch DB queries for [chunk] and yields [LoadedCandidate] events.
Stream<LoadedCandidateEvent> _loadChunk(
  List<SyncCandidate> chunk,
  Storage storage,
  RemoteId remoteId,
  PipeperfCollector? perf,
  String perfStage,
) async* {
  final sw = perf != null ? (Stopwatch()..start()) : null;
  final documentIris =
      chunk.map((e) => e.resourceIri.getDocumentIri()).toList();

  final docs = await storage.getDocumentsByIri(documentIris);
  final etags = await storage.getRemoteETags(remoteId, documentIris);
  if (sw != null) perf!.record(perfStage, sw.elapsedMicroseconds);

  for (final candidate in chunk) {
    final documentIri = candidate.resourceIri.getDocumentIri();
    final doc = docs[documentIri];
    final RdfGraphSource? localSource =
        doc != null ? DecodedGraphSource(doc.document) : null;

    yield LoadedCandidate(
      candidate,
      localSource: localSource,
      localUpdatedAt: doc?.metadata.updatedAt,
      storedRemoteEtag: etags[documentIri],
    );
  }
}
