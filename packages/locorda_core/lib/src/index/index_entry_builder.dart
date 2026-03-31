/// Pure CPU functions for building [SaveIndexEntryRequest]s from pre-loaded data.
///
/// Used by Stage 7c (pipeline path) to construct index entries without I/O.
/// The non-pipeline path in [IndexManager] has equivalent private methods.
library;

import 'package:locorda_core/src/index/shard_determiner.dart';
import 'package:locorda_core/src/mapping/resource_locator.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/storage/storage_interface.dart';
import 'package:locorda_core/src/vocab/generated/_index.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:logging/logging.dart';

final _log = Logger('IndexEntryBuilder');

/// Builds [SaveIndexEntryRequest]s for a single resource document.
///
/// Handles both active shard entries and tombstoned shard entries.
/// All inputs must be pre-loaded — this function does no I/O.
///
/// Parameters:
/// - [shardToIndex]: maps shard IRIs to parent index IRIs (from [ShardDeterminationResult])
/// - [resolvedGroupIndices]: for deriving GroupIndex → template IRI mapping
/// - [indexedProperties]: maps index/template resource IRI → set of property IRIs to index
/// - [resourceLocator]: for inferring index IRI from tombstoned shard IRIs
List<SaveIndexEntryRequest> buildIndexEntries({
  required IriTerm resourceIri,
  required IriTerm typeIri,
  required String clockHash,
  required RdfGraph graph,
  required IriTerm documentIri,
  required Map<IriTerm, IriTerm> shardToIndex,
  required List<ResolvedGroupIndex> resolvedGroupIndices,
  required Map<IriTerm, Set<IriTerm>> indexedProperties,
  required ResourceLocator resourceLocator,
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

  // Tombstoned shard entries
  final tombstonedShards = collectTombstonedShards(graph, documentIri);
  for (final shardIri in tombstonedShards) {
    // Skip shards that are still active (tombstone + active = active wins)
    if (shardToIndex.containsKey(shardIri)) continue;

    final indexIri = _inferIndexIriFromShardIri(shardIri, resourceLocator);
    if (indexIri == null) {
      _log.warning(
          'Cannot infer index IRI for tombstoned shard ${shardIri.value}, '
          'skipping tombstone entry');
      continue;
    }

    requests.add(SaveIndexEntryRequest(
      shardIri: shardIri,
      indexIri: indexIri,
      resourceIri: resourceIri,
      resourceType: typeIri,
      clockHash: '',
      isDeleted: true,
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
  if (reifiedStmts.isEmpty) return const {};

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

/// Infers the parent index IRI from a shard IRI using naming conventions.
///
/// Handles both FullIndex and GroupIndex shard IRIs. Returns `null` if
/// the shard IRI doesn't follow the expected naming pattern.
IriTerm? _inferIndexIriFromShardIri(
    IriTerm shardIri, ResourceLocator resourceLocator) {
  final shardDocIri = shardIri.getDocumentIri();
  if (!resourceLocator.isIdentifiableIri(shardDocIri)) return null;

  try {
    final iri = resourceLocator.fromIri(shardDocIri,
        expectedTypeIri: IdxShard.classIri);
    final shardId = iri.id;

    final type = shardId.startsWith('index-full-')
        ? IdxFullIndex.classIri
        : shardId.startsWith('index-grouped-')
            ? IdxGroupIndex.classIri
            : null;

    if (type != null && shardId.contains('/')) {
      final indexId =
          shardId.substring(0, shardId.lastIndexOf('/') + 1) + 'index';
      return resourceLocator.toIri(ResourceIdentifier(type, indexId, 'index'));
    }
  } on UnsupportedIriException catch (_) {
    // Not a parseable shard IRI
  }
  return null;
}
