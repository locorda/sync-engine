/// Pure CPU functions for building [SaveIndexEntryRequest]s from pre-loaded data.
///
/// Used by Stage 7c (pipeline path) to construct index entries without I/O.
/// The non-pipeline path in [IndexManager] has equivalent private methods.
library;

import 'package:locorda_core/src/index/shard_determiner.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/storage/storage_interface.dart';
import 'package:locorda_core/src/vocab/generated/_index.dart';
import 'package:locorda_rdf_core/core.dart';

/// Builds [SaveIndexEntryRequest]s for active shard entries of a single resource.
///
/// Tombstoned shard entries are NOT built here — they require a DB lookup
/// for the `indexIri` (via [Storage.getIndexIrisForShards]) and are handled
/// in Stage 9. Use [collectTombstonedShards] to extract tombstoned shard IRIs.
///
/// All inputs must be pre-loaded — this function does no I/O.
List<SaveIndexEntryRequest> buildActiveIndexEntries({
  required IriTerm resourceIri,
  required IriTerm typeIri,
  required String clockHash,
  required RdfGraph graph,
  required Map<IriTerm, IriTerm> shardToIndex,
  required List<ResolvedGroupIndex> resolvedGroupIndices,
  required Map<IriTerm, Set<IriTerm>> indexedProperties,
  required int physicalTime,
}) {
  final requests = <SaveIndexEntryRequest>[];

  // Pre-build GroupIndex → template IRI mapping for property lookup
  final indexToTemplate = <IriTerm, IriTerm>{
    for (final r in resolvedGroupIndices) r.groupIndexIri: r.templateIri,
  };

  // Active shard entries
  for (final MapEntry(key: shardIri, value: indexIri) in shardToIndex.entries) {
    // For GroupIndex shards, properties are defined on the template
    final indexOrTemplateIri = indexToTemplate[indexIri] ?? indexIri;
    final properties = indexedProperties[indexOrTemplateIri] ?? const {};

    final headerProperties = _extractHeaderProperties(
      resourceIri: resourceIri,
      document: graph,
      propertiesToExtract: properties,
    );

    RdfGraph? headerPropertiesGraph;
    if (headerProperties != null) {
      headerPropertiesGraph = RdfGraph.fromTriples(headerProperties.entries
          .expand((e) => e.value.map((v) => Triple(resourceIri, e.key, v))));
    }

    requests.add(SaveIndexEntryRequest(
      shardIri: shardIri,
      indexIri: indexIri,
      resourceIri: resourceIri,
      resourceType: typeIri,
      clockHash: clockHash,
      headerProperties: headerPropertiesGraph,
      ourPhysicalClock: physicalTime,
      updatedAt: 0, // Set by Stage 9 at commit time
    ));
  }

  return requests;
}

/// Collects shard IRIs that have CRDT deletion tombstones.
///
/// Scans reified `idx:belongsToIndexShard` statements for `crdt:deletedAt`
/// markers. These represent shards the resource was removed from (e.g. due
/// to group membership changes).
Set<IriTerm> collectTombstonedShards(
    RdfGraph crdtDocument, IriTerm documentIri) {
  final reifiedStmts =
      crdtDocument.findTriples(predicate: Rdf.subject, object: documentIri);
  if (reifiedStmts.isEmpty) return {};

  final tombstonedShards = <IriTerm>{};
  for (final reifiedStmt in reifiedStmts) {
    if (reifiedStmt.subject is! IriTerm) continue;
    final stmtIri = reifiedStmt.subject as IriTerm;

    final deletedAt =
        crdtDocument.findMaxDateTimeObject(stmtIri, Crdt.deletedAt);
    if (deletedAt == null) continue;

    final reifiedPredicate =
        crdtDocument.findSingleObject<IriTerm>(stmtIri, Rdf.predicate);
    if (reifiedPredicate != SyncManagedDocument.idxBelongsToIndexShard) {
      continue;
    }

    final shardIri =
        crdtDocument.findSingleObject<IriTerm>(stmtIri, Rdf.object);
    if (shardIri != null) {
      tombstonedShards.add(shardIri);
    }
  }

  return tombstonedShards;
}

/// Extracts header property values from a resource for index entries.
///
/// Returns `null` if no properties are configured or none have values.
Map<IriTerm, List<RdfObject>>? _extractHeaderProperties({
  required IriTerm resourceIri,
  required RdfGraph document,
  required Set<IriTerm> propertiesToExtract,
}) {
  if (propertiesToExtract.isEmpty) return null;

  final headerProperties = <IriTerm, List<RdfObject>>{};
  for (final propertyIri in propertiesToExtract) {
    final values = document.getMultiValueObjectList<RdfObject>(
      resourceIri,
      propertyIri,
    );
    if (values.isNotEmpty) {
      headerProperties[propertyIri] = values;
    }
  }

  return headerProperties.isEmpty ? null : headerProperties;
}
