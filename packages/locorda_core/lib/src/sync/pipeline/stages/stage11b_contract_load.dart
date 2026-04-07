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

/// Returns an `.asyncMap()` function for Stage 11b.
///
/// Loads the merge contract for each shard's governance IRI set.
FutureOr<ContractLoadedShardEvent> Function(PreparedShardEvent)
    loadShardContracts(
  MergeContractLoader mergeContractLoader,
) {
  return (PreparedShardEvent event) async => switch (event) {
        PhaseComplete() => event,
        ConflictedShard() => event,
        ShardComplete() => event,
        PreparedShard() => ContractLoadedShard(
            prepared: event,
            mergeContract: await mergeContractLoader.load(event.governanceIris),
          ),
      };
}
