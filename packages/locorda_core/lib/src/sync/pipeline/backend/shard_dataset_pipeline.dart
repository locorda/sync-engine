/// Backend pipeline implementations for shard-dataset mode.
///
/// In shard-dataset mode, each shard is stored as an RDF dataset (TriG)
/// where the default graph contains shard metadata and named graphs
/// contain the individual resource documents.
///
/// This replaces per-resource HTTP round-trips with per-shard dataset
/// downloads/uploads, reducing I/O to one request per shard.
library;

import 'dart:async';

import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/storage/remote_storage.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_support.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';
import 'package:locorda_core/src/vocab/generated/_index.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:logging/logging.dart';

/// Backend interface for shard-dataset storage.
///
/// Analogous to [FPRBackend] for file-per-resource mode. Implementations
/// provide dataset-level download/upload. [InMemorySyncStorage] and
/// directory-based backends implement this interface.
abstract interface class SDSBackend {
  /// Download multiple shard datasets, returning complete datasets.
  Future<List<RemoteDownloadResult<RdfDataset>>> downloadDatasets(
      Iterable<RemoteDownloadRequest> requests);

  /// Upload multiple shard datasets to remote storage.
  Future<List<RemoteUploadResult>> uploadDatasets(
      Iterable<RemoteUploadRequest<RdfDataset>> requests);
}

/// [PipelineRemoteSyncStorage] for shard-dataset backends.
///
/// Each shard lives in one dataset file. The four pipeline stages work as:
///
/// - **Stage 2 (shardFetch)**: Downloads the dataset per shard. The default
///   graph becomes the shard source; named graphs are cached internally for
///   Stage 6. Emits [ShardContent] with `allResourcesAvailable = true`.
///
/// - **Stage 6 (resourceFetch)**: Serves resource graphs from the internal
///   cache populated by Stage 2 — no HTTP. Cache is cleared per shard on
///   [ShardComplete].
///
/// - **Stage 8 (resourceUpload)**: Stores merged graphs into an accumulator
///   instead of uploading. The actual upload happens in Stage 12.
///
/// - **Stage 12 (shardUpload)**: Assembles a complete [RdfDataset] per shard
///   from the merged shard graph (defaultGraph) and resource graphs
///   (namedGraphs). Changed resources come from the Stage 8 accumulator;
///   unchanged resources are loaded from the local DB via
///   [ResourceGraphLoader].
class ShardDatasetRemoteSyncSupport implements PipelineRemoteSyncStorage {
  final _log = Logger('ShardDatasetRemoteSyncSupport');
  final SDSBackend backend;
  final int batchSize;

  /// Per-shard resource graph cache from Stage 2 downloads.
  ///
  /// Keyed by shard document IRI → (resource document IRI → graph).
  /// Populated in [shardFetch], consumed in [resourceFetch],
  /// cleared per shard on [ShardComplete].
  final Map<String, Map<IriTerm, RdfGraph>> _downloadCache = {};

  /// Accumulator for merged resource graphs from Stage 8.
  ///
  /// Keyed by shard document IRI → (resource document IRI → merged graph).
  /// Populated in [resourceUpload], consumed and cleared in [shardUpload].
  final Map<String, Map<IriTerm, DecodedGraphSource>> _uploadAccumulator = {};

  /// Temporary buffer for resources arriving before the shard boundary.
  ///
  /// Resources are accumulated here until [ShardComplete] arrives,
  /// at which point they are flushed into [_uploadAccumulator] under
  /// the correct shard key.
  final Map<IriTerm, DecodedGraphSource> _pendingResources = {};

  /// Resource graph loader injected by the orchestrator.
  ///
  /// Loads resource graphs from the local DB for dataset assembly in Stage 12.
  ResourceGraphLoader _resourceGraphLoader;

  ShardDatasetRemoteSyncSupport(
    this.backend, {
    required ResourceGraphLoader resourceGraphLoader,
    this.batchSize = defaultPipelineBatchSize,
  }) : _resourceGraphLoader = resourceGraphLoader;

  @override
  Future<void> finalizeSync() => Future.value();

  // ---------------------------------------------------------------------------
  // Stage 2: Shard Fetch — download datasets, cache named graphs
  // ---------------------------------------------------------------------------

  @override
  StreamTransformer<ShardRefEvent, FetchedShardEvent> shardFetch() =>
      StreamTransformer.fromBind((stream) async* {
        final buffer = <ShardRef>[];

        await for (final event in stream) {
          switch (event) {
            case ShardRef():
              buffer.add(event);
              if (buffer.length >= batchSize) {
                yield* _fetchShardChunk(buffer);
                buffer.clear();
              }
            case PhaseComplete():
              if (buffer.isNotEmpty) {
                yield* _fetchShardChunk(buffer);
                buffer.clear();
              }
              yield event;
          }
        }
      });

