/// Stage 4: Change Detection — classify resources for sync by diffing local
/// vs remote shard entries.
///
/// This stage performs the 1:N fan-out (one [ShardResult] → N [SyncCandidate]
/// events) and introduces [ShardComplete] at the end of each shard.
///
/// **Implementation**: `asyncExpand` — 1:N fan-out; O(shards) events per cycle.
///
/// **Input**: `Stream<ParsedShardEvent>`
/// **Output**: `Stream<SyncCandidateEvent>`
library;

import 'package:locorda_core/src/index/index_config_base.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/storage/storage_interface.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';
import 'package:locorda_core/src/vocab/generated/_index.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:logging/logging.dart';

final _log = Logger('Stage4.ChangeDetection');

/// Returns an asyncExpand function for Stage 4.
///
/// Usage: `stream.asyncExpand(changeDetection(storage, lastSyncTimestamp))`
Stream<SyncCandidateEvent> Function(ParsedShardEvent) changeDetection(
  Storage storage,
  int lastSyncTimestamp,
) {
  return (ParsedShardEvent event) async* {
    switch (event) {
      case PhaseComplete():
        yield event;
      case ParsedShard():
        yield* _handleParsedShard(event, storage, lastSyncTimestamp);
      case ShardResultNotModified():
        yield* _handleNotModified(event, storage, lastSyncTimestamp);
      case ShardResultGone():
        yield* _handleGone(event, storage);
    }
  };
}

/// ParsedShard: diff local entries against remote entries, classify each.
Stream<SyncCandidateEvent> _handleParsedShard(
  ParsedShard parsed,
  Storage storage,
  int lastSyncTimestamp,
) async* {
  final shardIri = parsed.shardIri;
  final shardStorageId = parsed.shardStorageId;

  // typeIri is required for SyncCandidate — skip if missing
  final typeIri = parsed.typeIri;
  if (typeIri == null) {
    _log.warning('ParsedShard ${shardIri.debug} has no typeIri — skipping');
    yield ShardComplete(shardIri, shardStorageId);
    return;
  }

  // Determine effective fetch policy
  final effectiveFetchPolicy = parsed.allResourcesAvailable
      ? RootResourceFetchPolicy.prefetch
      : parsed.fetchPolicy;

  // Extract filter predicate if PrefetchFiltered
  final filterPredicate = effectiveFetchPolicy is PrefetchFiltered
      ? effectiveFetchPolicy.filterPredicate
      : null;

  // Build remote entry map from parsed entries + shard graph for filter values
  final remoteEntries = _buildRemoteEntryMap(parsed, filterPredicate);

  // Load local entries
  final localEntries = await storage.getActiveIndexEntriesForShard(shardIri);
  final localByResource = _buildLocalEntryMap(localEntries, filterPredicate);

  // Diff: all resource IRIs present on either side
  final allResources = <IriTerm>{
    ...remoteEntries.keys,
    ...localByResource.keys,
  };
  for (final resourceIri in allResources) {
    final remote = remoteEntries[resourceIri];
    final local = localByResource[resourceIri];

    final candidate = _classify(
      resourceIri: resourceIri,
      shardStorageId: shardStorageId,
      typeIri: typeIri,
      localClockHash: local?.clockHash,
      remoteClockHash: remote?.clockHash,
      localFilterValues: local?.filterValues,
      remoteFilterValues: remote?.filterValues,
      fetchPolicy: effectiveFetchPolicy,
    );

    if (candidate != null) {
      yield candidate;
    }
  }

  yield ShardComplete(
    shardIri,
    shardStorageId,
    remoteShardGraph: parsed.decodedGraph,
    newEtag: parsed.newEtag,
    existsOnRemote: true,
  );
}

/// ShardNotModified: emit localOnly for locally-changed entries.
Stream<SyncCandidateEvent> _handleNotModified(
  ShardResultNotModified result,
  Storage storage,
  int lastSyncTimestamp,
) async* {
  final localEntries =
      await storage.getActiveIndexEntriesForShard(result.shardIri);
  for (final entry in localEntries) {
    if (entry.updatedAt > lastSyncTimestamp) {
      yield SyncCandidate(
        entry.resourceIri,
        result.shardStorageId,
        SyncDirection.localOnly,
        result.typeIri,
        localClockHash: entry.clockHash,
      );
    }
  }

  yield ShardComplete(result.shardIri, result.shardStorageId,
      existsOnRemote: result.existsOnRemote);
}

/// ShardGone: emit all local entries as remoteRemoved.
Stream<SyncCandidateEvent> _handleGone(
  ShardResultGone result,
  Storage storage,
) async* {
  final localEntries =
      await storage.getActiveIndexEntriesForShard(result.shardIri);

  for (final entry in localEntries) {
    yield SyncCandidate(
      entry.resourceIri,
      result.shardStorageId,
      SyncDirection.remoteRemoved,
      result.typeIri,
      localClockHash: entry.clockHash,
    );
  }

  yield ShardComplete(result.shardIri, result.shardStorageId);
}

// ---------------------------------------------------------------------------
// Entry maps
// ---------------------------------------------------------------------------

/// Lightweight entry data for classification.
class _EntryData {
  final String clockHash;
  final Set<RdfObject>? filterValues;

  const _EntryData(this.clockHash, {this.filterValues});
}

