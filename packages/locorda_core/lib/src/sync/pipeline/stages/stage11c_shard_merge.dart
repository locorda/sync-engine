/// Stage 11c: Shard CRDT Merge — sync merge with pre-loaded contract, encode.
///
/// **Implementation**: `.expand()` — pure CPU, no I/O. The merge contract
/// was pre-loaded by Stage 11b.
///
/// **Input**: `Stream<ContractLoadedShardEvent>`
/// **Output**: `Stream<MergedShardEvent>`
library;

import 'package:locorda_core/src/crdt_document_manager.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/storage/storage_interface.dart';
import 'package:locorda_core/src/sync/pipeline/pipeperf.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';
import 'package:locorda_core/src/sync/remote_document_merger.dart';
import 'package:locorda_core/src/sync/shard_document_generator.dart';
import 'package:locorda_core/src/vocab/generated/_index.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:locorda_rdf_jelly/jelly.dart';
import 'package:logging/logging.dart';

final _log = Logger('Stage11c.ShardMerge');

/// Returns an `.expand()` function for Stage 11c.
///
/// CRDT-merges the prepared shard entries with the existing local shard
/// document using the pre-loaded merge contract, then encodes the result.
///
/// When the remote returned a 200 response (i.e. [PreparedShard.remoteShardGraph]
/// is non-null), a structural CRDT merge between local and remote is performed
/// first via [RemoteDocumentMerger]. This preserves framework metadata from
/// foreign installations (clock entries, tombstones, `cm:createdAt`) that
/// are not present in the locally-generated shard document.
Iterable<MergedShardEvent> Function(ContractLoadedShardEvent) mergeShards(
  CrdtDocumentManager documentManager,
  RemoteDocumentMerger merger,
  RdfCore rdfCore, {
  PipeperfCollector? perf,
  String perfStage = 'S11c.ShardMerge',
}) {
  return (ContractLoadedShardEvent event) => switch (event) {
        // --- Shard Events ---
        ConflictedShard() => [event],
        ShardError() => [event],
        ShardSkipped() => [event],
        ContractLoadedShard() => _mergeOrError(
            event, documentManager, merger, rdfCore, perf, perfStage),

        // --- Phase Events ---
        PhaseComplete() => [event],
        PhaseError() => [event],
      };
}

/// Wraps [_merge] with error handling — emits [ShardError] on failure.
List<MergedShardEvent> _mergeOrError(
  ContractLoadedShard loaded,
  CrdtDocumentManager documentManager,
  RemoteDocumentMerger merger,
  RdfCore rdfCore,
  PipeperfCollector? perf,
  String perfStage,
) {
  try {
    return _merge(loaded, documentManager, merger, rdfCore, perf, perfStage);
  } catch (e, st) {
    _log.severe('Error merging shard ${loaded.prepared.shardIri.debug}', e, st);
    return [ShardError(loaded.prepared.shardIri, e, st)];
  }
}

