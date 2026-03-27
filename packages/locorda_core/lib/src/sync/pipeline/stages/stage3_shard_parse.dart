/// Stage 3: Shard Parse — decode fetched shard documents and extract entries.
///
/// **Implementation**: `stream.map()` — synchronous, no controller, zero
/// microtask overhead.
///
/// **Input**: `Stream<FetchedShard | PhaseComplete>`
/// **Output**: `Stream<ShardResult | PhaseComplete>`
library;

import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';
import 'package:locorda_core/src/vocab/generated/_index.dart';
import 'package:locorda_rdf_core/core.dart';

/// Returns a map function for Stage 3 that parses fetched shards.
///
/// Usage: `stream.map(shardParse(rdfCore))`
///
/// Boundaries ([PhaseComplete]) pass through unchanged.
Object Function(Object) shardParse(RdfCore rdfCore) {
  return (Object event) {
    if (event is Boundary) return event;

    final fetched = event as FetchedShard;
    return switch (fetched) {
      ShardContent() => _parseShardContent(fetched, rdfCore),
      ShardNotModified() => ShardResultNotModified(
          fetched.shardIri, fetched.shardStorageId, fetched.fetchPolicy,
          fetched.typeIri),
      ShardGone() => ShardResultGone(
          fetched.shardIri, fetched.shardStorageId, fetched.fetchPolicy,
          fetched.typeIri),
    };
  };
}

ShardResult _parseShardContent(ShardContent content, RdfCore rdfCore) {
  // Decode the graph source
  final decoded = content.source.decodeWith(rdfCore);

  // Extract shard entries from the decoded graph
  final graph = decoded.graph;
  final shardIri = content.shardIri;

  final entryIris =
      graph.getMultiValueObjects<IriTerm>(shardIri, IdxShard.containsEntry);

  final entries = <ShardEntry>[];
  for (final entryIri in entryIris) {
    final resourceIri =
        graph.findSingleObject<IriTerm>(entryIri, IdxShardEntry.resource);
    final clockHash = graph
        .findSingleObject<LiteralTerm>(entryIri, IdxShardEntry.crdtClockHash)
        ?.value;

    if (resourceIri != null && clockHash != null) {
      entries.add(ShardEntry(resourceIri, clockHash));
    }
  }

  return ParsedShard(
    shardIri,
    content.shardStorageId,
    content.fetchPolicy,
    content.typeIri,
    entries,
    decoded,
    content.newEtag,
    allResourcesAvailable: content.allResourcesAvailable,
  );
}
