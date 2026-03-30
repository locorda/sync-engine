/// Stage 7b: Preload — batch-load merge contracts, index configs, and index
/// documents for the sync CRDT merge in Stage 7c.
///
/// **Implementation**: `.transform()` — batched I/O with boundary-triggered
/// flush, modelled after Stage 5.
///
/// **Input**: `Stream<DecodedCandidateEvent>`
/// **Output**: `Stream<PreloadedCandidateEvent>`
library;

import 'dart:async';

import 'package:locorda_core/src/config/sync_engine_config.dart';
import 'package:locorda_core/src/index/index_discovery.dart';
import 'package:locorda_core/src/index/shard_determiner.dart';
import 'package:locorda_core/src/mapping/merge_contract.dart';
import 'package:locorda_core/src/mapping/merge_contract_loader.dart';
import 'package:locorda_core/src/storage/storage_interface.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';
import 'package:locorda_core/src/util/lru_cache.dart';
import 'package:locorda_rdf_core/core.dart';

/// Returns a StreamTransformer for Stage 7b.
///
/// Buffers [DecodedCandidate] events and flushes on boundary or batch-size cap.
/// For each batch:
/// 1. Loads unique merge contracts (LRU cached across batches)
/// 2. Discovers index configurations per resource type (LRU cached across batches)
/// 3. Batch-loads all index/template documents needed by sync [determineShards]
StreamTransformer<DecodedCandidateEvent, PreloadedCandidateEvent>
    preloadCandidates(
  MergeContractLoader mergeContractLoader,
  IndexDiscovery indexDiscovery,
  ShardDeterminer shardDeterminer,
  Storage storage, {
  int batchSize = defaultPipelineBatchSize,
}) {
  return StreamTransformer.fromBind((stream) async* {
    final buffer = <DecodedCandidate>[];
    final contractCache = LRUCache<String, MergeContract>();
    final indexConfigCache = LRUCache<IriTerm, Iterable<CrdtIndexData>>();

    Stream<PreloadedCandidate> preloadChunk(
        List<DecodedCandidate> chunk) async* {
      // 1. Load merge contracts for unique governance IRI sets.
      for (final candidate in chunk) {
        final key = _governanceKey(candidate.governanceIris);
        if (!contractCache.containsKey(key)) {
          contractCache[key] =
              await mergeContractLoader.load(candidate.governanceIris);
        }
      }

      // 2. Discover index configs for unique resource types.
      for (final candidate in chunk) {
        final typeIri = candidate.typeIri;
        if (!indexConfigCache.containsKey(typeIri)) {
          indexConfigCache[typeIri] =
              await indexDiscovery.discoverIndices(typeIri);
        }
      }

      // 3. Collect all index/template document IRIs needed by determineShards.
      final allDocIris = <IriTerm>{};
      for (final candidate in chunk) {
        final configs = indexConfigCache[candidate.typeIri]!;
        allDocIris.addAll(
          shardDeterminer.collectRequiredDocumentIris(
              configs, candidate.typeIri),
        );
      }

      // 4. Batch-load all required documents in one I/O call.
      final loadedDocs = allDocIris.isNotEmpty
          ? await storage.getDocumentsByIri(allDocIris.toList())
          : const <IriTerm, StoredDocument?>{};

      // 5. Emit PreloadedCandidate for each buffered item.
      for (final candidate in chunk) {
        yield PreloadedCandidate(
          decoded: candidate,
          mergeContract:
              contractCache[_governanceKey(candidate.governanceIris)]!,
          indexConfigs: indexConfigCache[candidate.typeIri]!,
          documents: loadedDocs,
        );
      }
    }

    await for (final event in stream) {
      switch (event) {
        case DecodedCandidate():
          buffer.add(event);
          if (buffer.length >= batchSize) {
            yield* preloadChunk(buffer);
            buffer.clear();
          }
        case ShardComplete():
          if (buffer.isNotEmpty) {
            yield* preloadChunk(buffer);
            buffer.clear();
          }
          yield event;
        case PhaseComplete():
          if (buffer.isNotEmpty) {
            yield* preloadChunk(buffer);
            buffer.clear();
          }
          yield event;
      }
    }
  });
}

/// Deterministic key for governance IRI sets (for deduplication).
String _governanceKey(List<IriTerm> iris) =>
    iris.map((iri) => iri.value).join('|');
