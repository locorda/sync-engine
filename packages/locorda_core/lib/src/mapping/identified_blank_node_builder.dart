import 'package:locorda_core/src/config/validation.dart';
import 'package:locorda_core/src/vocab/generated/rdf.dart';
import 'package:locorda_core/src/mapping/framework_iri_generator.dart';
import 'package:locorda_core/src/mapping/merge_contract.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:logging/logging.dart';
import 'package:locorda_rdf_core/core.dart';

final _log = Logger('IdentifiedBlankNodeBuilder');

class IdentifiedBlankNodeParent {
  final IriTerm? _iriTerm;
  final IdentifiedBlankNode? _blankNode;
  final Set<BlankNodeTerm>? _circuitCheck;

  const IdentifiedBlankNodeParent._circuitBreaker(this._circuitCheck)
      : _iriTerm = null,
        _blankNode = null;

  const IdentifiedBlankNodeParent.forIri(IriTerm iri)
      : _iriTerm = iri,
        _blankNode = null,
        _circuitCheck = null;

  const IdentifiedBlankNodeParent.forIdentifiedBlankNode(
      IdentifiedBlankNode blankNode)
      : _iriTerm = null,
        _blankNode = blankNode,
        _circuitCheck = null;

  /// Get the IRI if this parent is an IRI, null otherwise
  IriTerm? get iriTerm => _iriTerm;

  /// Get the IdentifiedBlankNode if this parent is an IdentifiedBlankNode, null otherwise
  IdentifiedBlankNode? get blankNode => _blankNode;

  /// True if this parent is an IRI
  bool get isIri => _iriTerm != null;

  /// True if this parent is an IdentifiedBlankNode
  bool get isBlankNode => _blankNode != null;

  @override
  int get hashCode => Object.hashAll([_iriTerm, _blankNode]);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! IdentifiedBlankNodeParent) {
      return false;
    }
    return _iriTerm == other._iriTerm && _blankNode == other._blankNode;
  }
}

class IdentifiedBlankNode {
  final IdentifiedBlankNodeParent _parent;
  final Map<RdfPredicate, List<RdfObject>> _identifyingProperties;
  final RdfPredicate? _parentPredicate;

  IdentifiedBlankNode(this._parent, this._identifyingProperties,
      [this._parentPredicate])
      : assert(_identifyingProperties.isNotEmpty || _parentPredicate != null,
            'Blank node must be identified by either identifying properties or parent predicate');

  IdentifiedBlankNodeParent get parent => _parent;
  Map<RdfPredicate, List<RdfObject>> get identifyingProperties =>
      Map.unmodifiable(_identifyingProperties);
  RdfPredicate? get parentPredicate => _parentPredicate;

  Set<BlankNodeTerm> get _circuitCheck =>
      _parent._circuitCheck ?? _parent._blankNode?._circuitCheck ?? {};

  @override
  int get hashCode => Object.hashAll([
        _parent,
        _parentPredicate,
        _identifyingProperties.length,
        // Hash based on sorted entries for consistent results
        ..._identifyingProperties.entries
            .map((e) => Object.hashAll([e.key, e.value]))
            .toList()
          ..sort()
      ]);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! IdentifiedBlankNode) return false;

    return _parent == other._parent &&
        _parentPredicate == other._parentPredicate &&
        _identifyingProperties.length == other._identifyingProperties.length &&
        _identifyingProperties.entries.every((entry) {
          final otherValue = other._identifyingProperties[entry.key];
          return otherValue != null &&
              entry.value.length == otherValue.length &&
              entry.value.every(otherValue.contains);
        });
  }

  @override
  String toString() {
    return 'IdentifiedBlankNode(parent: $_parent, parentPredicate: $_parentPredicate, properties: $_identifyingProperties)';
  }

  Iterable<IdentifiedBlankNode> blankNodeChain() sync* {
    yield this;
    if (_parent.blankNode != null) {
      yield* _parent.blankNode!.blankNodeChain();
    }
  }
}

class IdentifiedBlankNodes<T> {
  final Map<BlankNodeTerm, List<T>> _identifiedMap;

  static IdentifiedBlankNodes<T> empty<T>() =>
      const IdentifiedBlankNodes(identifiedMap: const {});

  const IdentifiedBlankNodes(
      {required Map<BlankNodeTerm, List<T>> identifiedMap})
      : _identifiedMap = identifiedMap;

  /// Get all identified blank nodes for a specific blank node term
  bool hasIdentifiedNodes(BlankNodeTerm blankNode) =>
      _identifiedMap[blankNode] != null &&
      _identifiedMap[blankNode]!.isNotEmpty;

