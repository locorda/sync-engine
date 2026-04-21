/// Backend pipeline implementation for single-file mode.
///
/// In single-file mode, ALL shard documents and resource documents are stored
/// in one RDF dataset (TriG). Every document is a named graph — the default
/// graph is only for this (artificial) single document.
///
/// The file is identified by an internally generated document IRI.
///
/// This reduces remote I/O to a single download and a single upload per sync
/// cycle, at the cost of re-uploading the entire file even for small changes.
library;

import 'dart:async';

import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/storage/remote_storage.dart';
import 'package:locorda_core/src/sync/pipeline/backend/backend_converter.dart';
import 'package:locorda_core/src/sync/pipeline/backend/remote_sync_backend.dart';
import 'package:locorda_core/src/sync/pipeline/pipeperf.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_support.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';
import 'package:locorda_core/src/mapping/resource_locator.dart';
import 'package:locorda_core/src/vocab/generated/_index.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:logging/logging.dart';

/// [PipelineRemoteSyncStorage] for single-file backends.
///
/// The entire remote is one TriG dataset. The four pipeline stages:
///
/// - **Stage 2 (shardFetch)**: Downloads the single file on first request,
///   caches all named graphs. For each [ShardRef], looks up its named graph
///   and emits [ShardContent] with `allResourcesAvailable = true`.
///   Subsequent shards are served from cache without I/O.
///
/// - **Stage 6 (resourceFetch)**: Serves resource graphs from the download
///   cache populated by Stage 2 — no I/O. Cache is cleared per shard on
///   [ShardComplete].
///
/// - **Stage 8 (resourceUpload)**: Stores merged graphs into an accumulator
///   instead of uploading. The actual upload happens in Stage 12.
///
/// - **Stage 12 (shardUpload)**: At [PhaseComplete], assembles a single
///   [RdfDataset] from merged shard graphs + merged resource graphs +
///   unchanged resources loaded from the local DB. One PUT total.
class SingleFileRemoteSyncStorage implements PipelineRemoteSyncStorage {
  /// Deterministic document IRI for single-file mode, computed once.
  static final _fileDocumentIri =
      LocalResourceLocator(iriTermFactory: IriTerm.new)
          .toIri(ResourceIdentifier.document(Sync.SyncFile, 'sync-file'));

  final _log = Logger('SingleFileRemoteSyncStorage');
  final RemoteSyncBackend backend;
  final BackendDatasetConverter _converter;

  /// Cached dataset from the single-file download. Populated on first
  /// shard fetch, consumed until the phase ends.
  RdfDataset? _cachedDataset;

  /// ETag of the downloaded file, used for conditional upload.
  String? _downloadedEtag;

  /// Whether the single file has already been downloaded this sync cycle.
  bool _downloaded = false;

  /// Per-shard resource graph cache extracted from the downloaded dataset.
  /// Keyed by shard document IRI string → (resource document IRI → graph).
  final Map<String, Map<IriTerm, RdfGraph>> _downloadCache = {};

  /// Accumulator for merged resource graphs from Stage 8.
  /// Keyed by shard document IRI string → (resource document IRI → merged graph).
  final Map<String, Map<IriTerm, DecodedGraphSource>> _uploadAccumulator = {};

  /// Pending resources before shard boundary reveals the shard key.
  final Map<IriTerm, DecodedGraphSource> _pendingResources = {};

  /// Accumulator for merged shard graphs from Stage 12.
  /// Keyed by shard document IRI → merged shard graph.
  final Map<IriTerm, DecodedGraphSource> _mergedShardGraphs = {};

  /// Shard document IRIs requested via [ShardRef] (both phases).
  /// Used by [_emitExtraShards] to skip already-processed shards.
  final Set<String> _requestedShardDocIris = {};

  /// Storage access for loading resource graphs and managing ETags.
  final BackendStorageAccess _storageAccess;

  SingleFileRemoteSyncStorage(
    this.backend, {
    required RdfCore rdfCore,
    required String contentType,
    required BackendStorageAccess storageAccess,
  })  : _converter = BackendDatasetConverter(
          rdfCore: rdfCore,
          isBinary: rdfCore.contentTypeInfo(contentType)?.isBinary ?? false,
          contentType: contentType,
        ),
        _storageAccess = storageAccess;

