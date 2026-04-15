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
import 'package:locorda_core/src/sync/pipeline/backend/backend_converter.dart';
import 'package:locorda_core/src/sync/pipeline/backend/backend_pipe.dart';
import 'package:locorda_core/src/sync/pipeline/backend/remote_sync_backend.dart';
import 'package:locorda_core/src/sync/pipeline/pipeperf.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_support.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';
import 'package:locorda_core/src/vocab/generated/_index.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:logging/logging.dart';

/// [PipelineRemoteSyncStorage] for shard-dataset backends.
///
/// Each shard lives in one dataset file. The four pipeline stages work as:
///
/// - **Stage 2 (shardFetch)**: Downloads the dataset per shard via
///   [RemoteSyncBackend.download]. The raw content is decoded to an
///   [RdfDataset]; the default graph becomes the shard source, named graphs
///   are cached internally for Stage 6. Emits [ShardContent] with
///   `allResourcesAvailable = true`.
///
/// - **Stage 6 (resourceFetch)**: Serves resource graphs from the internal
///   cache populated by Stage 2 — no I/O. Cache is cleared per shard on
///   [ShardComplete].
///
/// - **Stage 8 (resourceUpload)**: Stores merged graphs into an accumulator
///   instead of uploading. The actual upload happens in Stage 12.
///
/// - **Stage 12 (shardUpload)**: Assembles a complete [RdfDataset] per shard
///   from the merged shard graph (defaultGraph) and resource graphs
///   (namedGraphs). Changed resources come from the Stage 8 accumulator;
///   unchanged resources are loaded from the local DB via
///   [BackendStorageAccess]. The dataset is encoded and uploaded via
///   [RemoteSyncBackend.upload].
class ShardDatasetRemoteSyncStorage implements PipelineRemoteSyncStorage {
  final _log = Logger('ShardDatasetRemoteSyncStorage');
  final RemoteSyncBackend backend;

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

  /// Storage access for loading resource graphs and managing ETags.
  final BackendStorageAccess _storageAccess;
  final BackendDatasetConverter _converter;

  ShardDatasetRemoteSyncStorage(
    this.backend, {
    required RdfCore rdfCore,
    required String contentType,
    required BackendStorageAccess storageAccess,
  })  : _storageAccess = storageAccess,
        _converter = BackendDatasetConverter(
          rdfCore: rdfCore,
          isBinary: rdfCore.contentTypeInfo(contentType)?.isBinary ?? false,
          contentType: contentType,
        );

  @override
  Future<void> finalizeSync(SyncFinalizationState state,
        {PipeperfCollector? perf}) =>
      backend.finalize(state, perf: perf);

  // ---------------------------------------------------------------------------
  // Stage 2: Shard Fetch — download datasets, cache named graphs
  // ---------------------------------------------------------------------------

