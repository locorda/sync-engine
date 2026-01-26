import 'package:locorda_core/src/crdt/crdt_types.dart';
import 'package:locorda_core/src/vocab/generated/_index.dart';
import 'package:locorda_core/src/hlc_service.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:logging/logging.dart';
import 'package:locorda_rdf_core/core.dart';

final _log = Logger('RemoteDocumentMerger');

/// Organized statement data structures for efficient lookup during merge.
///
/// Note that identified blank nodes are already resolved from canonical IRIs
/// in graph statements to actual blank nodes in the graph,
/// so that you can directly  use blank nodes from the graph when querying statements.
///
/// But the canonical IRIs are still stored in the MetadataStatementKey instances
/// so you can also query statements by their canonical IRIs.
class OrganizedStatements {
  final Map<MetadataStatementKey, MetadataStatement> _statementsByKey;
  final Iterable<RdfSubject> statementIdentifiers;

  MetadataStatement? getStatementForKey(MetadataStatementKey key) =>
      _statementsByKey[key];

  MetadataStatement? getStatementForTriple(Triple triple) =>
      _statementsByKey[MetadataStatementKey.fromTriple(triple)];

  MetadataStatement? getStatementForSubjectPredicate(
          RdfSubject subject, RdfPredicate predicate) =>
      _statementsByKey[
          MetadataStatementKey.fromSubjectPredicate(subject, predicate)];

  MetadataStatement? getStatementForSubject(RdfSubject subject) =>
      _statementsByKey[MetadataStatementKey.fromSubject(subject)];

  OrganizedStatements._(
      Iterable<MetadataStatement> statements, this.statementIdentifiers)
      : _statementsByKey = {
          for (final e in statements
              .expand((stmt) => stmt.allKeys.map((k) => MapEntry(k, stmt))))
            e.key: e.value
        };

  factory OrganizedStatements.fromGraph(
    IriTerm documentIri,
    RdfGraph document,
    OrganizedBlankNodeMappings blankNodeMappings,
  ) {
    final statementIdentifiers = document.getMultiValueObjects<RdfSubject>(
        documentIri, SyncManagedDocument.hasStatement);
    final statementGraphs = {
      for (final subject in statementIdentifiers)
        subject: document.matching(subject: subject)
    };
    final statementsByKey = <MetadataStatementKey, Set<Node>>{};
    final maybeCanonicalKeysByRealKey =
        <MetadataStatementKey, Set<MetadataStatementKey>>{};

    for (final entry in statementGraphs.entries) {
      final subject = entry.key;
      final graph = entry.value;
      final rdfSubject =
          graph.findSingleObject<RdfSubject>(subject, RdfStatement.subject);
      if (rdfSubject is BlankNodeTerm) {
        throw StateError(
            'Statement subject cannot be a blank node in document ${documentIri.debug}: ${rdfSubject.debug}');
      }
      if (rdfSubject == null) {
        _log.severe(
            'Could not find statement subject in document ${documentIri.debug} for statement identifier ${subject.debug}');
        continue;
      }
      final rdfPredicate =
          graph.findSingleObject<IriTerm>(subject, RdfStatement.predicate);
      final rdfObject =
          graph.findSingleObject<RdfObject>(subject, RdfStatement.object);
      if (rdfObject is BlankNodeTerm) {
        throw StateError(
            'Statement object cannot be a blank node in document ${documentIri.debug}: ${rdfObject.debug}');
      }
      final realSubject =
          blankNodeMappings.getBlankNode(rdfSubject) ?? rdfSubject;
      final realObject = rdfObject is IriTerm
          ? blankNodeMappings.getBlankNode(rdfObject) ?? rdfObject
          : rdfObject;
      final MetadataStatementKey realKey =
          MetadataStatementKey.from(realSubject, rdfPredicate, realObject);

      statementsByKey
          .putIfAbsent(realKey, () => <Node>{})
          .add((subject, graph));
      final canonicalKeys = maybeCanonicalKeysByRealKey.putIfAbsent(
          realKey, () => <MetadataStatementKey>{});
      canonicalKeys
          .add(MetadataStatementKey.from(rdfSubject, rdfPredicate, rdfObject));
      if (rdfSubject != realSubject) {
        canonicalKeys.add(
            MetadataStatementKey.from(realSubject, rdfPredicate, rdfObject));
      }
      if (rdfObject != realObject && rdfObject != null) {
        canonicalKeys.add(
            MetadataStatementKey.from(rdfSubject, rdfPredicate, realObject));
      }
    }

    final statements = statementsByKey.entries.map((entry) {
      final key = entry.key;
      final nodes = entry.value;
      final predicateObjectMap =
          nodes.fold(<RdfPredicate, Set<RdfObject>>{}, (map, node) {
        final (subject, graph) = node;
        for (final triple in graph.findTriples(subject: subject)) {
          final objects =
              map.putIfAbsent(triple.predicate, () => <RdfObject>{});
          final realTripleObject = triple.object is IriTerm
              ? blankNodeMappings.getBlankNode(triple.object as IriTerm) ??
                  triple.object
              : triple.object;
          objects.add(realTripleObject);
        }
        return map;
      });
      final allKeys = {key, ...?maybeCanonicalKeysByRealKey[key]};
      return MetadataStatement(key, predicateObjectMap, allKeys);
    });
    return OrganizedStatements._(statements, statementIdentifiers);
  }