  @override
  Future<void> finalizeSync(SyncFinalizationState state,
      {PipeperfCollector? perf}) async {
    if (state is SyncFinalizationSuccess) {
      try {
        await _uploadSingleFile(perf: perf);
      } catch (e, st) {
        _log.warning(
            'Single-file upload during finalization failed: $e', e, st);
        // Non-fatal: data is already committed locally, upload will retry
        // on next sync cycle.
      }
    }
    _mergedShardGraphs.clear();
    _uploadAccumulator.clear();
    _requestedShardDocIris.clear();
    _cachedDataset = null;
    _downloaded = false;
    _notModified = false;
    await backend.finalize(state, perf: perf);
  }

  // ---------------------------------------------------------------------------
  // Stage 2: Shard Fetch — download single file, serve shards from cache
  // ---------------------------------------------------------------------------

  /// Downloads the single file (once) and populates the per-shard caches.
  Future<void> _ensureDownloaded({PipeperfCollector? perf}) async {
    if (_downloaded) return;
    _downloaded = true;

    // Load stored ETag for conditional GET.
    final storedEtags = await _storageAccess.getRemoteETags([_fileDocumentIri]);
    final storedEtag = storedEtags[_fileDocumentIri];

    final swIo = perf?.start('S02.ShardFetch.SF.io');
    final results = await backend
        .download(Stream.fromIterable([
          RemoteDownloadRequest(
            documentIri: _fileDocumentIri,
            ifNoneMatch: storedEtag,
          ),
        ]))
        .toList();
    swIo?.stop();

    final result = results.single;
    switch (result) {
      case NotModifiedDownloadResult():
        // 304 Not Modified — remote unchanged since last sync.
        _downloadedEtag = storedEtag;
        _notModified = true;
      case SuccessDownloadResult(:final graph, :final etag):
        final sw = perf?.start('S02.ShardFetch.SF.decode');
        _cachedDataset = _converter.decodeDataset(graph);
        _downloadedEtag = etag;
        sw?.stop();
      case NotFoundDownloadResult():
        break; // Remote file doesn't exist yet.
      case ErrorDownloadResult(:final error, :final stackTrace):
        Error.throwWithStackTrace(error, stackTrace);
    }
    // If NotFound: _cachedDataset stays null, and each shard will get ShardNotFound.
  }

  /// Whether the remote file returned 304 Not Modified.
  bool _notModified = false;

  @override
  StreamTransformer<ShardRefEvent, FetchedShardEvent> shardFetch(
          {PipeperfCollector? perf}) =>
      StreamTransformer.fromBind((stream) async* {
        await for (final event in stream) {
          switch (event) {
            // --- Shard Events ---
            case ShardRef():
              try {
                await _ensureDownloaded(perf: perf);
                yield _lookupShard(event);
              } catch (e, st) {
                _log.warning(
                    'Shard fetch failed for ${event.shardIri}: $e', e, st);
                yield ShardError(event.shardIri, e, st);
              }

            // --- Phase Events ---
            case PhaseComplete():
              // Emit extra shards from the downloaded single file that were
              // not requested via ShardRef (e.g. foreign device shards).
              yield* _emitExtraShards(event);
              yield event;
            case PhaseError():
              yield event;
          }
        }
      });