  Stream<FetchedShardEvent> _fetchShardChunk(List<ShardRef> chunk) async* {
    final requests = chunk.map((e) => RemoteDownloadRequest(
          documentIri: e.shardIri.getDocumentIri(),
          ifNoneMatch: e.storedEtag,
        ));

    final results = await backend.downloadDatasets(requests);

    for (var i = 0; i < chunk.length; i++) {
      final event = chunk[i];
      final result = results[i];

      if (result.notModified) {
        yield ShardNotModified(event.shardIri, event.shardStorageId,
            event.fetchPolicy, event.typeIri,
            storedEtag: event.storedEtag);
      } else if (result.graph == null && event.storedEtag != null) {
        yield ShardGone(event.shardIri, event.shardStorageId, event.fetchPolicy,
            event.typeIri);
      } else if (result.graph == null) {
        yield ShardNotModified(event.shardIri, event.shardStorageId,
            event.fetchPolicy, event.typeIri,
            existsOnRemote: false);
      } else {
        final dataset = result.graph!;
        final shardDocIri = event.shardIri.getDocumentIri();

        // Cache named graphs (resource documents) for Stage 6.
        final resourceCache = <IriTerm, RdfGraph>{};
        for (final graphName in dataset.graphNames) {
          if (graphName is IriTerm) {
            final graph = dataset.graph(graphName);
            if (graph != null) {
              resourceCache[graphName] = graph;
            }
          }
        }
        _downloadCache[shardDocIri.value] = resourceCache;

        // Emit the default graph (shard metadata) as ShardContent.
        yield ShardContent(
          event.shardIri,
          event.shardStorageId,
          event.fetchPolicy,
          event.typeIri,
          DecodedGraphSource(dataset.defaultGraph),
          result.etag!,
          allResourcesAvailable: true,
        );
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Stage 6: Resource Fetch — serve from download cache, no HTTP
  // ---------------------------------------------------------------------------

  @override
  StreamTransformer<LoadedCandidateEvent, FetchedCandidateEvent>
      resourceFetch() => StreamTransformer.fromBind((stream) async* {
            await for (final event in stream) {
              switch (event) {
                case LoadedCandidate():
                  final direction = event.candidate.direction;

                  // Pass-through directions that don't need a remote fetch.
                  if (direction == SyncDirection.remoteShardUnchanged ||
                      direction == SyncDirection.notInRemoteShard ||
                      direction == SyncDirection.shardGone) {
                    yield FetchedCandidate(event,
                        remoteEtag: event.storedRemoteEtag);
                    continue;
                  }

                  // Look up the resource graph from download cache.
                  final docIri = event.candidate.resourceIri.getDocumentIri();

                  // Find the graph in any shard's cache.
                  RdfGraph? cached;
                  for (final shardCache in _downloadCache.values) {
                    cached = shardCache[docIri];
                    if (cached != null) break;
                  }

                  if (cached != null) {
                    yield FetchedCandidate(
                      event,
                      remoteSource: DecodedGraphSource(cached),
                      remoteEtag: event.storedRemoteEtag,
                    );
                  } else {
                    // Resource not in cache — shouldn't happen with
                    // allResourcesAvailable, but degrade gracefully.
                    _log.warning(
                        'Resource ${docIri.debug} not in download cache');
                    yield FetchedCandidate(event,
                        remoteEtag: event.storedRemoteEtag);
                  }

                case ShardComplete():
                  // Clear this shard's download cache to free memory.
                  final shardDocIri = event.shardIri.getDocumentIri();
                  _downloadCache.remove(shardDocIri.value);
                  yield event;

                case PhaseComplete():
                  // Clear all remaining cache on phase boundary.
                  _downloadCache.clear();
                  yield event;
              }
            }
          });

  // ---------------------------------------------------------------------------
  // Stage 8: Resource Upload — accumulate, don't upload
  // ---------------------------------------------------------------------------

  @override
  StreamTransformer<MergedResourceEvent, UploadedResourceEvent>
      resourceUpload() => StreamTransformer.fromBind((stream) async* {
            await for (final event in stream) {
              switch (event) {
                case MergeResult():
                  if (event.needsUpload) {
                    // Buffer merged graph until ShardComplete reveals the shard.
                    final docIri = event.resourceIri.getDocumentIri();
                    _pendingResources[docIri] = event.mergedGraph;
                  }
                  // Always emit UploadResult (no remote ETag — deferred).
                  yield UploadResult(event);

                case ShardComplete():
                  // Flush pending resources into accumulator under this shard.
                  if (_pendingResources.isNotEmpty) {
                    final shardKey = event.shardIri.getDocumentIri().value;
                    _uploadAccumulator
                        .putIfAbsent(shardKey, () => {})
                        .addAll(_pendingResources);
                    _pendingResources.clear();
                  }
                  yield event;

                case PhaseComplete():
                  _pendingResources.clear();
                  yield event;
              }
            }
          });

  // ---------------------------------------------------------------------------
  // Stage 12: Shard Upload — assemble and upload dataset
  // ---------------------------------------------------------------------------

  @override
  StreamTransformer<MergedShardEvent, UploadedShardEvent> shardUpload() =>
      StreamTransformer.fromBind((stream) async* {
        final buffer = <MergedShard>[];
        final passThrough = <MergedShard>[];

        await for (final event in stream) {
          switch (event) {
            case MergedShard():
              if (!event.needsUpload) {
                passThrough.add(event);
              } else {
                buffer.add(event);
              }
              if (buffer.length >= batchSize) {
                yield* _yieldShardPassThrough(passThrough);
                yield* _uploadShardDatasets(buffer);
                buffer.clear();
                passThrough.clear();
              }
            case PhaseComplete():
              if (buffer.isNotEmpty || passThrough.isNotEmpty) {
                yield* _yieldShardPassThrough(passThrough);
                yield* _uploadShardDatasets(buffer);
                buffer.clear();
                passThrough.clear();
              }
              // Clean up accumulator on phase boundary.
              _uploadAccumulator.clear();
              yield event;
          }
        }
      });

  Stream<UploadedShardEvent> _yieldShardPassThrough(
      List<MergedShard> items) async* {
    for (final event in items) {
      yield UploadedShard(event.shardIri, event);
    }
  }

  Stream<UploadedShardEvent> _uploadShardDatasets(
      List<MergedShard> chunk) async* {
    if (chunk.isEmpty) return;

    // Build datasets for each shard.
    final datasets = <RdfDataset>[];
    for (final shard in chunk) {
      datasets.add(await _assembleDataset(shard));
    }

    // Upload all datasets in batch.
    final requests = <RemoteUploadRequest<RdfDataset>>[];
    for (var i = 0; i < chunk.length; i++) {
      requests.add(RemoteUploadRequest<RdfDataset>(
        documentIri: chunk[i].shardIri.getDocumentIri(),
        document: datasets[i],
        ifMatch: chunk[i].newEtag,
      ));
    }

    final results = await backend.uploadDatasets(requests);

    for (var i = 0; i < chunk.length; i++) {
      final event = chunk[i];
      final result = results[i];

      if (result is SuccessUploadResult) {
        yield UploadedShard(event.shardIri, event, newRemoteEtag: result.etag);
      } else {
        final docIri = event.shardIri.getDocumentIri();
        _log.warning('Dataset upload conflict for ${docIri.debug} — skipping');
        yield UploadedShard(event.shardIri, event);
      }
    }
  }

  /// Assemble a complete [RdfDataset] from the merged shard graph and
  /// resource graphs (accumulated + DB).
  Future<RdfDataset> _assembleDataset(MergedShard shard) async {
    final shardGraph = shard.mergedGraph.graph;
    final shardIri = shard.shardIri;
    final shardDocIri = shardIri.getDocumentIri();

    // Extract resource document IRIs from the shard graph entries.
    final entryIris = shardGraph.getMultiValueObjects<IriTerm>(
        shardIri, IdxShard.containsEntry);

    final resourceDocIris = <IriTerm>{};
    for (final entryIri in entryIris) {
      final resourceIri = shardGraph.expectSingleObject<IriTerm>(
          entryIri, IdxShardEntry.resource);
      if (resourceIri != null) {
        resourceDocIris.add(resourceIri.getDocumentIri());
      }
    }

    // Collect named graphs: accumulated (changed) resources first.
    final namedGraphs = <RdfGraphName, RdfGraph>{};
    final accumulated = _uploadAccumulator[shardDocIri.value] ?? {};
    final missingDocIris = <IriTerm>[];

    for (final docIri in resourceDocIris) {
      final accumulatedGraph = accumulated[docIri];
      if (accumulatedGraph != null) {
        namedGraphs[docIri] = accumulatedGraph.graph;
      } else {
        missingDocIris.add(docIri);
      }
    }

    // Load unchanged resources from local DB via the injected loader.
    if (missingDocIris.isNotEmpty) {
      final dbGraphs = await _resourceGraphLoader.load(missingDocIris);
      for (final entry in dbGraphs.entries) {
        if (entry.value != null) {
          namedGraphs[entry.key] = entry.value!;
        } else {
          _log.warning('Resource ${entry.key.debug} not found in local DB '
              'during dataset assembly for ${shardDocIri.debug}');
        }
      }
    }

    // Clean up accumulated entries for this shard.
    _uploadAccumulator.remove(shardDocIri.value);

    return RdfDataset(
      defaultGraph: shardGraph,
      namedGraphs: namedGraphs,
    );
  }
}