List<MergedShardEvent> _merge(
  ContractLoadedShard loaded,
  CrdtDocumentManager documentManager,
  RemoteDocumentMerger merger,
  RdfCore rdfCore,
  PipeperfCollector? perf,
  String perfStage,
) {
  final p = loaded.prepared;
  final shardIri = p.shardIri;
  final shardDocumentIri = shardIri.getDocumentIri();
  final sw = perf?.start(perfStage);
  try {
    // When a 200 response was received, merge remote CRDT framework metadata
    // (foreign clock entries, tombstones) into the local shard before applying
    // local entry changes. Without this, multi-installation scenarios lose
    // the foreign installation's CRDT history entirely.
    final StoredDocument? effectiveDoc;
    if (p.remoteShardGraph != null) {
      final mergeResult = merger.merge(
        mergeContract: loaded.mergeContract,
        documentIri: shardDocumentIri,
        localGraph: p.localDoc?.document,
        remoteGraph: p.remoteShardGraph!.graph,
      );
      effectiveDoc = StoredDocument(
        documentIri: shardDocumentIri,
        document: mergeResult.mergedGraph,
        metadata: p.localDoc?.metadata ??
            DocumentMetadata(ourPhysicalClock: 0, updatedAt: 0),
      );
    } else {
      effectiveDoc = p.localDoc;
    }
    sw?.stopSection('remoteMerge');

    // Early-exit: skip expensive CRDT diff when entry triples are unchanged.
    // Only applies to local-only path (no remote merge needed).
    if (p.remoteShardGraph == null && effectiveDoc != null) {
      final doc = effectiveDoc.document;
      final oldEntryTriples = _extractEntryTriples(doc, shardIri);
      final newEntryTriples = p.entryTriples.toSet();
      if (oldEntryTriples.length == newEntryTriples.length &&
          oldEntryTriples.containsAll(newEntryTriples)) {
        sw?.stopSection('earlyExit');
        // Content unchanged — encode existing graph for downstream stages
        // (S12 upload if needed, S13 DB commit, S14 feedback).
        final encoded = BinaryGraphSource(
          rdfCore.encodeBinary(doc, contentType: jelly.primaryMimeType),
          contentType: jelly.primaryMimeType,
        );
        sw?.stopSection('encode');
        return [
          MergedShard(
            shardIri,
            DecodedGraphSource(doc, originalSource: encoded),
            encoded,
            newEtag: p.newEtag,
            needsUpload: !p.existsOnRemote,
            ourPhysicalClock: effectiveDoc.metadata.ourPhysicalClock,
          ),
        ];
      }
    }

    // CRDT-merge via sync path — picks up existing HLC clock.
    final prepared = documentManager.prepareModifyWithContract(
      IdxShard.classIri,
      shardIri,
      (oldAppData) =>
          buildShardAppData(oldAppData, shardIri, p.indexIri, p.entryTriples),
      effectiveDoc,
      loaded.mergeContract,
      acceptMissing: true,
      perf: perf,
    );
    sw?.stopSection('prepareModify');
    if (prepared == null) {
      // No changes — shard is already up-to-date locally.
      // effectiveDoc is either the merged remote shard (200 response) or the
      // existing local shard (304 / local-only path). It is never null here
      // because acceptMissing=true guarantees at least RdfGraph() is passed.
      final baseGraph = effectiveDoc?.document;
      if (baseGraph == null) return const [];

      final encoded = BinaryGraphSource(
        rdfCore.encodeBinary(baseGraph, contentType: jelly.primaryMimeType),
        contentType: jelly.primaryMimeType,
      );
      sw?.stopSection('encode');

      return [
        MergedShard(
          shardIri,
          DecodedGraphSource(baseGraph, originalSource: encoded),
          encoded,
          newEtag: p.newEtag,
          needsUpload: !p.existsOnRemote,
          ourPhysicalClock: effectiveDoc?.metadata.ourPhysicalClock ?? 0,
        ),
      ];
    }

    // Encode merged shard document.
    final mergedGraph = prepared.crdtDocument;
    final encoded = BinaryGraphSource(
      rdfCore.encodeBinary(mergedGraph, contentType: jelly.primaryMimeType),
      contentType: jelly.primaryMimeType,
    );
    sw?.stopSection('encode');

    return [
      MergedShard(
        shardIri,
        DecodedGraphSource(mergedGraph, originalSource: encoded),
        encoded,
        newEtag: p.newEtag,
        needsUpload: true,
        ourPhysicalClock: prepared.physicalTime,
      ),
    ];
  } finally {
    sw?.stop();
  }
}

/// Extracts the entry-related triples from a shard document.
///
/// Collects all `idx:containsEntry` triples from [shardIri] and all property
/// triples of the referenced entry IRIs.
Set<Triple> _extractEntryTriples(RdfGraph doc, IriTerm shardIri) {
  final result = <Triple>{};
  final containsEntries =
      doc.findTriples(subject: shardIri, predicate: IdxShard.containsEntry);
  for (final ce in containsEntries) {
    result.add(ce);
    final entryIri = ce.object;
    if (entryIri is IriTerm) {
      result.addAll(doc.findTriples(subject: entryIri));
    }
  }
  return result;
}