  FetchedShardEvent _lookupShard(ShardRef event) {
    _requestedShardDocIris.add(event.shardIri.getDocumentIri().value);

    // 304 Not Modified — all shards unchanged.
    if (_notModified) {
      return ShardNotModified(event.shardIri, event.shardStorageId,
          event.fetchPolicy, event.typeIri,
          storedEtag: event.storedEtag);
    }

    final dataset = _cachedDataset;
    if (dataset == null) {
      // Remote file doesn't exist — every shard is "not found".

      return ShardNotFound(event.shardIri, event.shardStorageId,
          event.fetchPolicy, event.typeIri);
    }

    final shardDocIri = event.shardIri.getDocumentIri();
    final shardGraph = dataset.graph(shardDocIri);

    if (shardGraph == null) {
      // Shard not present in the remote file.
      return ShardNotFound(event.shardIri, event.shardStorageId,
          event.fetchPolicy, event.typeIri);
    }

    // Extract clockHash as synthetic per-shard ETag.
    final clockHash = shardGraph.clockHash(shardDocIri);

    if (clockHash != null && clockHash == event.storedEtag) {
      // 304 equivalent: shard unchanged within the changed file.
      return ShardNotModified(event.shardIri, event.shardStorageId,
          event.fetchPolicy, event.typeIri,
          storedEtag: clockHash);
    }

    // Build per-shard resource cache from all named graphs that are
    // referenced as entries in this shard.
    final resourceCache = <IriTerm, RdfGraph>{};
    final entryIris = shardGraph.getMultiValueObjects<IriTerm>(
        event.shardIri, IdxShard.containsEntry);
    for (final entryIri in entryIris) {
      final resourceIri = shardGraph.expectSingleObject<IriTerm>(
          entryIri, IdxShardEntry.resource);
      if (resourceIri != null) {
        final docIri = resourceIri.getDocumentIri();
        final resourceGraph = dataset.graph(docIri);
        if (resourceGraph != null) {
          resourceCache[docIri] = resourceGraph;
        }
      }
    }
    _downloadCache[shardDocIri.value] = resourceCache;

    return ShardContent(
      event.shardIri,
      event.shardStorageId,
      event.fetchPolicy,
      event.typeIri,
      DecodedGraphSource(shardGraph),
      clockHash ?? _downloadedEtag!,
      preloadedResourceDocIris: resourceCache.keys.toSet(),
    );
  }

  /// Emits [ShardContent] for shard graphs in the downloaded single file that
  /// were not requested via [ShardRef] — typically shards from foreign devices.
  ///
  /// Only emits during the **content phase**: meta-phase shards are discovered
  /// via Stage 1's index resolution. At content-phase [PhaseComplete], all
  /// remaining named graphs that look like shards (contain `idx:isShardOf`)
  /// are injected with `shardStorageId: null` and `allResourcesAvailable: true`
  /// so the pipeline processes them fully.
  Stream<ShardContent> _emitExtraShards(PhaseComplete event) async* {
    // Only emit extras at end of content phase.
    if (event.source.isMetaIndexPhase) return;

    final dataset = _cachedDataset;
    if (dataset == null || _notModified) return;

    for (final namedGraph in dataset.namedGraphs) {
      final graphName = namedGraph.name;
      if (graphName is! IriTerm) continue;
      final docIri = graphName;

      // Skip shards already served via ShardRef.
      if (_requestedShardDocIris.contains(docIri.value)) continue;

      final graph = namedGraph.graph;

      // Identify shard documents via sync:managedResourceType predicate.
      if (!_isShardGraph(graph, docIri)) continue;

      // Resolve shard IRI via foaf:primaryTopic, then look up the index.
      final shardIri =
          graph.findSingleObject<IriTerm>(docIri, Foaf.primaryTopic);
      if (shardIri == null) continue;
      final indexIri =
          graph.findSingleObject<IriTerm>(shardIri, IdxShard.isShardOf);
      if (indexIri == null) continue;

      // Extract typeIri from the index document (idx:indexesClass).
      // For FullIndex: directly on the index resource.
      // For GroupIndex: follow idx:basedOn → GroupIndexTemplate → indexesClass.
      final indexDocGraph = dataset.graph(indexIri.getDocumentIri());
      var typeIri = indexDocGraph?.findSingleObject<IriTerm>(
          indexIri, IdxFullIndex.indexesClass);
      if (typeIri == null && indexDocGraph != null) {
        final templateIri = indexDocGraph.findSingleObject<IriTerm>(
            indexIri, IdxGroupIndex.basedOn);
        if (templateIri != null) {
          final templateGraph = dataset.graph(templateIri.getDocumentIri());
          typeIri = templateGraph?.findSingleObject<IriTerm>(
              templateIri, IdxGroupIndexTemplate.indexesClass);
        }
      }

      // Build resource cache (same as _lookupShard).
      final resourceCache = <IriTerm, RdfGraph>{};
      final entryIris =
          graph.getMultiValueObjects<IriTerm>(shardIri, IdxShard.containsEntry);
      for (final entryIri in entryIris) {
        final resourceIri =
            graph.expectSingleObject<IriTerm>(entryIri, IdxShardEntry.resource);
        if (resourceIri != null) {
          final resDocIri = resourceIri.getDocumentIri();
          final resourceGraph = dataset.graph(resDocIri);
          if (resourceGraph != null) {
            resourceCache[resDocIri] = resourceGraph;
          }
        }
      }
      _downloadCache[docIri.value] = resourceCache;
      _requestedShardDocIris.add(docIri.value);

      final shardClockHash = graph.clockHash(docIri);

      _log.fine('Emitting extra shard ${shardIri.debug} '
          '(index: ${indexIri.debug}, entries: ${entryIris.length})');

      yield ShardContent(
        shardIri,
        null, // shardStorageId — unknown to Stage 1
        null, // fetchPolicy — backend-injected
        typeIri,
        DecodedGraphSource(graph),
        shardClockHash ?? _downloadedEtag!,
        preloadedResourceDocIris: resourceCache.keys.toSet(),
      );
    }
  }

