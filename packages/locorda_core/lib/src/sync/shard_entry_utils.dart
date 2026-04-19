/// Utilities for working with idx:ShardEntry nodes in RDF graphs.
///
/// These helpers centralise the structural-predicate filter that is needed
/// in multiple places (shard parse stage, CRDT document merger, etc.) so the
/// definition of "which predicates are structural vs. header properties" lives
/// in exactly one place.
library;

import 'package:locorda_core/src/vocab/generated/_index.dart';
import 'package:locorda_rdf_core/core.dart';

/// Returns `true` if [predicate] is a *structural* idx:ShardEntry predicate —
/// i.e. one that carries identity / clock metadata rather than user-defined
/// index properties.
///
/// Structural predicates: `idx:resource`, `crdt:clockHash`.
/// Everything else on a shard entry is considered a *header property*.
///
/// Accepts [RdfPredicate] (supertype of [IriTerm]) so callers that iterate
/// graph triples without an upfront cast can use this directly.
bool isShardEntryStructuralPredicate(RdfPredicate predicate) =>
    predicate == IdxShardEntry.resource ||
    predicate == IdxShardEntry.crdtClockHash;

/// Extracts header properties from a shard entry node in [graph].
///
/// Collects all triples whose subject is [entryIri] and whose predicate is
/// NOT a structural shard-entry predicate, then re-keys the subject to
/// [resourceIri] so downstream consumers see consistent subjects.
///
/// Returns `null` when the entry carries no header properties (bare entry with
/// only `idx:resource` + `crdt:clockHash`).
RdfGraph? extractShardEntryHeaderProperties(
  RdfGraph graph,
  IriTerm entryIri,
  IriTerm resourceIri,
) {
  final headerTriples = graph
      .findTriples(subject: entryIri)
      .where((t) => !isShardEntryStructuralPredicate(t.predicate))
      .map((t) => Triple(resourceIri, t.predicate, t.object))
      .toList(growable: false);
  return headerTriples.isEmpty ? null : RdfGraph.fromTriples(headerTriples);
}
