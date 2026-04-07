/// Stage 3: Shard Parse — decode fetched shard documents and extract entries.
///
/// **Implementation**: `stream.map()` — synchronous, no controller, zero
/// microtask overhead.
///
/// **Input**: `Stream<FetchedShardEvent>`
/// **Output**: `Stream<ParsedShardEvent>`
library;

import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';
import 'package:locorda_core/src/vocab/generated/_index.dart';
import 'package:locorda_rdf_core/core.dart';

/// Returns a map function for Stage 3 that parses fetched shards.
///
/// Usage: `stream.map(shardParse(rdfCore))`
ParsedShardEvent Function(FetchedShardEvent) shardParse(RdfCore rdfCore) =>
    (FetchedShardEvent event) => switch (event) {
          PhaseComplete() => event,
          ShardContent() => _parseShardContent(event, rdfCore),
          ShardNotModified() => ShardResultNotModified(
              event.shardIri,
              event.shardStorageId,
              event.fetchPolicy,
              event.typeIri,
              storedEtag: event.storedEtag,
            ),
          ShardNotFound() => ShardResultNotFound(
              event.shardIri,
              event.shardStorageId,
              event.fetchPolicy,
              event.typeIri,
            ),
          ShardGone() => ShardResultGone(
              event.shardIri,
              event.shardStorageId,
              event.fetchPolicy,
              event.typeIri,
            ),
        };

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
      entries.add(ShardEntry(entryIri, resourceIri, clockHash));
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