/// Build remote entry map from the parsed shard, extracting filter values
/// from the shard graph if a filter predicate is specified.
Map<IriTerm, _EntryData> _buildRemoteEntryMap(
  ParsedShard parsed,
  IriTerm? filterPredicate,
) {
  final result = <IriTerm, _EntryData>{};

  if (filterPredicate == null) {
    // Fast path: no filter, just use parsed entries directly
    for (final entry in parsed.entries) {
      result[entry.resourceIri] = _EntryData(entry.clockHash);
    }
    return result;
  }

  // Need filter values: walk the shard graph's containsEntry triples
  final graph = parsed.decodedGraph.graph;
  final entryIris = graph.getMultiValueObjects<IriTerm>(
      parsed.shardIri, IdxShard.containsEntry);

  for (final entryIri in entryIris) {
    final resourceIri =
        graph.findSingleObject<IriTerm>(entryIri, IdxShardEntry.resource);
    final clockHash = graph
        .findSingleObject<LiteralTerm>(entryIri, IdxShardEntry.crdtClockHash)
        ?.value;

    if (resourceIri != null && clockHash != null) {
      final filterValues =
          graph.getMultiValueObjects<RdfObject>(entryIri, filterPredicate);
      result[resourceIri] = _EntryData(
        clockHash,
        filterValues: filterValues.isNotEmpty ? filterValues : null,
      );
    }
  }

  return result;
}

/// Build local entry map from index entries, extracting filter values if needed.
Map<IriTerm, _EntryData> _buildLocalEntryMap(
  List<IndexEntryWithIri> localEntries,
  IriTerm? filterPredicate,
) {
  final result = <IriTerm, _EntryData>{};

  for (final entry in localEntries) {
    Set<RdfObject>? filterValues;
    if (filterPredicate != null && entry.headerProperties != null) {
      filterValues = entry.headerProperties!
          .getMultiValueObjects(entry.resourceIri, filterPredicate);
    }
    result[entry.resourceIri] = _EntryData(
      entry.clockHash,
      filterValues: filterValues,
    );
  }

  return result;
}

// ---------------------------------------------------------------------------
// Classification
// ---------------------------------------------------------------------------

/// Classify a single resource based on local/remote presence and fetch policy.
///
/// Returns null if the resource should be skipped (unchanged, or deferred by
/// onRequest policy).
SyncCandidate? _classify({
  required IriTerm resourceIri,
  required IriStorageId shardStorageId,
  required IriTerm typeIri,
  required String? localClockHash,
  required String? remoteClockHash,
  required Set<RdfObject>? localFilterValues,
  required Set<RdfObject>? remoteFilterValues,
  required RootResourceFetchPolicy? fetchPolicy,
}) {
  final existsLocally = localClockHash != null;
  final existsRemotely = remoteClockHash != null;

  if (existsLocally && existsRemotely) {
    if (localClockHash == remoteClockHash) {
      return null; // unchanged — skip
    }
    return SyncCandidate(
      resourceIri,
      shardStorageId,
      SyncDirection.conflictCandidate,
      typeIri,
      localClockHash: localClockHash,
      remoteClockHash: remoteClockHash,
    );
  }

  if (existsRemotely && !existsLocally) {
    // New from remote — apply fetch policy
    if (!_shouldFetchRemoteOnly(
        fetchPolicy, remoteFilterValues, localFilterValues)) {
      _log.fine(
          'Skipping remoteOnly ${resourceIri.debug} (fetch policy: $fetchPolicy)');
      return null;
    }
    return SyncCandidate(
      resourceIri,
      shardStorageId,
      SyncDirection.remoteOnly,
      typeIri,
      remoteClockHash: remoteClockHash,
    );
  }

  if (existsLocally && !existsRemotely) {
    return SyncCandidate(
      resourceIri,
      shardStorageId,
      SyncDirection.localOnly,
      typeIri,
      localClockHash: localClockHash,
    );
  }

  return null; // should not happen
}

/// Whether a remoteOnly resource should be fetched, based on fetch policy.
bool _shouldFetchRemoteOnly(
  RootResourceFetchPolicy? fetchPolicy,
  Set<RdfObject>? remoteFilterValues,
  Set<RdfObject>? localFilterValues,
) {
  if (fetchPolicy == null) {
    // Backend-injected shard with allResourcesAvailable — always fetch.
    return true;
  }
  return switch (fetchPolicy) {
    Prefetch() => true,
    OnRequest() => false,
    PrefetchFiltered() => _matchesPrefetchFilter(
        fetchPolicy, remoteFilterValues, localFilterValues),
  };
}

/// Check if an entry matches a PrefetchFiltered policy.
///
/// Mirrors the existing `_matchesFilter` logic: checks remote filter values
/// first, then local, defaults to true if neither available.
bool _matchesPrefetchFilter(
  PrefetchFiltered filter,
  Set<RdfObject>? remoteFilterValues,
  Set<RdfObject>? localFilterValues,
) {
  if (remoteFilterValues != null) {
    return remoteFilterValues
        .any((value) => filter.acceptedObjectValues.contains(value));
  }
  if (localFilterValues != null) {
    return localFilterValues
        .any((value) => filter.acceptedObjectValues.contains(value));
  }
  // No filter values available — don't filter (safe fallback)
  return true;
}