  Iterable<MetadataStatement> getAllStatementsForSubject(RdfObjectKey key) {
    // TODO: Optimize by precomputing a map from subject keys to statements or similar
    final subjectEquivalents = <RdfSubject>{
      if (key.value is RdfSubject) key.value as RdfSubject,
      ...?key.canonicalIris
    };
    return _statementsByKey.entries
        .where((entry) => switch (entry.key) {
              TripleMetadataStatement(subject: var subj) =>
                subjectEquivalents.contains(subj),
              SubjectPredicateMetadataStatement(subject: var subj) =>
                subjectEquivalents.contains(subj),
              SubjectMetadataStatement(subject: var subj) =>
                subjectEquivalents.contains(subj),
            })
        .map((entry) => entry.value)
        .toSet();
  }

  MetadataStatement? getStatement(
      RdfObjectKey subject, RdfPredicate? predicate, RdfObjectKey? object) {
    final key = MetadataStatementKey.from(
        subject.value as RdfSubject, predicate, object?.value);
    final statement = _statementsByKey[key];
    if (statement != null) {
      return statement;
    }
    return subject.valueOrCanonicalIrisAs<RdfSubject>().expand((subj) {
      if (object == null) {
        final altKey = MetadataStatementKey.from(subj, predicate);
        return [_statementsByKey[altKey]];
      }
      return object.valueOrCanonicalIrisAs<RdfObject>().map((obj) {
        final altKey = MetadataStatementKey.from(subj, predicate, obj);
        return _statementsByKey[altKey];
      });
    }).firstWhere((stmt) => stmt != null, orElse: () => null);
  }
}

enum MergeSubjectType {
  statement,
  blankNodeIdentifier,
  identifiedBlankNode,
  unidentifiedBlankNode,
  iri,
}

class MergeObject {
  final RdfObject? local;
  final RdfObjectKey? localKey;
  final RdfObject? remote;
  final RdfObjectKey? remoteKey;

  late final RdfObject object;

  MergeObject._({
    required this.local,
    required this.localKey,
    required this.remote,
    required this.remoteKey,
  }) {
    if (local != null && localKey == null) {
      throw ArgumentError(
          'localKey is null but local is not null for MergeObject');
    }
    if (remote != null && remoteKey == null) {
      throw ArgumentError(
          'remoteKey is null but remote is not null for MergeObject');
    }
    if (local == null && remote == null) {
      throw ArgumentError('Both local and remote are null for MergeObject with '
          'localKey: $localKey, remoteKey: $remoteKey');
    }
    object = local ?? remote!;
  }