  List<T> getIdentifiedNodes(BlankNodeTerm blankNode) {
    final nodes = _identifiedMap[blankNode];
    if (nodes == null || nodes.isEmpty) {
      throw UnidentifiedBlankNodeException(blankNode);
    }
    return nodes;
  }

  /// Get all blank node terms that have been identified
  Iterable<BlankNodeTerm> get identifiedBlankNodes => _identifiedMap.keys;

  /// Check if a blank node has been identified
  bool isIdentified(BlankNodeTerm blankNode) =>
      _identifiedMap.containsKey(blankNode);
  bool isNotIdentified(BlankNodeTerm blankNode) =>
      !_identifiedMap.containsKey(blankNode);

  /// Get read-only access to the complete mapping
  Map<BlankNodeTerm, List<T>> get identifiedMap =>
      Map.unmodifiable(_identifiedMap);

  Iterable<T> getCanonicalIris(BlankNodeTerm subject) {
    final result = identifiedMap[subject];
    if (result == null || result.isEmpty) {
      throw UnidentifiedBlankNodeException(subject);
    }
    return result;
  }
}

class UnidentifiedBlankNodeException implements Exception {
  final BlankNodeTerm blankNode;
  final String? message;

  UnidentifiedBlankNodeException(this.blankNode, [this.message]);

  @override
  String toString() =>
      'UnidentifiedBlankNodeException:${message == null ? '' : ' $message'} The blank node $blankNode could not be identified.';
}

class UnidentifiedBlankNodeWithContextException implements Exception {
  final BlankNodeTerm blankNode;
  final String context;
  final List<Triple> subjectTriples;
  final List<Triple> objectTriples;

  UnidentifiedBlankNodeWithContextException(
      this.blankNode, this.context, this.subjectTriples, this.objectTriples);

  @override
  String toString() {
    final msg = '''
UnidentifiedBlankNodeWithContextException: The blank node $blankNode could not be identified.

It is found in the following triples of $context:

As subject:
${subjectTriples.map((t) => '  $t').join('\n')}

As object:
${objectTriples.map((t) => '  $t').join('\n')}

    ''';
    return msg;
  }
}

class IdentifiedBlankNodeBuilder {
  final FrameworkIriGenerator _iriGenerator;

  IdentifiedBlankNodeBuilder({required FrameworkIriGenerator iriGenerator})
      : _iriGenerator = iriGenerator;

  IdentifiedBlankNodes<IriTerm> computeCanonicalBlankNodes(
          IriTerm documentIri, RdfGraph graph, MergeContract mergeContract) =>
      computeIdentifiedBlankNodes<IriTerm>(
          graph,
          mergeContract,
          (ibn) =>
              _iriGenerator.generateCanonicalBlankNodeIri(documentIri, ibn));

