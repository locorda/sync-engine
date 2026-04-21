/// Stage 4: Change Detection — classify resources for sync by diffing local
/// vs remote shard entries.
///
/// This stage performs the 1:N fan-out (one [ShardResult] → N [SyncCandidate]
/// events) and introduces [ShardComplete] at the end of each shard.
///
/// **Implementation**: `StreamTransformer` wrapping per-shard `asyncExpand`.
/// Each shard queries its local entries individually, which keeps downstream
/// stages fed while the next shard's DB query is in flight.
///
/// **Input**: `Stream<ParsedShardEvent>`
/// **Output**: `Stream<SyncCandidateEvent>`
library;

import 'dart:async';

import 'package:locorda_core/src/index/index_config_base.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/storage/storage_interface.dart';
import 'package:locorda_core/src/sync/pipeline/pipeperf.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:logging/logging.dart';

final _log = Logger('Stage4.ChangeDetection');

/// Returns a [StreamTransformer] for Stage 4.
///
/// Issues a single upfront [Storage.getShardsWithLocalChangesSince] query to
/// determine which shards have any locally-modified entries. For
/// [ShardResultNotModified] events whose shard is *not* in this set, the
/// transformer emits [ShardComplete] immediately — no per-shard DB roundtrip.
/// This eliminates ~135 isolate roundtrips on no-change syncs.
///
/// If more shards than [limit] have local changes, the upfront query returns
/// `null` and all [ShardResultNotModified] events fall back to per-shard
/// queries (no worse than the pre-optimization path).
///
/// [ParsedShard] and [ShardResultGone] events are always processed fully
/// (per-shard DB query), as they require the complete local entry set for
/// diffing.
///
/// Usage: `stream.transform(changeDetection(storage, lastSyncTimestamp))`
StreamTransformer<ParsedShardEvent, SyncCandidateEvent> changeDetection(
  Storage storage,
  int lastSyncTimestamp, {
  PipeperfCollector? perf,
}) {
  return StreamTransformer.fromBind((stream) async* {
    // Single upfront query: which shards have any locally-changed entries?
    // Returns null if more than 20 shards changed — in that case we fall
    // back to per-shard queries (the upfront filter isn't worth it).
    final Set<IriTerm>? shardsWithChanges;
    try {
      shardsWithChanges =
          await storage.getShardsWithLocalChangesSince(lastSyncTimestamp);
    } catch (e, st) {
      _log.warning('S04: upfront query failed', e, st);
      yield PhaseError(e, st, stage: 'S04');
      return;
    }

    await for (final event in stream) {
      switch (event) {
        // --- Shard Events ---
        case ShardError():
          yield event;
        case ParsedShard():
          try {
            await for (final e in _handleParsedShard(
                event, storage, lastSyncTimestamp, perf)) {
              yield e;
            }
          } catch (e, st) {
            _log.warning(
                'S04: failed to process shard ${event.shardIri}', e, st);
            yield ShardError(event.shardIri, e, st);
          }
        case ShardResultNotModified():
          try {
            if (shardsWithChanges == null ||
                shardsWithChanges.contains(event.shardIri)) {
              await for (final e in _handleNotModified(
                  event, storage, lastSyncTimestamp, perf)) {
                yield e;
              }
            } else {
              yield ShardSkipped(event.shardIri, event.shardStorageId,
                  existsOnRemote: true, newEtag: event.storedEtag);
            }
          } catch (e, st) {
            _log.warning(
                'S04: failed to process shard ${event.shardIri}', e, st);
            yield ShardError(event.shardIri, e, st);
          }
        case ShardResultNotFound():
          try {
            await for (final e
                in _handleNotFound(event, storage, lastSyncTimestamp, perf)) {
              yield e;
            }
          } catch (e, st) {
            _log.warning(
                'S04: failed to process shard ${event.shardIri}', e, st);
            yield ShardError(event.shardIri, e, st);
          }
        case ShardResultGone():
          try {
            await for (final e in _handleGone(event, storage, perf)) {
              yield e;
            }
          } catch (e, st) {
            _log.warning(
                'S04: failed to process shard ${event.shardIri}', e, st);
            yield ShardError(event.shardIri, e, st);
          }

        // --- Phase Events ---
        case PhaseComplete():
          yield event;
        case PhaseError():
          yield event;
      }
    }
  });
}