  static Iterable<MergeObject> createMergeObjects(
    OrganizedGraph local,
    Iterable<RdfObject> localObjects,
    OrganizedGraph remote,
    Iterable<RdfObject> remoteObjects,
  ) {
    var localKeys = localObjects
        .map((obj) => RdfObjectKey.fromObject(obj, local.blankNodeMappings))
        .toSet();
    var remoteKeys = remoteObjects
        .map((obj) => RdfObjectKey.fromObject(obj, remote.blankNodeMappings))
        .toSet();
    final allKeys = {...localKeys, ...remoteKeys};

    return allKeys.map((key) {
      var localKey = localKeys.lookup(key);
      var remoteKey = remoteKeys.lookup(key);
      return MergeObject._(
        local: localKey?.value,
        localKey: localKey,
        remote: remoteKey?.value,
        remoteKey: remoteKey,
      );
    });
  }
}

class MergeSubject {
  final RdfSubject? local;
  final RdfObjectKey? localKey;
  final RdfSubject? remote;
  final RdfObjectKey? remoteKey;
  final MergeSubjectType type;
  late final RdfSubject subject;

  MergeSubject._({
    required this.local,
    required this.localKey,
    required this.remote,
    required this.remoteKey,
    required this.type,
  }) {
    if (local != null && localKey == null) {
      throw ArgumentError(
          'localKey is null but localSubject is not null for MergeSubject');
    }
    if (remote != null && remoteKey == null) {
      throw ArgumentError(
          'remoteKey is null but remoteSubject is not null for MergeSubject');
    }
    if (local == null && remote == null) {
      throw ArgumentError(
          'Both localSubject and remoteSubject are null for MergeSubject');
    }
    subject = local ?? remote!;
  }

  static MergeSubjectType _determineType(RdfObjectKey key,
      Set<RdfSubject> statementIdentifiers, Set<IriTerm> blankNodeIdentifiers) {
    if (statementIdentifiers.contains(key.value)) {
      return MergeSubjectType.statement;
    }
    if (blankNodeIdentifiers.contains(key.value)) {
      return MergeSubjectType.blankNodeIdentifier;
    }
    return switch (key) {
      IriSubjectKey() => MergeSubjectType.iri,
      IdentifiedBlankNodeKey() => MergeSubjectType.identifiedBlankNode,
      UnIdentifiedBlankNodeKey() => MergeSubjectType.unidentifiedBlankNode,
      LiteralKey() => throw ArgumentError(
          'Literal cannot be a subject for MergeSubject: ${key.value}'),
    };
  }

  static Iterable<MergeSubject> createMergeSubjects(
      OrganizedGraph local, OrganizedGraph remote) {
    var localSubjectKeys = local.allSubjectKeys.toSet();
    var remoteSubjectKeys = remote.allSubjectKeys.toSet();
    final allKeys = {...localSubjectKeys, ...remoteSubjectKeys};
    final allStatementIdentifiers = {
      ...local.statements.statementIdentifiers,
      ...remote.statements.statementIdentifiers
    };
    final allBlankNodeIdentifiers = {
      ...local.blankNodeMappings.blankNodeIdentifiers,
      ...remote.blankNodeMappings.blankNodeIdentifiers
    };
    return allKeys.map((key) {
      var localKey = localSubjectKeys.lookup(key);
      var remoteKey = remoteSubjectKeys.lookup(key);
      return MergeSubject._(
        local: localKey?.value as RdfSubject?,
        localKey: localKey,
        remote: remoteKey?.value as RdfSubject?,
        remoteKey: remoteKey,
        type: _determineType(
            key, allStatementIdentifiers, allBlankNodeIdentifiers),
      );
    });
  }
}

class OrganizedBlankNodeMappings {
  /// Maps blank node identifier to its mapping subject
  final Map<BlankNodeTerm, Iterable<IriTerm>> _identifiedBlankNodes;