  IdentifiedBlankNodes<T> computeIdentifiedBlankNodes<T>(RdfGraph graph,
      MergeContract mergeContract, T Function(IdentifiedBlankNode) converter) {
    final blankNodeSubjects = graph.subjects.whereType<BlankNodeTerm>().toSet();

    // 1st: find the identifying properties for each blank node. If there are none,
    // then we do not need to go further - the blank node cannot be identified
    final identifyingPredicates = {
      for (final blankNode in blankNodeSubjects)
        blankNode: mergeContract.getIdentifyingPredicates(graph, blankNode)
    };

    // 2nd: find the parent path(s) - store full triples to access predicates
    final parentTriples = graph.findTriples(
            objectIn: blankNodeSubjects)
        .fold(<BlankNodeTerm, List<Triple>>{}, (r, t) {
      r.putIfAbsent(t.object as BlankNodeTerm, () => <Triple>[]).add(t);
      return r;
    });

    final identifiedBlankNodes = <BlankNodeTerm, List<IdentifiedBlankNode>>{};

    // Process nodes in dependency order: IRI-rooted first, then blank-node-rooted
    final sortedNodes =
        _sortByDependencies(blankNodeSubjects.toList(), parentTriples);

    for (final blankNode in sortedNodes) {
      _addIdentifiedBlankNodes(graph, blankNode, identifyingPredicates,
          parentTriples, identifiedBlankNodes, mergeContract);
    }
    // ok, now we might have to clean up circular references
    final Set<BlankNodeTerm> circularReferences = identifiedBlankNodes.values
        .expand((l) => l.expand((i) => i._circuitCheck))
        .toSet();
    final reversedIdentifiedMap = <IdentifiedBlankNode, BlankNodeTerm>{};
    final duplicateBlankNodes = <IdentifiedBlankNode, List<BlankNodeTerm>>{};
    for (final entry in identifiedBlankNodes.entries) {
      for (final ibn in entry.value) {
        if (reversedIdentifiedMap.containsKey(ibn)) {
          duplicateBlankNodes
              .putIfAbsent(ibn, () => [reversedIdentifiedMap[ibn]!])
              .add(entry.key);
        }
        reversedIdentifiedMap[ibn] = entry.key;
      }
    }
    if (duplicateBlankNodes.isNotEmpty) {
      ValidationResult result = ValidationResult();
      for (final entry in duplicateBlankNodes.entries) {
        final context = entry.key
            .blankNodeChain()
            .expand<String>((bn) => [
                  if (bn.parentPredicate is IriTerm)
                    (bn.parentPredicate as IriTerm).value,
                  if (bn.parent.isIri) bn.parent.iriTerm!.value,
                  if (bn._identifyingProperties.isNotEmpty)
                    "${bn._identifyingProperties.length} identifying properties"
                ])
            .toList()
            .reversed
            .toList();
        result.addError(
            """Found ${entry.value.length} blank nodes at the same path that would be treated as the same entity during synchronization.

This creates ambiguity - the system cannot determine which blank node should be used during merge operations.

Solutions:
1. If these blank nodes should remain distinct, use `mc:disableBlankNodePathIdentification` on the parent predicate. This disables path-based identification, but means the blank node values will be replaced atomically (not merged property-by-property).

2. If these blank nodes represent duplicate data, ensure each has unique identifying properties configured in the merge contract, or remove the duplicate blank nodes from your data.
""",
            context: context);
      }
      result.throwIfInvalid();
    }
    if (circularReferences.isNotEmpty) {
      _log.warning(
          "Detected ${circularReferences.length} circular references in identified blank nodes. These blank nodes will be removed from identification, so they will be handled as non-identified nodes.");
    }
    final realIdentifedBlankNodeEntries =
        identifiedBlankNodes.entries.map((entry) {
      Iterable<IdentifiedBlankNode> filtered = entry.value;
      if (circularReferences.isNotEmpty) {
        filtered = filtered.where((i) => !i
            .blankNodeChain()
            .map((ibn) => reversedIdentifiedMap[ibn]!)
            .any((bn) => circularReferences.contains(bn)));
        if (filtered.isEmpty) {
          _log.info(
              "Removing blank node ${entry.key} from identified blank nodes because it is part of a circular reference.");
          return null;
        }
      }
      final iris = filtered.map(converter).toSet().toList();
      return MapEntry(entry.key, iris);
    }).nonNulls;
    final realIdentifedBlankNodes = {
      for (final entry in realIdentifedBlankNodeEntries) entry.key: entry.value
    };
    return IdentifiedBlankNodes<T>(identifiedMap: realIdentifedBlankNodes);
  }
}

/// Sort blank nodes to process IRI-rooted nodes first, which helps with circular dependencies
List<BlankNodeTerm> _sortByDependencies(List<BlankNodeTerm> blankNodes,
    Map<BlankNodeTerm, List<Triple>> parentTriples) {
  final iriRooted = <BlankNodeTerm>[];
  final blankRooted = <BlankNodeTerm>[];

  for (final node in blankNodes) {
    final nodeParents = parentTriples[node] ?? [];
    final hasIriParent = nodeParents.any((t) => t.subject is IriTerm);
    if (hasIriParent) {
      iriRooted.add(node);
    } else {
      blankRooted.add(node);
    }
  }

  return [...iriRooted, ...blankRooted];
}