  @override
  StreamTransformer<ShardRefEvent, FetchedShardEvent> shardFetch(
          {PipeperfCollector? perf}) =>
      StreamTransformer.fromBind((stream) => backendPipe<
              ShardRef,
              ShardRefEvent,
              FetchedShardEvent,
              RemoteDownloadRequest,
              RemoteDownloadResult<RawContent>>(
            stream: stream,
            logger: _log,
            perf: perf,
            perfStage: 'S02.ShardFetch.SD',
            classify: (e) => switch (e) {
              // --- Shard Events ---
              ShardRef() => BackendRequest(
                  (e.shardIri.getDocumentIri(), e.storedEtag),
                  e,
                  RemoteDownloadRequest(
                    documentIri: e.shardIri.getDocumentIri(),
                    ifNoneMatch: e.storedEtag,
                  ),
                ),

              // --- Phase Events ---
              PhaseComplete() => BackendBoundary(e),
              PhaseError() => BackendBoundary(e),
            },
            backendCall: backend.download,
            resultKey: (r) => (r.documentIri, r.requestETag),
            toOutput: (event, result) {
              if (result.notModified) {
                return ShardNotModified(event.shardIri, event.shardStorageId,
                    event.fetchPolicy, event.typeIri,
                    storedEtag: event.storedEtag);
              } else if (result.graph == null && event.storedEtag != null) {
                return ShardGone(event.shardIri, event.shardStorageId,
                    event.fetchPolicy, event.typeIri);
              } else if (result.graph == null) {
                return ShardNotFound(event.shardIri, event.shardStorageId,
                    event.fetchPolicy, event.typeIri);
              }
              try {
                // CPU: decode raw → dataset, then populate resource cache.
                final sw = perf?.start('S02.ShardFetch.SD.decode');
                final dataset = _converter.decodeDataset(result.graph!);
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
                sw?.stop();

                return ShardContent(
                  event.shardIri,
                  event.shardStorageId,
                  event.fetchPolicy,
                  event.typeIri,
                  DecodedGraphSource(dataset.defaultGraph),
                  result.etag!,
                  allResourcesAvailable: true,
                );
              } catch (e, st) {
                _log.warning(
                    'Shard decode failed for ${event.shardIri}: $e', e, st);
                return ShardError(event.shardIri, e, st);
              }
            },
            onError: (event, error, stackTrace) =>
                ShardError(event.shardIri, error, stackTrace),
          ));

  // ---------------------------------------------------------------------------
  // Stage 6: Resource Fetch — serve from download cache, no HTTP
  // ---------------------------------------------------------------------------

  @override
  StreamTransformer<LoadedCandidateEvent, FetchedCandidateEvent> resourceFetch(
          {PipeperfCollector? perf}) =>
      StreamTransformer.fromBind((stream) async* {
        await for (final event in stream) {
          switch (event) {
            // --- Resource Events ---
            case LoadedCandidate():
              final needsFetch = event.needsRemoteFetch;

              // Pass-through when remote shard is unchanged (304).
              if (!needsFetch) {
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
                // Extract clockHash from cached resource graph as synthetic ETag.
                final newClockHash = cached.clockHash(docIri);

                if (newClockHash != null &&
                    newClockHash == event.storedRemoteEtag) {
                  // 304 equivalent: resource unchanged within the changed shard.
                  // Skip remoteSource to avoid unnecessary merge.
                  yield FetchedCandidate(event, remoteEtag: newClockHash);
                } else {
                  // 200 equivalent: resource changed (or no prior ETag stored).
                  // Pass fresh graph with new clockHash as ETag.
                  yield FetchedCandidate(
                    event,
                    remoteSource: DecodedGraphSource(cached),
                    remoteEtag: newClockHash,
                  );
                }
              } else {
                // Resource not in cache — shouldn't happen with
                // allResourcesAvailable, but degrade gracefully.
                _log.warning('Resource ${docIri.debug} not in download cache');
                yield FetchedCandidate(event,
                    remoteEtag: event.storedRemoteEtag);
              }

            case ResourceError():
              yield event;

            // --- Shard Events ---
            case ShardError():
              // Clear this shard's download cache on error as well.
              _clearShard(event.shardIri);
              yield event;

            case ShardComplete():
              // Clear this shard's download cache to free memory.
              _clearShard(event.shardIri);
              yield event;

            case ShardSkipped():
              // Clear this shard's download cache to free memory.
              _clearShard(event.shardIri);
              yield event;

            // --- Phase Events ---
            case PhaseComplete():
              // Clear all remaining cache on phase boundary.
              _downloadCache.clear();
              yield event;

            case PhaseError():
              _downloadCache.clear();
              yield event;
          }
        }
      });

  // ---------------------------------------------------------------------------
  // Stage 8: Resource Upload — accumulate, don't upload
  // ---------------------------------------------------------------------------