  late final Set<IriTerm> blankNodeIdentifiers =
      _identifiedBlankNodes.values.expand((v) => v).toSet();
  late final Map<IriTerm, BlankNodeTerm> _canonicalToBlankNodeMap = {
    for (final entry in _identifiedBlankNodes.entries) ...{
      for (final iri in entry.value) iri: entry.key
    }
  };
  Iterable<BlankNodeTerm> get identifiedBlankNodes =>
      _identifiedBlankNodes.keys;

  OrganizedBlankNodeMappings._(this._identifiedBlankNodes);

  Iterable<IriTerm>? getCanonicalIrisForBlankNode(BlankNodeTerm blankNode) {
    return _identifiedBlankNodes[blankNode];
  }

  factory OrganizedBlankNodeMappings.fromGraph(
    IriTerm documentIri,
    RdfGraph document,
  ) {
    final blankNodeIdentifiers = document.getMultiValueObjects<RdfSubject>(
      documentIri,
      SyncManagedDocument.hasBlankNodeMapping,
    );
    final identifiedBlankNodes =
        _buildBlankNodeToCanonicalMap(document, blankNodeIdentifiers);

    return OrganizedBlankNodeMappings._(
      identifiedBlankNodes,
    );
  }

  static Map<BlankNodeTerm, Set<IriTerm>> _buildBlankNodeToCanonicalMap(
      RdfGraph localGraph, Set<RdfSubject> localSubjects) {
    return localGraph
        .findTriples(
            subjectIn: localSubjects, predicate: SyncBlankNodeMapping.blankNode)
        .fold(<BlankNodeTerm, Set<IriTerm>>{}, (map, triple) {
      if (triple.predicate == SyncBlankNodeMapping.blankNode &&
          triple.object is BlankNodeTerm &&
          triple.subject is IriTerm) {
        final subject = triple.subject as IriTerm;
        final object = triple.object as BlankNodeTerm;
        map.putIfAbsent(object, () => <IriTerm>{}).add(subject);
      } else {
        _log.warning('Unexpected triple in blank node mapping: $triple');
      }
      return map;
    });
  }

  BlankNodeTerm? byIdentifiers(List<IriTerm> identifiers) => identifiers
      .map((id) => _canonicalToBlankNodeMap[id])
      .firstWhere((bnode) => bnode != null, orElse: () => null);

  BlankNodeTerm? getBlankNode(RdfSubject rdfSubject) {
    return _canonicalToBlankNodeMap[rdfSubject];
  }

  bool isIdentified(BlankNodeTerm object) {
    return _identifiedBlankNodes.containsKey(object);
  }
}

sealed class RdfObjectKey {
  RdfObject get value;
  Iterable<IriTerm>? get canonicalIris => null;
  Iterable<T> valueOrCanonicalIrisAs<T extends RdfObject>() sync* {
    if (value is T) {
      yield value as T;
    }
    if (canonicalIris != null) {
      for (final iri in canonicalIris!) {
        if (iri is T) {
          yield iri as T;
        }
      }
    }
  }

  static RdfObjectKey fromObject(
      RdfObject object, OrganizedBlankNodeMappings mappings) {
    switch (object) {
      case IriTerm iri:
        return IriSubjectKey(iri);
      case BlankNodeTerm bnode:
        final identifiers = mappings.getCanonicalIrisForBlankNode(bnode);
        if (identifiers == null || identifiers.isEmpty) {
          return UnIdentifiedBlankNodeKey(bnode);
        }
        return IdentifiedBlankNodeKey(bnode, identifiers.toList());
      case LiteralTerm literal:
        return LiteralKey(literal);
    }
  }
}

class LiteralKey extends RdfObjectKey {
  final LiteralTerm literal;

  LiteralKey(this.literal);

  @override
  RdfObject get value => literal;

  @override
  int get hashCode => literal.hashCode;

  @override
  bool operator ==(Object other) =>
      other is LiteralKey && other.literal == literal;
}

class IriSubjectKey extends RdfObjectKey {
  final IriTerm iri;

  IriSubjectKey(this.iri);

  @override
  RdfObject get value => iri;

  @override
  int get hashCode => iri.hashCode;