/// ParsedShard: diff local entries against remote entries, classify each.
Stream<SyncCandidateEvent> _handleParsedShard(
  ParsedShard parsed,
  Storage storage,
  int lastSyncTimestamp,
  PipeperfCollector? perf,
) async* {
  final shardIri = parsed.shardIri;
  final shardStorageId = parsed.shardStorageId;

  // typeIri is required for SyncCandidate — skip if missing
  final typeIri = parsed.typeIri;
  if (typeIri == null) {
    _log.warning('ParsedShard ${shardIri.debug} has no typeIri — skipping');
    yield ShardSkipped(shardIri, shardStorageId);
    return;
  }
  final sw = perf?.start('S04.ChangeDetect');

  final fetchPolicy = parsed.fetchPolicy;

  // Extract filter predicate if PrefetchFiltered.
  // When preloadedResourceDocIris is set, availability overrides fetch policy,
  // but filterPredicate is still used to extract header values for the entry map.
  final filterPredicate =
      fetchPolicy is PrefetchFiltered ? fetchPolicy.filterPredicate : null;

  // Build remote entry map from parsed entries + shard graph for filter values
  final remoteEntries = _buildRemoteEntryMap(parsed, filterPredicate);

  // Load local entries; exclude remote-only placeholders from classification
  // so they are never confused with genuine local state during diffing.
  final localEntries = await storage.getActiveIndexEntriesForShard(shardIri);
  final genuineLocalEntries =
      localEntries.where((e) => !e.isRemoteOnly).toList(growable: false);
  final localByResource =
      _buildLocalEntryMap(genuineLocalEntries, filterPredicate);

  // Diff: all resource IRIs present on either side
  final allResources = <IriTerm>{
    ...remoteEntries.keys,
    ...localByResource.keys,
  };
  final candidates = <SyncCandidate?>[];
  for (final resourceIri in allResources) {
    final remote = remoteEntries[resourceIri];
    final local = localByResource[resourceIri];

    candidates.add(_classify(
      resourceIri: resourceIri,
      shardStorageId: shardStorageId,
      typeIri: typeIri,
      localClockHash: local?.clockHash,
      remoteClockHash: remote?.clockHash,
      localFilterValues: local?.filterValues,
      remoteFilterValues: remote?.filterValues,
      fetchPolicy: fetchPolicy,
      preloadedResourceDocIris: parsed.preloadedResourceDocIris,
    ));
  }

  // Persist remote-only placeholders for entries skipped by fetch policy.
  // Without this, shard regeneration (Stage 11a) would omit those entries and
  // Stage 11c CRDT-merge would generate tombstones for them.
  // Skip only when everything is guaranteed to be fetched: fetchPolicy is
  // Prefetch AND no preloaded set restricts availability.
  final allResourcesFetched =
      fetchPolicy is Prefetch && parsed.preloadedResourceDocIris == null;
  if (!allResourcesFetched) {
    final indexIriMap = await storage.getIndexIrisForShards([shardIri]);
    final indexIri = indexIriMap[shardIri];
    if (indexIri != null) {
      final entriesToUpsert = [
        for (final entry in parsed.entries)
          if (!localByResource.containsKey(entry.resourceIri) &&
              !_shouldFetchRemoteOnly(
                  entry.resourceIri,
                  fetchPolicy,
                  parsed.preloadedResourceDocIris,
                  remoteEntries[entry.resourceIri]?.filterValues,
                  null))
            (
              resourceIri: entry.resourceIri,
              clockHash: entry.clockHash,
              headerProperties: entry.headerProperties,
            ),
      ];
      await storage.syncRemoteOnlyShardEntries(
        shardIri: shardIri,
        indexIri: indexIri,
        typeIri: typeIri,
        entriesToUpsert: entriesToUpsert,
        allCurrentRemoteIris: remoteEntries.keys.toSet(),
      );
    }
  }

  sw?.stop();

  for (final candidate in candidates) {
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

/// ShardNotModified: emit remoteShardUnchanged for locally-changed entries.
Stream<SyncCandidateEvent> _handleNotModified(
  ShardResultNotModified result,
  Storage storage,
  int lastSyncTimestamp,
  PipeperfCollector? perf,
) async* {
  final sw = perf?.start('S04.ChangeDetect');
  final changedEntries = await storage.getLocallyChangedEntriesForShard(
      result.shardIri, lastSyncTimestamp);
  sw?.stop();
  for (final entry in changedEntries) {
    yield SyncCandidate(
      entry.resourceIri,
      result.shardStorageId,
      SyncDirection.remoteShardUnchanged,
      result.typeIri,
      localClockHash: entry.clockHash,
    );
  }

  // Note: we intentionally emit ShardComplete (not ShardSkipped) even when
  // changedEntries is empty. getLocallyChangedEntriesForShard only tracks
  // resource-level changes within a shard, but entry *removals* (e.g. a
  // resource moving groups) are invisible to it. The shard still needs
  // S10–S11 to regenerate its entry list and produce tombstones.
  // Only the upfront shardsWithChanges shortcut (which includes deleted
  // entries) can safely emit ShardSkipped.
  yield ShardComplete(result.shardIri, result.shardStorageId,
      existsOnRemote: true, newEtag: result.storedEtag);
}

/// ShardResultNotFound: shard never uploaded — treat local entries as
/// [SyncDirection.remoteShardUnchanged] and mark shard as not on remote so
/// Stage 11c creates and uploads it.
Stream<SyncCandidateEvent> _handleNotFound(
  ShardResultNotFound result,
  Storage storage,
  int lastSyncTimestamp,
  PipeperfCollector? perf,
) async* {
  final sw = perf?.start('S04.ChangeDetect');
  final changedEntries = await storage.getLocallyChangedEntriesForShard(
      result.shardIri, lastSyncTimestamp);
  sw?.stop();
  for (final entry in changedEntries) {
    yield SyncCandidate(
      entry.resourceIri,
      result.shardStorageId,
      SyncDirection.remoteShardUnchanged,
      result.typeIri,
      localClockHash: entry.clockHash,
    );
  }
  yield ShardComplete(result.shardIri, result.shardStorageId,
      existsOnRemote: false, newEtag: null);
}

/// ShardGone: emit all local entries as shardGone.
Stream<SyncCandidateEvent> _handleGone(
  ShardResultGone result,
  Storage storage,
  PipeperfCollector? perf,
) async* {
  final sw = perf?.start('S04.ChangeDetect');
  final localEntries =
      await storage.getActiveIndexEntriesForShard(result.shardIri);
  sw?.stop();

  for (final entry in localEntries) {
    yield SyncCandidate(
      entry.resourceIri,
      result.shardStorageId,
      SyncDirection.shardGone,
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
  if (filterPredicate == null) {
    // Fast path: no filter, just use parsed entries directly
    return {
      for (final entry in parsed.entries)
        entry.resourceIri: _EntryData(entry.clockHash)
    };
  }
  final graph = parsed.decodedGraph.graph;
  final result = <IriTerm, _EntryData>{};
  for (final entry in parsed.entries) {
    final filterValues =
        graph.getMultiValueObjects<RdfObject>(entry.entryIri, filterPredicate);
    result[entry.resourceIri] = _EntryData(
      entry.clockHash,
      filterValues: filterValues.isNotEmpty ? filterValues : null,
    );
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
  required Set<IriTerm>? preloadedResourceDocIris,
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
    // New from remote — apply fetch policy (or preloaded set if available)
    if (!_shouldFetchRemoteOnly(resourceIri, fetchPolicy,
        preloadedResourceDocIris, remoteFilterValues, localFilterValues)) {
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
      SyncDirection.notInRemoteShard,
      typeIri,
      localClockHash: localClockHash,
    );
  }

  return null; // should not happen
}

/// Whether a remoteOnly resource should be fetched.
///
/// When [preloadedResourceDocIris] is non-null, the backend owns the decision:
/// only resources whose document IRI is in the set were cached and will be
/// processed — fetch policy is ignored. This replaces the former boolean
/// `allResourcesAvailable` flag with a precise, per-resource answer.
///
/// When [preloadedResourceDocIris] is null, normal [fetchPolicy] semantics apply.
bool _shouldFetchRemoteOnly(
  IriTerm resourceIri,
  RootResourceFetchPolicy? fetchPolicy,
  Set<IriTerm>? preloadedResourceDocIris,
  Set<RdfObject>? remoteFilterValues,
  Set<RdfObject>? localFilterValues,
) {
  if (preloadedResourceDocIris != null) {
    return preloadedResourceDocIris.contains(resourceIri.getDocumentIri());
  }
  return switch (fetchPolicy) {
    null =>
      true, // backend-injected shard — shouldn't occur without preloaded set
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