// Note: a Blank node can have multiple parents, and thus multiple IdentifiedBlankNode instances
List<IdentifiedBlankNode> _addIdentifiedBlankNodes(
    RdfGraph graph,
    BlankNodeTerm blankNode,
    Map<BlankNodeTerm, Set<RdfPredicate>> identifyingPredicates,
    Map<BlankNodeTerm, List<Triple>> parentTriples,
    Map<BlankNodeTerm, List<IdentifiedBlankNode>> identifiedBlankNodes,
    MergeContract mergeContract,
    {Set<BlankNodeTerm>? circuit}) {
  if (identifiedBlankNodes.containsKey(blankNode)) {
    return identifiedBlankNodes[blankNode]!;
  }
  final circuitCheck = circuit ?? <BlankNodeTerm>{};
  circuitCheck.add(blankNode);
  final identifyingPreds = identifyingPredicates[blankNode];

  final parentTriplesForNode = parentTriples[blankNode];
  if (parentTriplesForNode == null || parentTriplesForNode.isEmpty) {
    _log.warning(
        "Found blank node ${blankNode} that cannot be identified because it has no parent.\n${'-' * 40}\n${turtle.encode(graph.subgraph(blankNode))}\n${'-' * 40}\n${turtle.encode(graph)}\n");
    return const [];
  }

  // Check if this blank node can be identified
  final hasPropertyIdentification =
      identifyingPreds != null && identifyingPreds.isNotEmpty;

  // Path identification is the default for single-value algorithms
  // Check which parent triples support path identification
  final pathIdentifyingTriples = parentTriplesForNode.where((triple) {
    final resourceType =
        graph.findSingleObject<IriTerm>(triple.subject, Rdf.type);
    final rule =
        mergeContract.getEffectivePredicateRule(resourceType, triple.predicate);

    // Path identification enabled?
    return rule?.isPathIdentifying == true;
  }).toList();

  final hasPathIdentification = pathIdentifyingTriples.isNotEmpty;

  if (!hasPropertyIdentification && !hasPathIdentification) {
    // Cannot identify this blank node - no identification mechanism available
    return const [];
  }

  // Build identifying properties map (empty if only path-identified)
  final identifyingProps = hasPropertyIdentification
      ? {
          for (final pred in identifyingPreds)
            pred: graph.getMultiValueObjectList(blankNode, pred)
        }
      : <RdfPredicate, List<RdfObject>>{};

  // Verify the objects of the identifying properties - we currently do not
  // support identifying properties that are blank nodes themselves
  for (final entry in identifyingProps.entries) {
    final hasBlankNodeObject = entry.value.any((o) => o is BlankNodeTerm);
    if (hasBlankNodeObject) {
      throw Exception(
          "Found identifiable Blank node ${blankNode} that cannot be identified because one of its identifying properties (${entry.key}) has a blank node as object.");
    }
  }

  // Generate IdentifiedBlankNode instances for each parent
  final ips = parentTriplesForNode.expand<IdentifiedBlankNode>((triple) {
    final parentSubject = triple.subject;
    final parentPredicate = triple.predicate;

    // Determine if this specific parent path is path-identifying
    final isPathIdentifying = pathIdentifyingTriples.contains(triple);
    final effectiveParentPredicate = isPathIdentifying ? parentPredicate : null;

    switch (parentSubject) {
      case IriTerm iriTerm:
        return [
          IdentifiedBlankNode(IdentifiedBlankNodeParent.forIri(iriTerm),
              identifyingProps, effectiveParentPredicate)
        ];
      case BlankNodeTerm blankNodeParent:
        if (circuitCheck.contains(blankNodeParent)) {
          _log.warning(
              "Detected circular reference while identifying Blank node ${blankNode}. Skipping further processing of this branch.");
          return [
            IdentifiedBlankNode(
                IdentifiedBlankNodeParent._circuitBreaker(circuitCheck),
                identifyingProps,
                effectiveParentPredicate)
          ];
        }

        final identifiedParents = _addIdentifiedBlankNodes(
            graph,
            blankNodeParent,
            identifyingPredicates,
            parentTriples,
            identifiedBlankNodes,
            mergeContract,
            circuit: circuitCheck);
        return identifiedParents
            .map((ip) => IdentifiedBlankNode(
                IdentifiedBlankNodeParent.forIdentifiedBlankNode(ip),
                identifyingProps,
                effectiveParentPredicate))
            .toList();
    }
  }).toList();
  identifiedBlankNodes[blankNode] = ips;
  return ips;
}

sealed class IdentifiedRdfSubject {
  RdfSubject get subject;

  /// Get the IRI to use for property change tracking.
  /// For IRI subjects, returns the IRI itself.
  /// For identified blank nodes, returns the first canonical IRI.
  List<IriTerm> get propertyChangeIris;
}

class IdentifiedIriSubject extends IdentifiedRdfSubject {
  final IriTerm iri;

  IdentifiedIriSubject(this.iri);

  @override
  RdfSubject get subject => iri;

  @override
  List<IriTerm> get propertyChangeIris => [iri];

  @override
  int get hashCode => iri.hashCode;

  @override
  bool operator ==(Object other) =>
      other is IdentifiedIriSubject && other.iri == iri;
}

class IdentifiedBlankNodeSubject extends IdentifiedRdfSubject {
  final BlankNodeTerm blankNode;
  final List<IriTerm> identifiers;

  IdentifiedBlankNodeSubject(this.blankNode, this.identifiers);

  @override
  RdfSubject get subject => blankNode;

  @override
  List<IriTerm> get propertyChangeIris => identifiers;

  // Two identified blank nodes are considered equal if they share at least one identifier,
  // so we cannot implement hashCode properly since we cannot know here which
  // of the identifiers will match. So the only way to get a consistent behaviour
  // is to return a constant hashCode and do a full comparison in operator==.
  @override
  int get hashCode => 0;

  @override
  bool operator ==(Object other) {
    if (other is! IdentifiedBlankNodeSubject) {
      return false;
    }
    // Actually, we consider two identified blank nodes equal if they share at least one identifier

    if (identifiers.any((id) => other.identifiers.contains(id))) {
      return true;
    }

    return false;
  }
}
