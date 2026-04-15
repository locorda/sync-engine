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
import 'package:logging/logging.dart';

final _log = Logger('Stage5.LocalContentLoad');

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
  String perfStage = 'S05.LocalLoad',
}) {
  return StreamTransformer.fromBind((stream) async* {
    final buffer = <SyncCandidate>[];

    await for (final event in stream) {
      switch (event) {
        // --- Resource Events ---
        case SyncCandidate():
          buffer.add(event);
          if (buffer.length >= batchSize) {
            yield* _loadChunkSafe(buffer, storage, remoteId, perf, perfStage);
            buffer.clear();
          }

        // --- Shard Events ---
        case ShardError():
          assert(buffer.isEmpty,
              'S05: buffer not empty at ShardError — upstream protocol violation');
          if (buffer.isNotEmpty) {
            _log.severe('S05: buffer unexpectedly non-empty '
                '(${buffer.length} items) at ShardError for '
                '${event.shardIri} — discarding');
            buffer.clear();
          }
          yield event;

        case ShardComplete():
          if (buffer.isNotEmpty) {
            yield* _loadChunkSafe(buffer, storage, remoteId, perf, perfStage);
            buffer.clear();
          }
          yield event;
        case ShardSkipped():
          assert(buffer.isEmpty,
              'S05: buffer not empty at ShardSkipped — upstream protocol violation');
          if (buffer.isNotEmpty) {
            _log.severe('S05: buffer unexpectedly non-empty '
                '(${buffer.length} items) at ShardSkipped for '
                '${event.shardIri} — discarding');
            buffer.clear();
          }
          yield event;

        // --- Phase Events ---
        case PhaseComplete():
          if (buffer.isNotEmpty) {
            yield* _loadChunkSafe(buffer, storage, remoteId, perf, perfStage);
            buffer.clear();
          }
          yield event;
        case PhaseError():
          assert(buffer.isEmpty,
              'S05: buffer not empty at PhaseError — upstream protocol violation');
          if (buffer.isNotEmpty) {
            _log.severe('S05: buffer unexpectedly non-empty '
                '(${buffer.length} items) at PhaseError — discarding');
            buffer.clear();
          }
          yield event;
      }
    }
  });
}

/// Safe wrapper around [_loadChunk] — emits [ResourceError] per candidate on failure.
Stream<LoadedCandidateEvent> _loadChunkSafe(
  List<SyncCandidate> chunk,
  Storage storage,
  RemoteId remoteId,
  PipeperfCollector? perf,
  String perfStage,
) async* {
  try {
    await for (final e
        in _loadChunk(chunk, storage, remoteId, perf, perfStage)) {
      yield e;
    }
  } catch (e, st) {
    _log.warning(
        'S05: batch load failed for ${chunk.length} candidates', e, st);
    for (final candidate in chunk) {
      yield ResourceError(candidate.resourceIri, e, st);
    }
  }
}

/// Executes two batch DB queries for [chunk] and yields [LoadedCandidate] events.
Stream<LoadedCandidateEvent> _loadChunk(
  List<SyncCandidate> chunk,
  Storage storage,
  RemoteId remoteId,
  PipeperfCollector? perf,
  String perfStage,
) async* {
  final sw = perf?.start(perfStage);
  final documentIris =
      chunk.map((e) => e.resourceIri.getDocumentIri()).toList();

  final docs = await storage.getRawDocumentsByIri(documentIris);
  final etags = await storage.getRemoteETags(remoteId, documentIris);
  sw?.stop();

  for (final candidate in chunk) {
    final documentIri = candidate.resourceIri.getDocumentIri();
    final doc = docs[documentIri];
    final RdfGraphSource? localSource;
    if (doc == null) {
      localSource = null;
    } else {
      localSource =
          BinaryGraphSource(doc.rawContent, contentType: doc.contentType);
    }

    yield LoadedCandidate(
      candidate,
      localSource: localSource,
      localUpdatedAt: doc?.metadata.updatedAt,
      storedRemoteEtag: etags[documentIri],
    );
  }
}
