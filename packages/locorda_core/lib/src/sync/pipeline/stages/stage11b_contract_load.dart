/// Stage 11b: Shard Contract Load — load merge contract for shard CRDT merge.
///
/// **Implementation**: `.asyncMap()` — single async call per shard. The
/// [MergeContractLoader] uses an LRU cache, so this is typically a cache hit
/// (all shards share the same governance IRI set).
///
/// **Input**: `Stream<PreparedShardEvent>`
/// **Output**: `Stream<ContractLoadedShardEvent>`
library;

import 'dart:async';

import 'package:locorda_core/src/mapping/merge_contract_loader.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';
import 'package:logging/logging.dart';

final _log = Logger('Stage11b.ContractLoad');

/// Returns an `.asyncMap()` function for Stage 11b.
///
/// Loads the merge contract for each shard's governance IRI set.
FutureOr<ContractLoadedShardEvent> Function(PreparedShardEvent)
    loadShardContracts(
  MergeContractLoader mergeContractLoader,
) {
  return (PreparedShardEvent event) async {
    try {
      return switch (event) {
        // --- Shard Events ---
        ConflictedShard() => event,
        ShardError() => event,
        ShardSkipped() => event,
        PreparedShard() => ContractLoadedShard(
            prepared: event,
            mergeContract: await mergeContractLoader.load(event.governanceIris),
          ),

        // --- Phase Events ---
        PhaseComplete() => event,
        PhaseError() => event,
      };
    } catch (e, st) {
      if (event is PreparedShard) {
        _log.warning(
            'S11b: failed to load contract for shard ${event.shardIri}', e, st);
        return ShardError(event.shardIri, e, st);
      }
      rethrow;
    }
  };
}
