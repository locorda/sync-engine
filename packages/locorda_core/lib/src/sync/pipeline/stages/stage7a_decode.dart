/// Stage 7a: Decode & Classify — decode RDF sources, classify effective
/// direction, extract governance IRIs.
///
/// **Implementation**: `.map()` — pure CPU, no I/O.
///
/// **Input**: `Stream<FetchedCandidateEvent>`
/// **Output**: `Stream<DecodedCandidateEvent>`
library;

import 'package:locorda_core/src/mapping/merge_contract_loader.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:logging/logging.dart';

final _log = Logger('Stage7a.Decode');

/// Returns a `.map()` function for Stage 7a.
///
/// Decodes local/remote graph sources on demand, upgrades remoteOnly →
/// conflictCandidate when local data exists, and extracts governance IRIs
/// for batch contract loading in Stage 7b.
DecodedCandidateEvent Function(FetchedCandidateEvent) decodeCandidates(
  MergeContractLoader mergeContractLoader,
  RdfCore rdfCore,
) {
  return (FetchedCandidateEvent event) => switch (event) {
        // --- Resource Events ---
        ResourceError() => event,
        FetchedCandidate() =>
          _decodeOrError(event, mergeContractLoader, rdfCore),

        // --- Shard Events ---
        ShardSkipped() => event,
        ShardError() => event,
        ShardComplete() => event,

        // --- Phase Events ---
        PhaseComplete() => event,
        PhaseError() => event,
      };
}

DecodedCandidateEvent _decodeOrError(
  FetchedCandidate fetched,
  MergeContractLoader mergeContractLoader,
  RdfCore rdfCore,
) {
  try {
    return _decode(fetched, mergeContractLoader, rdfCore);
  } catch (e, st) {
    _log.warning(
        'S07a: failed to decode ${fetched.loaded.candidate.resourceIri}',
        e,
        st);
    return ResourceError(fetched.loaded.candidate.resourceIri, e, st);
  }
}

DecodedCandidate _decode(
  FetchedCandidate fetched,
  MergeContractLoader mergeContractLoader,
  RdfCore rdfCore,
) {
  final candidate = fetched.loaded.candidate;
  final documentIri = candidate.resourceIri.getDocumentIri();

  final remoteGraph = fetched.remoteSource?.decodeWith(rdfCore).graph;
  final localGraph = fetched.loaded.localSource?.decodeWith(rdfCore).graph;

  // Derive effective direction from actual data availability, not just the
  // S04 classification which is shard-scoped. S06 may have fetched remote
  // data even for remoteShardUnchanged (null ETag → forced fetch) or
  // notInRemoteShard (resource exists in a different remote shard).
  // Whenever both graphs are present we must merge, not pick a winner.
  final effectiveDirection = switch (candidate.direction) {
    SyncDirection.remoteOnly when localGraph != null =>
      SyncDirection.conflictCandidate,
    SyncDirection.remoteShardUnchanged
        when remoteGraph != null && localGraph != null =>
      SyncDirection.conflictCandidate,
    SyncDirection.notInRemoteShard
        when remoteGraph != null && localGraph != null =>
      SyncDirection.conflictCandidate,
    _ => candidate.direction,
  };

  final governanceIris = mergeContractLoader.getMergedGovernanceIris(
    [
      if (localGraph != null) localGraph,
      if (remoteGraph != null) remoteGraph,
    ],
    documentIri,
  );

  _log.finer(
      '${candidate.resourceIri.debug}: ${candidate.direction} → $effectiveDirection');

  return DecodedCandidate(
    resourceIri: candidate.resourceIri,
    documentIri: documentIri,
    typeIri: candidate.typeIri,
    localGraph: localGraph,
    remoteGraph: remoteGraph,
    effectiveDirection: effectiveDirection,
    governanceIris: governanceIris,
    localUpdatedAt: fetched.loaded.localUpdatedAt,
    remoteEtag: fetched.remoteEtag,
    localClockHash: candidate.localClockHash,
    remoteClockHash: candidate.remoteClockHash,
  );
}
