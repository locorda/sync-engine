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
import 'package:locorda_core/src/index/index_property_resolver.dart';
import 'package:locorda_core/src/index/index_rdf_generator.dart';
import 'package:locorda_core/src/index/shard_determiner.dart';
import 'package:locorda_core/src/mapping/merge_contract.dart';
import 'package:locorda_core/src/mapping/merge_contract_loader.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/storage/storage_interface.dart';
import 'package:locorda_core/src/sync/pipeline/pipeperf.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';
import 'package:locorda_core/src/util/lru_cache.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:logging/logging.dart';

final _log = Logger('Stage7b.Preload');

/// Returns a StreamTransformer for Stage 7b.
///
/// Buffers [DecodedCandidate] events and flushes on boundary or batch-size cap.
/// For each batch:
/// 1. Loads merge contracts, index configs, and collects required doc IRIs
/// 2. Batch-loads all index/template documents needed by sync [determineShards]
/// 3. Extracts indexed property IRIs and emits [PreloadedCandidate]s
StreamTransformer<DecodedCandidateEvent, PreloadedCandidateEvent>
    preloadCandidates(
  MergeContractLoader mergeContractLoader,
  IndexDiscovery indexDiscovery,
  ShardDeterminer shardDeterminer,
  Storage storage,
  IndexRdfGenerator indexRdfGenerator, {
  int batchSize = defaultPipelineBatchSize,
  PipeperfCollector? perf,
  String perfStage = 'S07b.Preload',
}) {
  return StreamTransformer.fromBind((stream) async* {
    final buffer = <DecodedCandidate>[];
    final contractCache = LRUCache<String, MergeContract>();
    final indexConfigCache = LRUCache<IriTerm, Iterable<CrdtIndexData>>();
    // Cache: index/template resource IRI → extracted property IRIs
    final indexedPropertiesCache = LRUCache<IriTerm, Set<IriTerm>>();

    Stream<PreloadedCandidate> preloadChunk(
        List<DecodedCandidate> chunk) async* {
      final swIo = perf?.start('$perfStage.io');
      // 1. Load merge contracts, discover index configs, and collect
      //    all index/template document IRIs (all LRU cached across batches).
      final allDocIris = <IriTerm>{};
      for (final candidate in chunk) {
        final key = _governanceKey(candidate.governanceIris);
        if (!contractCache.containsKey(key)) {
          contractCache[key] =
              await mergeContractLoader.load(candidate.governanceIris);
        }
        final typeIri = candidate.typeIri;
        if (!indexConfigCache.containsKey(typeIri)) {
          indexConfigCache[typeIri] =
              await indexDiscovery.discoverIndices(typeIri);
        }
        allDocIris.addAll(
          shardDeterminer.collectRequiredDocumentIris(
              indexConfigCache[typeIri]!, typeIri),
        );
      }

      // 2. Batch-load all required documents in one I/O call.
      final loadedDocs = allDocIris.isNotEmpty
          ? await storage.getDocumentsByIri(allDocIris.toList())
          : const <IriTerm, StoredDocument?>{};
      swIo?.stop();

      // 3. Extract indexed properties and collect PreloadedCandidates (CPU).
      final swCpu = perf?.start('$perfStage.cpu');
      final results = <PreloadedCandidate>[];
      for (final candidate in chunk) {
        final configs = indexConfigCache[candidate.typeIri]!;
        final indexedProperties = <IriTerm, Set<IriTerm>>{};
        for (final config in configs) {
          final indexOrTemplateIri = indexRdfGenerator
              .generateIndexOrTemplateIri(config, candidate.typeIri);
          if (!indexedPropertiesCache.containsKey(indexOrTemplateIri)) {
            final docIri = indexOrTemplateIri.getDocumentIri();
            final storedDoc = loadedDocs[docIri];
            if (storedDoc != null) {
              indexedPropertiesCache[indexOrTemplateIri] =
                  IndexPropertyResolver.extractIndexedProperties(
                      storedDoc.document, indexOrTemplateIri);
            } else {
              indexedPropertiesCache[indexOrTemplateIri] = const {};
            }
          }
          final props = indexedPropertiesCache[indexOrTemplateIri]!;
          if (props.isNotEmpty) {
            indexedProperties[indexOrTemplateIri] = props;
          }
        }

        results.add(PreloadedCandidate(
          decoded: candidate,
          mergeContract:
              contractCache[_governanceKey(candidate.governanceIris)]!,
          indexConfigs: configs,
          documents: loadedDocs,
          indexedProperties: indexedProperties,
        ));
      }
      swCpu?.stop();
      for (final result in results) {
        yield result;
      }
    }

    Stream<PreloadedCandidateEvent> preloadChunkSafe(
        List<DecodedCandidate> chunk) async* {
      try {
        await for (final e in preloadChunk(chunk)) {
          yield e;
        }
      } catch (e, st) {
        _log.warning(
            'S07b: batch preload failed for ${chunk.length} candidates', e, st);
        for (final candidate in chunk) {
          yield ResourceError(candidate.resourceIri, e, st);
        }
      }
    }

    await for (final event in stream) {
      switch (event) {
        // --- Resource Events ---
        case DecodedCandidate():
          buffer.add(event);
          if (buffer.length >= batchSize) {
            yield* preloadChunkSafe(buffer);
            buffer.clear();
          }
        case ResourceError():
          yield event;

        // --- Shard Events ---
        case ShardError():
          // ShardError could be triggered due to a failed resource in this shard - keep processing the rest of the batch
          if (buffer.isNotEmpty) {
            yield* preloadChunkSafe(buffer);
            buffer.clear();
          }
          yield event;
        case ShardComplete():
          if (buffer.isNotEmpty) {
            yield* preloadChunkSafe(buffer);
            buffer.clear();
          }
          yield event;
        case ShardSkipped():
          assert(buffer.isEmpty,
              'S07b: buffer not empty at ShardSkipped — upstream protocol violation');
          if (buffer.isNotEmpty) {
            _log.severe('S07b: buffer unexpectedly non-empty '
                '(${buffer.length} items) at ShardSkipped for '
                '${event.shardIri} — discarding');
            buffer.clear();
          }
          yield event;

        // --- Phase Events ---
        case PhaseComplete():
          if (buffer.isNotEmpty) {
            yield* preloadChunkSafe(buffer);
            buffer.clear();
          }
          yield event;
        case PhaseError():
          assert(buffer.isEmpty,
              'S07b: buffer not empty at PhaseError — upstream protocol violation');
          if (buffer.isNotEmpty) {
            _log.severe('S07b: buffer unexpectedly non-empty '
                '(${buffer.length} items) at PhaseError — discarding');
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
