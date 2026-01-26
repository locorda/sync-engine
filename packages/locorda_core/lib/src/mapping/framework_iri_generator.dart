import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:locorda_core/src/vocab/generated/_index.dart';
import 'package:locorda_core/src/vocab/generated/sync.dart';
import 'package:locorda_core/src/mapping/identified_blank_node_builder.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_rdf_core/core.dart';

class FrameworkIriGenerator {
  static const fragmentPrefix = 'lcrd-';

  final IriTermFactory _iriTermFactory;

  final NQuadsEncoder _nquadsEncoder = NQuadsEncoder(
    options: const NQuadsEncoderOptions(canonical: true),
  );

  FrameworkIriGenerator({IriTermFactory? iriTermFactory})
      : _iriTermFactory = iriTermFactory ?? IriTerm.validated;

  /// Generates a canonical IRI for an identified blank node based on its identification pattern.
  ///
  /// The canonical IRI is stable across serialization/deserialization and uniquely identifies
  /// the blank node based on:
  /// 1. Its parent (IRI or another identified blank node)
  /// 2. Its identifying properties and values
  ///
  /// The algorithm:
  /// 1. Builds a minimal RDF graph containing only identification information
  /// 2. Assigns deterministic blank node labels based on position in parent chain
  /// 3. Serializes to canonical N-Quads format
  /// 4. Generates MD5 hash and creates IRI: #lcrd-ibn-md5-{hash}
  ///
  /// Example:
  /// ```dart
  /// final canonicalIri = generateCanonicalIri(identifiedBlankNode);
  /// // Returns: IriTerm('locorda:md5:a3f9e2d1c4b5e6f7a8b9c0d1e2f3a4b5')
  /// ```
  IriTerm generateCanonicalBlankNodeIri(
      IriTerm documentIri, IdentifiedBlankNode identifiedBlankNode) {
    // Step 1 & 2: Build identification graph and assign deterministic labels
    final result = _buildIdentificationGraphWithLabels(identifiedBlankNode);

    // Step 3 & 4: Serialize to canonical N-Quads, hash it and generate IRI
    return _toCanonicalHashIri(documentIri, 'ibn', result.graph, result.labels);
  }

  IriTerm generateSimpleCanonicalIri(
      IriTerm documentIri, String fragmentType, List<Triple> triples,
      {Map<BlankNodeTerm, String> labels = const {}}) {
    if (triples.any(
        (t) => t.object is BlankNodeTerm || t.predicate is BlankNodeTerm)) {
      throw ArgumentError('Triples must not contain blank node objects.');
    }
    return _toCanonicalHashIri(
        documentIri, fragmentType, RdfGraph.fromTriples(triples), labels);
  }

  // Similar to generateCanonicalIri, but for statements

  IriTerm _toCanonicalHashIri(IriTerm documentIri, String type, RdfGraph graph,
      Map<BlankNodeTerm, String> labels) {
    final dataset = RdfDataset.fromDefaultGraph(graph);
    final nquads = _nquadsEncoder.encode(
      dataset,
      blankNodeLabels: labels,
      generateNewBlankNodeLabels: false,
    );

    final hash = md5.convert(utf8.encode(nquads)).toString();

    // Use the document Iri as base, and create a fragment IRI with #lcrd-ibn-{hash}
    return documentIri.withFragment(
        '${FrameworkIriGenerator.fragmentPrefix}${type}-md5-$hash',
        iriTermFactory: _iriTermFactory);
  }
}

/// Builds a minimal RDF graph containing only the identification information
/// and assigns deterministic blank node labels.
///
/// The graph includes:
/// - Parent relationship via sync:parent predicate
/// - All identifying properties and their values
/// - Recursive nesting for identified blank node parents
///
/// Labels are assigned in leaf-to-root order: the target blank node gets _:ibn0,
/// its parent gets _:ibn1, grandparent _:ibn2, etc.
_GraphWithLabels _buildIdentificationGraphWithLabels(IdentifiedBlankNode ibn) {
  final blankNodeMap = <IdentifiedBlankNode, BlankNodeTerm>{};
  final labels = <BlankNodeTerm, String>{};
  int labelCounter = 0;

  // Build triples and assign labels in a single traversal (leaf-to-root)
  Iterable<Triple> processNode(IdentifiedBlankNode current) sync* {
    // Get or create blank node for this IdentifiedBlankNode
    final subject = blankNodeMap.putIfAbsent(
      current,
      () => BlankNodeTerm(),
    );

    // Assign label if not already assigned (leaf-to-root ordering)
    if (!labels.containsKey(subject)) {
      labels[subject] = 'ibn$labelCounter';
      labelCounter++;
    }

    // Add parent triple
    final parent = current.parent;
    if (parent.isIri) {
      yield Triple(subject, Sync.parent, parent.iriTerm!);
    } else if (parent.isBlankNode) {
      // Recursively process parent blank node
      final parentIbn = parent.blankNode!;
      yield* processNode(parentIbn);
      final parentBlankNode = blankNodeMap[parentIbn]!;
      yield Triple(subject, Sync.parent, parentBlankNode);
    }
    // else: circuit breaker parent - should not happen here

    // Add parent predicate if available
    if (current.parentPredicate != null) {
      yield Triple(
          subject,
          Sync.parentProperty,
          switch (current.parentPredicate!) {
            IriTerm iri => iri,
          });
    }
    // Add identifying properties
    for (final entry in current.identifyingProperties.entries) {
      final predicate = entry.key;
      final objects = entry.value;
      for (final object in objects) {
        yield Triple(subject, predicate, object);
      }
    }
  }

  final triples = processNode(ibn).toList();

  return _GraphWithLabels(RdfGraph.fromTriples(triples), labels);
}

/// Result of building an identification graph with deterministic labels
class _GraphWithLabels {
  final RdfGraph graph;
  final Map<BlankNodeTerm, String> labels;

  _GraphWithLabels(this.graph, this.labels);
}
