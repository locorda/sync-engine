import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:locorda_core/src/vocab/generated/_index.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/storage/storage_interface.dart'
    show IndexEntryWithIri;
import 'package:locorda_rdf_core/core.dart';

class ShardDocumentGenerator {
  const ShardDocumentGenerator();

  /// Generates RDF graph for a complete shard document.
  ///
  /// Creates a graph containing idx:containsEntry links and entry fragments
  /// for all provided entries. Entries must be from the same shard.
  ///
  /// The generated graph contains:
  /// - idx:containsEntry links from shard to each entry
  /// - Entry fragments with idx:resource, cm:clockHash, and optional headers
  ///
  /// All installations must generate identical graphs for the same entries
  /// to ensure CRDT convergence.
  List<Node> generateShardNodes({
    required IriTerm shardDocumentIri,
    required IriTerm shardResourceIri,
    required Iterable<IndexEntryWithIri> entries,
  }) {
    final nodes = <Node>[];
    for (final entry in entries) {
      if (entry.isDeleted) {
        // Skip deleted entries - they are handled by DocumentManager tombstones
        continue;
      }
      // Extract header properties from graph if present
      Map<IriTerm, List<RdfObject>>? headerProperties;
      if (entry.headerProperties != null) {
        headerProperties = {};
        for (final triple in entry.headerProperties!
            .findTriples(subject: entry.resourceIri)) {
          headerProperties.putIfAbsent(triple.predicate as IriTerm, () => []);
          headerProperties[triple.predicate as IriTerm]!.add(triple.object);
        }
        if (headerProperties.isEmpty) {
          headerProperties = null;
        }
      }

      // Generate entry IRI and fragment
      final (entryIri, entryGraph) = _generateIndexEntry(
        shardDocumentIri: shardDocumentIri,
        itemResourceIri: entry.resourceIri,
        clockHash: entry.clockHash,
        headerProperties: headerProperties,
      );

      // Add entry fragment triples
      nodes.add((entryIri, entryGraph));
    }

    return nodes;
  }

  /// Generates RDF graph for an index entry.
  ///
  /// Creates a graph containing:
  /// - Link from shard to entry (idx:containsEntry)
  /// - Entry properties (idx:resource, crdt:clockHash, optional headers)
  ///
  /// All installations must generate identical fragments for the same resource
  /// to ensure CRDT convergence. Uses MD5-based fragment generation as specified
  /// in proposal 010-index-entry-iri-identification.md
  Node _generateIndexEntry({
    required IriTerm shardDocumentIri,
    required IriTerm itemResourceIri,
    required String clockHash,
    Map<IriTerm, List<RdfObject>>? headerProperties,
  }) {
    // Generate deterministic fragment from resource IRI
    final entryFragment = _generateEntryFragment(itemResourceIri);
    final entryIri = IriTerm('${shardDocumentIri.value}#$entryFragment');

    final triples = <Triple>[
      // Entry properties
      Triple(entryIri, IdxShardEntry.resource, itemResourceIri), // Immutable
      Triple(
        entryIri,
        IdxShardEntry.crdtClockHash,
        LiteralTerm(clockHash),
      ), // LWW-Register
    ];

    // Optional header properties (all LWW-Register)
    if (headerProperties != null) {
      for (final entry in headerProperties.entries) {
        triples.addMultiple(entryIri, entry.key, entry.value);
      }
    }

    return (entryIri, triples.toRdfGraph());
  }

  /// Generates deterministic fragment identifier for index entry.
  ///
  /// Uses MD5 hash of resource IRI to ensure all installations
  /// generate identical fragment identifiers for the same resource.
  ///
  /// This is a specification requirement (proposal 010) - all implementations
  /// MUST use this exact algorithm for interoperability.
  ///
  /// Returns: `entry-{32-char-md5-hex}` (e.g., `entry-a1b2c3d4...`)
  String _generateEntryFragment(IriTerm resourceIri) {
    // Use full IRI value, not prefixed form
    final bytes = utf8.encode(resourceIri.value);
    final digest = md5.convert(bytes);
    return 'entry-${digest.toString()}'; // Full 32-character hex string
  }
}

RdfGraph buildShardAppData(RdfGraph oldAppData, IriTerm shardIri,
    IriTerm indexIri, Iterable<Triple> newTriples) {
  final hasIsShardOf =
      oldAppData.hasTriples(subject: shardIri, predicate: IdxShard.isShardOf);
  final hasType =
      oldAppData.hasTriples(subject: shardIri, predicate: IdxShard.rdfType);
  return RdfGraph.fromTriples([
    ...oldAppData
        .subgraph(
          shardIri,
          filter: (triple, depth) => triple.predicate == IdxShard.containsEntry
              ? TraversalDecision.skip
              : TraversalDecision.include,
        )
        .triples,
    if (!hasType) Triple(shardIri, IdxShard.rdfType, IdxShard.classIri),
    if (!hasIsShardOf) Triple(shardIri, IdxShard.isShardOf, indexIri),
    ...newTriples
  ]);
}