  /// Accumulates merged resource graphs per shard instead of uploading them
  /// individually. The actual upload happens in Stage 12 as a single dataset.
  ///
  /// **Error handling — abort-on-first-error per shard:**
  ///
  /// Unlike FPR mode (where each resource is uploaded individually and its
  /// new ETag is immediately valid for the next sync cycle), dataset mode
  /// defers the upload to S12. If a shard's S12 upload never happens (due
  /// to an error in any resource), *none* of the accumulated ETags are valid
  /// on remote — the retry cycle will re-download the old shard and re-merge
  /// every resource anyway.
  ///
  /// Continuing to accumulate after a [ResourceError] would therefore be
  /// wasted work. Worse, it would overwrite the stored remote ETags (via
  /// S09) with values that don't match remote, forcing unnecessary re-merges
  /// on retry. By aborting early and emitting [ShardError] at the shard
  /// boundary, we preserve the old stored ETags for unprocessed resources
  /// so they can benefit from 304-equivalent skips on the next attempt.
  @override
  StreamTransformer<MergedResourceEvent, UploadedResourceEvent> resourceUpload(
      {PipeperfCollector? perf}) {
    /// Per-shard error flag: set when [ResourceError] is received, cleared on
    /// shard/phase boundary. Prevents accumulation of partial/corrupt data.
    bool shardHasError = false;
    Object? shardError;
    StackTrace? shardErrorStack;

    /// Temporary buffer for resources arriving before the shard boundary.
    ///
    /// Resources are accumulated here until [ShardComplete] arrives,
    /// at which point they are flushed into [_uploadAccumulator] under
    /// the correct shard key.
    final Map<IriTerm, DecodedGraphSource> _pendingResources = {};

    /// Resets all per-shard accumulation state — call on every shard/phase
    /// boundary to ensure the next shard starts clean.
    void clearCurrentShard() {
      _pendingResources.clear();
      shardHasError = false;
      shardError = null;
      shardErrorStack = null;
    }

    return StreamTransformer.fromBind((stream) async* {
      await for (final event in stream) {
        switch (event) {
          // --- Resource Events ---
          case MergeResult() when shardHasError:
            // Shard already failed — keep event flow, but do not synthesize a
            // post-upload ETag for data that will not be uploaded in S12.
            yield UploadResult(event);

          case MergeResult() when event.needsUpload:
            final docIri = event.resourceIri.getDocumentIri();
            _pendingResources[docIri] = event.mergedGraph;
            // Extract clockHash from merged graph as synthetic ETag.
            // S12 will upload this graph, so the remote clockHash after
            // upload matches this value — S09 must persist it so S06
            // can detect unchanged resources on the next sync cycle.
            final newClockHash = event.mergedGraph.graph
                .clockHash(event.resourceIri.getDocumentIri());
            yield UploadResult(event, newRemoteEtag: newClockHash);

          case MergeResult():
            // No upload needed, just pass through.
            yield UploadResult(event);

          case ResourceError():
            // Flag the shard — all subsequent resources are skipped.
            shardHasError = true;
            shardError ??= event.error;
            shardErrorStack ??= event.stackTrace;
            _pendingResources.clear();
            // Forward the original resource failure; shard-level abort is
            // still emitted at ShardComplete.
            yield event;

          // --- Shard Events ---
          case ShardError():
            clearCurrentShard();
            yield event;

          case ShardComplete():
            if (shardHasError) {
              final error = shardError!;
              final stack = shardErrorStack!;
              clearCurrentShard();
              yield ShardError(event.shardIri, error, stack);
            } else {
              // Flush pending resources into accumulator under this shard.
              if (_pendingResources.isNotEmpty) {
                final shardKey = event.shardIri.getDocumentIri().value;
                _uploadAccumulator
                    .putIfAbsent(shardKey, () => {})
                    .addAll(_pendingResources);
              }
              clearCurrentShard();
              yield event;
            }

          case ShardSkipped():
            clearCurrentShard();
            yield event;

          // --- Phase Events ---
          case PhaseComplete():
            clearCurrentShard();
            yield event;

          case PhaseError():
            clearCurrentShard();
            yield event;
        }
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Stage 12: Shard Upload — assemble and upload dataset
  // ---------------------------------------------------------------------------

  @override
  StreamTransformer<MergedShardEvent, UploadedShardEvent> shardUpload(
          {PipeperfCollector? perf}) =>
      StreamTransformer.fromBind((stream) {
        // Pre-process: assemble datasets and encode for shards needing upload.
        // asyncExpand processes events sequentially, so _assembleDataset calls
        // consume their accumulator entries before PhaseComplete clears the rest.
        final prepared = stream.asyncExpand((event) async* {
          switch (event) {
            case MergedShard() when event.needsUpload:
              try {
                final swDbLoad = perf?.start('S12.ShardUpload.SD.dbLoad');
                final dataset = await _assembleDataset(event);
                swDbLoad?.stop();
                final swEncode = perf?.start('S12.ShardUpload.SD.encode');
                final content = _converter.encodeDataset(dataset);
                swEncode?.stop();
                yield _ReadyToUpload(event, content);
              } catch (e, st) {
                _log.warning(
                    'Dataset assembly failed for ${event.shardIri}: $e', e, st);
                yield _RawS12Event(ShardError(event.shardIri, e, st));
              }
            case PhaseComplete():
              _uploadAccumulator.clear();
              yield _RawS12Event(event);
            case PhaseError():
              _uploadAccumulator.clear();
              yield _RawS12Event(event);
            default:
              yield _RawS12Event(event);
          }
        });

        return backendPipe<MergedShard, _S12Input, UploadedShardEvent,
            RemoteUploadRequest<RawContent>, RemoteUploadResult>(
          stream: prepared,
          logger: _log,
          perf: perf,
          perfStage: 'S12.ShardUpload.SD',
          classify: (e) => switch (e) {
            _ReadyToUpload(:final shard, :final content) => BackendRequest(
                (shard.shardIri.getDocumentIri(), shard.newEtag),
                shard,
                RemoteUploadRequest<RawContent>(
                  documentIri: shard.shardIri.getDocumentIri(),
                  document: content,
                  ifMatch: shard.newEtag,
                ),
              ),
            _RawS12Event(:final event) => switch (event) {
                // --- Shard Events ---
                MergedShard() =>
                  BackendPassThrough(UploadedShard(event.shardIri, event)),
                ConflictedShard() => BackendPassThrough(event),
                ShardError() => BackendPassThrough(event),
                ShardSkipped() => BackendPassThrough(event),

                // --- Phase Events ---
                PhaseComplete() => BackendBoundary(event),
                PhaseError() => BackendBoundary(event),
              },
          },
          backendCall: backend.upload,
          resultKey: (r) => (r.documentIri, r.requestETag),
          toOutput: (event, result) => switch (result) {
            SuccessUploadResult(:final etag) =>
              UploadedShard(event.shardIri, event, newRemoteEtag: etag),
            ConflictUploadResult() => () {
                final docIri = event.shardIri.getDocumentIri();
                _log.info(
                    'Dataset upload conflict for ${docIri.debug} (If-Match: ${result.requestETag ?? 'none'}) — will retry');
                return ConflictedShard(event.shardIri,
                    trigger: event,
                    message: 'Dataset upload conflict for ${docIri.debug}');
              }(),
          },
          onError: (event, error, stackTrace) =>
              ShardError(event.shardIri, error, stackTrace),
        );
      });

  /// Assemble a complete [RdfDataset] from the merged shard graph and
  /// resource graphs (accumulated + DB).
  Future<RdfDataset> _assembleDataset(MergedShard shard) async {
    final shardGraph = shard.mergedGraph.graph;
    final shardIri = shard.shardIri;
    final shardDocIri = shardIri.getDocumentIri();

    // Extract resource document IRIs and expected clock hashes from shard
    // entries. The clock hash is used to detect stale accumulator entries
    // that were produced before a cross-shard CRDT merge updated the DB.
    final entryIris = shardGraph.getMultiValueObjects<IriTerm>(
        shardIri, IdxShard.containsEntry);

    final resourceDocIris = <IriTerm>{};
    final expectedClockHashes = <IriTerm, String>{};
    for (final entryIri in entryIris) {
      final resourceIri = shardGraph.expectSingleObject<IriTerm>(
          entryIri, IdxShardEntry.resource);
      if (resourceIri != null) {
        final docIri = resourceIri.getDocumentIri();
        resourceDocIris.add(docIri);
        final clockHash = shardGraph.clockHash(entryIri);
        if (clockHash != null) {
          expectedClockHashes[docIri] = clockHash;
        }
      }
    }

    // Collect named graphs: accumulated (changed) resources first.
    // Accumulated graphs may be stale when a resource was processed for this
    // shard before another shard's CRDT merge produced a newer version and
    // committed it to DB. Detect this by comparing the accumulated graph's
    // clock hash against the expected clock hash from the shard entry.
    final namedGraphs = <RdfGraphName, RdfGraph>{};
    final accumulated = _uploadAccumulator[shardDocIri.value] ?? {};
    final missingDocIris = <IriTerm>[];

    for (final docIri in resourceDocIris) {
      final accumulatedGraph = accumulated[docIri];
      if (accumulatedGraph != null) {
        final accClockHash = accumulatedGraph.graph.clockHash(docIri);
        final expected = expectedClockHashes[docIri];
        if (expected != null && accClockHash != expected) {
          // Accumulated graph is stale — load fresh version from DB.
          _log.fine('Stale accumulator for ${docIri.debug} in '
              '${shardDocIri.debug}: accumulated=$accClockHash, '
              'expected=$expected — loading from DB');
          missingDocIris.add(docIri);
        } else {
          namedGraphs[docIri] = accumulatedGraph.graph;
        }
      } else {
        missingDocIris.add(docIri);
      }
    }

    // Load unchanged (or stale-replaced) resources from local DB.
    if (missingDocIris.isNotEmpty) {
      final dbGraphs = await _storageAccess.loadResourceGraphs(missingDocIris);
      for (final iri in missingDocIris) {
        final graph = dbGraphs[iri];
        if (graph != null) {
          namedGraphs[iri] = graph;
        } else {
          _log.warning('Resource ${iri.debug} not found in local DB '
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

  void _clearShard(IriTerm shardIri) {
    // Clear this shard's download cache to free memory.
    final shardDocIri = shardIri.getDocumentIri();
    _downloadCache.remove(shardDocIri.value);
  }
}

// ---------------------------------------------------------------------------
// Stage 12 pre-processing types
// ---------------------------------------------------------------------------

/// Pre-processed input for Stage 12 [backendPipe].
///
/// [asyncExpand] pre-processing converts [MergedShard] events that need
/// upload into [_ReadyToUpload] (with assembled+encoded content), wrapping
/// all other events in [_RawS12Event].
sealed class _S12Input {}

/// A shard that has been assembled into a dataset and encoded for upload.
final class _ReadyToUpload implements _S12Input {
  final MergedShard shard;
  final RawContent content;
  _ReadyToUpload(this.shard, this.content);
}

/// Wrapper for events that need no pre-processing.
final class _RawS12Event implements _S12Input {
  final MergedShardEvent event;
  _RawS12Event(this.event);
}

extension _ClockHashExtension on RdfGraph {
  /// Extract the `crdt:clockHash` literal value for [subject], or `null`.
  String? clockHash(RdfSubject subject) =>
      findSingleObject<LiteralTerm>(subject, Crdt.clockHash)?.value;
}