  @override
  bool operator ==(Object other) => other is IriSubjectKey && other.iri == iri;
}

class IdentifiedBlankNodeKey extends RdfObjectKey {
  final BlankNodeTerm blankNode;
  final List<IriTerm> identifiers;

  IdentifiedBlankNodeKey(this.blankNode, this.identifiers);

  @override
  RdfObject get value => blankNode;

  @override
  Iterable<IriTerm>? get canonicalIris => identifiers;

  // Two identified blank nodes are considered equal if they share at least one identifier,
  // so we cannot implement hashCode properly since we cannot know here which
  // of the identifiers will match. So the only way to get a consistent behaviour
  // is to return a constant hashCode and do a full comparison in operator==.
  @override
  int get hashCode => 0;

  @override
  bool operator ==(Object other) {
    if (other is! IdentifiedBlankNodeKey) {
      return false;
    }
    // Two identified blank nodes are considered equal if they share at least one identifier

    if (identifiers.any((id) => other.identifiers.contains(id))) {
      return true;
    }

    return false;
  }
}

class UnIdentifiedBlankNodeKey extends RdfObjectKey {
  final BlankNodeTerm blankNode;

  UnIdentifiedBlankNodeKey(this.blankNode);

  @override
  RdfObject get value => blankNode;

  @override
  int get hashCode => blankNode.hashCode;

  @override
  bool operator ==(Object other) {
    if (other is! UnIdentifiedBlankNodeKey) {
      return false;
    }

    return blankNode == other.blankNode;
  }
}

final class OrganizedGraph {
  final OrganizedStatements statements;
  final OrganizedBlankNodeMappings blankNodeMappings;
  final RdfGraph fullGraph;
  final CurrentCrdtClock clock;
  final Set<RdfSubject> _allSubjects;
  final Map<IriTerm, (int logical, int physical)> clockTimes;

  late final int maxPhysicalTime = clockTimes.values
      .map((times) => times.$2)
      .fold<int>(0, (prev, element) => element > prev ? element : prev);
  late final int minPhysicalTime = clockTimes.values
      .map((times) => times.$2)
      .fold<int>(0, (prev, element) => element < prev ? element : prev);

  OrganizedGraph._({
    required this.statements,
    required this.blankNodeMappings,
    required this.fullGraph,
    required this.clock,
    required this.clockTimes,
  }) : _allSubjects =
            // Relying on RdfGraph being immutable, so we do not need to copy the subjects set
            fullGraph.subjects;

  MetadataStatement? getStatement(RdfSubject subject,
          [RdfPredicate? predicate, RdfObject? object]) =>
      statements.getStatementForKey(
          MetadataStatementKey.from(subject, predicate, object));

  bool isTombstoned(RdfSubject subject,
          [RdfPredicate? predicate, RdfObject? object]) =>
      getStatement(subject, predicate, object)?.isTombstoned() ?? false;

  /// Get statement by RdfObjectKey subject, RdfPredicate and RdfObjectKey object
  ///
  /// Returns null if no such statement exists or if subject is null.
  MetadataStatement? getStatementForKey(RdfObjectKey? subject,
          [RdfPredicate? predicate, RdfObjectKey? object]) =>
      subject == null
          ? null
          : statements.getStatement(subject, predicate, object);

  Iterable<MetadataStatement> getAllStatementsForSubject(RdfObjectKey key) =>
      statements.getAllStatementsForSubject(key);

  bool isTombstonedObjectKey(RdfObjectKey subject, RdfPredicate? predicate,
          RdfObjectKey? object) =>
      getStatementForKey(subject, predicate, object)?.isTombstoned() ?? false;

  Iterable<RdfObjectKey> get allSubjectKeys => _allSubjects
      .map((subject) => RdfObjectKey.fromObject(subject, blankNodeMappings));