  /// Whether [graph] is a shard document (`sync:managedResourceType idx:Shard`).
  bool _isShardGraph(RdfGraph graph, IriTerm docIri) {
    final resourceType =
        graph.expectSingleObject<IriTerm>(docIri, Sync.managedResourceType);
    return resourceType == Idx.Shard;
  }

  // ---------------------------------------------------------------------------
  // Stage 6: Resource Fetch — serve from download cache, no I/O
  // ---------------------------------------------------------------------------

  @override
  StreamTransformer<LoadedCandidateEvent, FetchedCandidateEvent> resourceFetch(
          {PipeperfCollector? perf}) =>
      StreamTransformer.fromBind((stream) async* {
        await for (final event in stream) {
          switch (event) {
            // --- Resource Events ---
            case LoadedCandidate():
              if (!event.needsRemoteFetch) {
                yield FetchedCandidate(event,
                    remoteEtag: event.storedRemoteEtag);
                continue;
              }

              final docIri = event.candidate.resourceIri.getDocumentIri();
              RdfGraph? cached;
              for (final shardCache in _downloadCache.values) {
                cached = shardCache[docIri];
                if (cached != null) break;
              }

              if (cached != null) {
                // Extract clockHash as synthetic per-resource ETag.
                final newClockHash = cached.clockHash(docIri);

                if (newClockHash != null &&
                    newClockHash == event.storedRemoteEtag) {
                  // 304 equivalent: resource unchanged within the changed shard.
                  yield FetchedCandidate(event, remoteEtag: newClockHash);
                } else {
                  // 200 equivalent: resource changed (or no prior ETag stored).
                  yield FetchedCandidate(
                    event,
                    remoteSource: DecodedGraphSource(cached),
                    remoteEtag: newClockHash,
                  );
                }
              } else {
                _log.warning('Resource ${docIri.debug} not in download cache');
                yield FetchedCandidate(event,
                    remoteEtag: event.storedRemoteEtag);
              }

            case ResourceError():
              yield event;

            // --- Shard Events ---
            case ShardError():
              final shardDocIri = event.shardIri.getDocumentIri();
              _downloadCache.remove(shardDocIri.value);
              yield event;

            case ShardComplete():
              final shardDocIri = event.shardIri.getDocumentIri();
              _downloadCache.remove(shardDocIri.value);
              yield event;

            case ShardSkipped():
              final shardDocIri = event.shardIri.getDocumentIri();
              _downloadCache.remove(shardDocIri.value);
              yield event;

            // --- Phase Events ---
            case PhaseComplete():
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
  /// individually. The actual upload happens at [finalizeSync] as a single
  /// file upload containing all shards and resources.
  ///
  /// **Error handling — abort-on-first-error per shard:**
  ///
  /// Unlike FPR mode (where each resource is uploaded individually and its
  /// new ETag is immediately valid for the next sync cycle), single-file mode
  /// defers the upload to [finalizeSync]. If the upload never happens (due
  /// to an error in any resource), *none* of the accumulated ETags are valid
  /// on remote — the retry cycle will re-download the file and re-merge
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

    /// Resets all per-shard accumulation state — call on every shard/phase
    /// boundary to ensure the next shard starts clean.
    void clearShard() {
      _pendingResources.clear();
      shardHasError = false;
      shardError = null;
      shardErrorStack = null;
    }

    return StreamTransformer.fromBind((stream) async* {
      await for (final event in stream) {
        switch (event) {
          // --- Resource Events ---
          case MergeResult():
            if (event.needsUpload && !shardHasError) {
              final docIri = event.resourceIri.getDocumentIri();
              _pendingResources[docIri] = event.mergedGraph;
            }
            // Extract clockHash from merged graph as synthetic ETag.
            // finalizeSync will upload this graph, so the remote clockHash
            // after upload matches this value — S09 must persist it so S06
            // can detect unchanged resources on the next sync cycle.
            final newClockHash = event.mergedGraph.graph
                .clockHash(event.resourceIri.getDocumentIri());
            yield UploadResult(event, newRemoteEtag: newClockHash);

          case ResourceError():
            // Flag the shard — all subsequent resources are skipped.
            shardHasError = true;
            shardError ??= event.error;
            shardErrorStack ??= event.stackTrace;
            _pendingResources.clear();
          // Consumed: ShardError will be emitted at ShardComplete.

          // --- Shard Events ---
          case ShardError():
            clearShard();
            yield event;

          case ShardComplete():
            if (shardHasError) {
              yield ShardError(event.shardIri, shardError!, shardErrorStack!);
            } else {
              if (_pendingResources.isNotEmpty) {
                final shardKey = event.shardIri.getDocumentIri().value;
                _uploadAccumulator
                    .putIfAbsent(shardKey, () => {})
                    .addAll(_pendingResources);
              }
              yield event;
            }
            clearShard();

          case ShardSkipped():
            clearShard();
            yield event;

          // --- Phase Events ---
          case PhaseComplete():
            clearShard();
            yield event;

          case PhaseError():
            clearShard();
            yield event;
        }
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Stage 12: Shard Upload — accumulate shard graphs, upload one file at PhaseComplete
  // ---------------------------------------------------------------------------

  @override
  StreamTransformer<MergedShardEvent, UploadedShardEvent> shardUpload(
          {PipeperfCollector? perf}) =>
      StreamTransformer.fromBind((stream) async* {
        await for (final event in stream) {
          switch (event) {
            // --- Shard Events ---
            case MergedShard():
              if (event.needsUpload) {
                _mergedShardGraphs[event.shardIri.getDocumentIri()] =
                    event.mergedGraph;
              }
              // Extract clockHash from merged shard graph as synthetic ETag.
              // S13 persists this so S02 can detect unchanged shards on retry.
              final newClockHash = event.mergedGraph.graph
                  .clockHash(event.shardIri.getDocumentIri());
              yield UploadedShard(event.shardIri, event,
                  newRemoteEtag: newClockHash);

            case ShardSkipped():
              yield event;

            case ConflictedShard():
              yield event;

            case ShardError():
              yield event;

            // --- Phase Events ---
            case PhaseComplete():
              // Upload deferred to finalizeSync — just pass through.
              yield event;

            case PhaseError():
              _mergedShardGraphs.clear();
              yield event;
          }
        }
      });

  /// Assemble the complete dataset and upload as one PUT.
  Future<void> _uploadSingleFile({PipeperfCollector? perf}) async {
    // Nothing changed — no upload needed.
    if (_mergedShardGraphs.isEmpty && _uploadAccumulator.isEmpty) return;

    final swAssemble = perf?.start('S12.ShardUpload.SF.assemble');

    final namedGraphs = <RdfGraphName, RdfGraph>{};

    // 1. Add merged shard graphs.
    for (final entry in _mergedShardGraphs.entries) {
      namedGraphs[entry.key] = entry.value.graph;
    }

    // 2. Collect all resource document IRIs and expected clock hashes from
    //    shard entries. The clock hash detects stale accumulator entries that
    //    were produced before a cross-shard CRDT merge updated the DB.
    final allResourceDocIris = <IriTerm>{};
    final expectedClockHashes = <IriTerm, String>{};

    for (final shardEntry in _mergedShardGraphs.entries) {
      final shardDocIri = shardEntry.key;
      final shardGraph = shardEntry.value.graph;
      // Determine the shard IRI via foaf:primaryTopic.
      final shardIri = shardGraph.expectSingleObject<IriTerm>(
          shardDocIri, Foaf.primaryTopic);
      if (shardIri == null) continue;

      final entryIris = shardGraph.getMultiValueObjects<IriTerm>(
          shardIri, IdxShard.containsEntry);
      for (final entryIri in entryIris) {
        final resourceIri = shardGraph.expectSingleObject<IriTerm>(
            entryIri, IdxShardEntry.resource);
        if (resourceIri != null) {
          final docIri = resourceIri.getDocumentIri();
          allResourceDocIris.add(docIri);
          final clockHash = shardGraph.clockHash(entryIri);
          if (clockHash != null) {
            expectedClockHashes[docIri] = clockHash;
          }
        }
      }
    }

    // 3. Add accumulated (changed) resource graphs, checking for staleness.
    //    Accumulated graphs may be stale when a resource was processed for one
    //    shard before another shard's CRDT merge produced a newer version and
    //    committed it to DB.
    final accumulatedDocIris = <IriTerm>{};
    for (final shardAccumulator in _uploadAccumulator.values) {
      for (final entry in shardAccumulator.entries) {
        final docIri = entry.key;
        final accClockHash = entry.value.graph.clockHash(docIri);
        final expected = expectedClockHashes[docIri];
        if (expected != null && accClockHash != expected) {
          _log.fine('Stale accumulator for ${docIri.debug}: '
              'accumulated=$accClockHash, expected=$expected '
              '— loading from DB');
          // Don't add to accumulatedDocIris → falls through to DB load.
          continue;
        }
        namedGraphs[docIri] = entry.value.graph;
        accumulatedDocIris.add(docIri);
      }
    }

    // 4. Load unchanged (or stale-replaced) resources from the local DB.
    final missingDocIris =
        allResourceDocIris.difference(accumulatedDocIris).toList();
    if (missingDocIris.isNotEmpty) {
      final swDbLoad = perf?.start('S12.ShardUpload.SF.dbLoad');
      final dbGraphs = await _storageAccess.loadResourceGraphs(missingDocIris);
      swDbLoad?.stop();
      for (final entry in dbGraphs.entries) {
        if (entry.value != null) {
          namedGraphs[entry.key] = entry.value!;
        } else {
          _log.warning('Resource ${entry.key.debug} not found in local DB '
              'during single-file assembly');
        }
      }
    }

    // 5. Include shard graphs from the cached download that were NOT merged
    //    (i.e. shards with no changes this sync cycle).
    final cachedDataset = _cachedDataset;
    if (cachedDataset != null) {
      for (final graphName in cachedDataset.graphNames) {
        if (graphName is IriTerm && !namedGraphs.containsKey(graphName)) {
          final graph = cachedDataset.graph(graphName);
          if (graph != null) {
            namedGraphs[graphName] = graph;
          }
        }
      }
    }

    swAssemble?.stop();

    // 6. Encode and upload.
    //    The default graph identifies the file itself so that consumers
    //    (including the test infrastructure) can discover the document IRI.
    final defaultGraph = RdfGraph.fromTriples([
      Triple(_fileDocumentIri, Rdf.type, Sync.SyncFile),
    ]);
    final dataset = RdfDataset(
      defaultGraph: defaultGraph,
      namedGraphs: namedGraphs,
    );

    final swEncode = perf?.start('S12.ShardUpload.SF.encode');
    final encoded = _converter.encodeDataset(dataset);
    swEncode?.stop();

    final swIo = perf?.start('S12.ShardUpload.SF.io');
    final results = await backend
        .upload(Stream.fromIterable([
          RemoteUploadRequest<RawContent>(
            documentIri: _fileDocumentIri,
            document: encoded,
            ifMatch: _downloadedEtag,
          ),
        ]))
        .toList();
    swIo?.stop();

    final result = results.single;
    if (result is SuccessUploadResult) {
      _downloadedEtag = result.etag;
      // Persist the new ETag so the next sync cycle can use conditional GET.
      await _storageAccess.setRemoteETags({_fileDocumentIri: result.etag});
    } else {
      _log.info(
          'Single-file upload conflict (If-Match: ${result.requestETag ?? 'none'}) — will retry');
    }
  }
}

extension _ClockHashExtension on RdfGraph {
  /// Extract the `crdt:clockHash` literal value for [subject], or `null`.
  String? clockHash(RdfSubject subject) =>
      findSingleObject<LiteralTerm>(subject, Crdt.clockHash)?.value;
}