  /// While an RdfSubject might be specific to a given graph (due to blank nodes),
  /// a RdfSubjectKey can be used to identify the same subject across different graphs
  /// if it is an identifiable blank node or an IRI.
  ///
  /// Use this method to resolve a RdfSubjectKey back to the actual RdfSubject in this graph.
  ///
  /// Return null if the subject cannot be found in this graph.
  RdfObject? getObjectForKey(RdfObjectKey key) => switch (key) {
        IdentifiedBlankNodeKey() =>
          blankNodeMappings.byIdentifiers(key.identifiers),
        _ => key.value
      };

  factory OrganizedGraph.fromGraph(
      IriTerm documentIri, RdfGraph document, HlcService hlcService) {
    final clock = hlcService.getCurrentClock(document, documentIri);
    final blankNodeMappings =
        OrganizedBlankNodeMappings.fromGraph(documentIri, document);
    final statements =
        OrganizedStatements.fromGraph(documentIri, document, blankNodeMappings);
    final clockTimes = <IriTerm, (int logical, int physical)>{};

    for (final (subject, graph) in clock.fullClock) {
      final logical = graph
              .findSingleObject<LiteralTerm>(
                  subject, CrdtClockEntry.logicalTime)
              ?.integerValue ??
          0;
      final physical = graph
              .findSingleObject<LiteralTerm>(
                  subject, CrdtClockEntry.physicalTime)
              ?.integerValue ??
          0;
      clockTimes[subject as IriTerm] = (logical, physical);
    }

    return OrganizedGraph._(
      statements: statements,
      blankNodeMappings: blankNodeMappings,
      fullGraph: document,
      clock: clock,
      clockTimes: Map.unmodifiable(clockTimes),
    );
  }
}

/// Result of comparing two Hybrid Logical Clocks for causality determination.
enum ClockComparison {
  /// Local clock dominates (local is causally after remote)
  localDominates,

  /// Remote clock dominates (remote is causally after local)
  remoteDominates,

  /// Clocks are concurrent (no causal relationship)
  concurrent,

  /// Clocks are identical (no merge needed)
  identical,

  /// Both clocks are empty/missing
  bothEmpty;

  /// Compares two Hybrid Logical Clocks to determine causality relationship.
  ///
  /// Per CRDT spec section 2.2: Causality Determination
  /// - Clock A dominates B if A.logical[i] ≥ B.logical[i] for all i, and A.logical[j] > B.logical[j] for at least one j
  /// - If neither dominates based on logical time, they are concurrent
  /// - Empty/missing clocks are treated as all zeros

  static ClockComparison compareClocks(
    OrganizedGraph local,
    OrganizedGraph remote,
  ) {
    // Handle empty clocks (treated as all zeros per spec)
    final localIsEmpty = local.clockTimes.isEmpty;
    final remoteIsEmpty = remote.clockTimes.isEmpty;

    if (localIsEmpty && remoteIsEmpty) {
      return ClockComparison.bothEmpty;
    }

    if (localIsEmpty) {
      return ClockComparison.remoteDominates;
    }

    if (remoteIsEmpty) {
      return ClockComparison.localDominates;
    }

    // Build maps of installation -> (logical, physical) for comparison
    final localEntries = local.clockTimes;
    final remoteEntries = remote.clockTimes;

    // Get all installation IDs from both clocks
    final allInstallations = {...localEntries.keys, ...remoteEntries.keys};

    var localGreater = false;
    var remoteGreater = false;

    for (final installation in allInstallations) {
      final localLogical = localEntries[installation]?.$1 ?? 0;
      final remoteLogical = remoteEntries[installation]?.$1 ?? 0;

      if (localLogical > remoteLogical) {
        localGreater = true;
      } else if (remoteLogical > localLogical) {
        remoteGreater = true;
      }

      // If both have been greater at some point, they're concurrent
      if (localGreater && remoteGreater) {
        return ClockComparison.concurrent;
      }
    }

    if (localGreater) {
      return ClockComparison.localDominates;
    } else if (remoteGreater) {
      return ClockComparison.remoteDominates;
    } else {
      // All logical times are equal - clocks are identical
      return ClockComparison.identical;
    }
  }
}
