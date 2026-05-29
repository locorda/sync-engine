import 'package:collection/collection.dart';
import 'package:locorda_core/src/vocab/generated/_index.dart';
import 'package:locorda_core/src/mapping/framework_iri_generator.dart';
import 'package:locorda_core/src/mapping/identified_blank_node_builder.dart';
import 'package:locorda_core/src/mapping/metadata_generator.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/sync/data_types.dart';
import 'package:logging/logging.dart';
import 'package:locorda_rdf_core/core.dart';

final _log = Logger('CrdtTypes');

/// CRDT type definitions from the architecture specification.
///
/// Defines the state-based CRDT algorithms used for property-level
/// merge strategies as outlined in the crdt-algorithms vocabulary.

typedef PropertyValueContext = ({
  IriTerm documentIri,
  RdfGraph appData,
  IdentifiedBlankNodes<IriTerm> blankNodes,
  RdfSubject subject,
  RdfPredicate predicate,
  Iterable<RdfObject> values,
});

/// Metadata changes resulting from a CRDT value change operation.
///
/// Contains both statements to add to the framework graph and statements
/// to remove (e.g., outdated tombstones that should be cleaned up).
typedef Metadata = ({
  Iterable<Node> statementsToAdd,
  Iterable<Triple> triplesToRemove,
});

const Metadata noMetadata = (statementsToAdd: [], triplesToRemove: []);
final _coreStatementPredicates = {
  RdfStatement.type,
  RdfStatement.subject,
  RdfStatement.predicate,
  RdfStatement.object,
};

/// Base interface for all CRDT types.
abstract interface class CrdtType {
  const CrdtType();

  bool get isSingleValueSupported;

  IriTerm get iri;

  /// Creates the metadata triples for a local property value change.
  /// The returned [Metadata] contains statements to add and statements to remove.
  ///
  /// [oldFrameworkGraph] provides access to existing framework metadata
  /// (e.g., tombstones) that may need to be cleaned up during this operation.
  Metadata localValueChange({
    required PropertyValueContext? oldPropertyValue,
    required PropertyValueContext newPropertyValue,
    required RdfGraph? oldFrameworkGraph,
    required CrdtMergeContext mergeContext,
    required int physicalClock,
  });

  MergeResults? remoteMerge({
    required MergeSubject subject,
    required RdfPredicate predicate,
    required OrganizedGraph local,
    required OrganizedGraph remote,
    required RemoteCrdtMergeContext mergeContext,
  });
}

extension MetadataStatementConvencienceExtension on MetadataStatement? {
  bool isTombstoned() {
    return this?.isTombstoned() ?? false;
  }
}

class MetadataStatement {
  final MetadataStatementKey key;
  final Set<MetadataStatementKey> allKeys;
  final Map<RdfPredicate, Iterable<RdfObject>> predicateObjectMap;

  const MetadataStatement(this.key, this.predicateObjectMap, this.allKeys);

  bool isTombstoned() {
    return predicateObjectMap.containsKey(RdfStatement.crdtDeletedAt);
  }

  MetadataStatement merge(MetadataStatement other) {
    assert(key == other.key);
    final mergedMap = <RdfPredicate, Set<RdfObject>>{};
    for (final entry in predicateObjectMap.entries) {
      mergedMap.putIfAbsent(entry.key, () => {}).addAll(entry.value);
    }
    for (final entry in other.predicateObjectMap.entries) {
      mergedMap.putIfAbsent(entry.key, () => {}).addAll(entry.value);
    }
    return MetadataStatement(
      key,
      mergedMap.map(
        (key, value) => MapEntry(key, value.toList()),
      ),
      {...allKeys, ...other.allKeys},
    );
  }
}

sealed class MetadataStatementKey {
  const MetadataStatementKey();

  factory MetadataStatementKey.fromTriple(Triple triple) {
    return TripleMetadataStatement(
        triple.subject, triple.predicate, triple.object);
  }

  factory MetadataStatementKey.fromSubjectPredicateObject(
      RdfSubject subject, RdfPredicate predicate, RdfObject object) {
    return TripleMetadataStatement(subject, predicate, object);
  }

  factory MetadataStatementKey.from(RdfSubject subject,
      [RdfPredicate? predicate, RdfObject? object]) {
    if (predicate != null && object != null) {
      return TripleMetadataStatement(subject, predicate, object);
    } else if (predicate != null) {
      return SubjectPredicateMetadataStatement(subject, predicate);
    } else {
      return SubjectMetadataStatement(subject);
    }
  }

  factory MetadataStatementKey.fromSubjectPredicate(
      RdfSubject subject, RdfPredicate predicate) {
    return SubjectPredicateMetadataStatement(subject, predicate);
  }

  factory MetadataStatementKey.fromSubject(RdfSubject subject) {
    return SubjectMetadataStatement(subject);
  }
}

class SubjectMetadataStatement extends MetadataStatementKey {
  final RdfSubject subject;

  const SubjectMetadataStatement(this.subject);

  @override
  bool operator ==(Object other) {
    if (other is! SubjectMetadataStatement) {
      return false;
    }
    return subject == other.subject;
  }

  @override
  int get hashCode => subject.hashCode;

  @override
  String toString() {
    return 'SubjectMetadataStatement(subject: ${subject.debug})';
  }
}

class SubjectPredicateMetadataStatement extends MetadataStatementKey {
  final RdfSubject subject;
  final RdfPredicate predicate;

  const SubjectPredicateMetadataStatement(this.subject, this.predicate);

  @override
  bool operator ==(Object other) {
    if (other is! SubjectPredicateMetadataStatement) {
      return false;
    }
    return subject == other.subject && predicate == other.predicate;
  }

  @override
  int get hashCode => subject.hashCode ^ predicate.hashCode;

  @override
  String toString() {
    return 'SubjectPredicateMetadataStatement(subject: ${subject.debug}, predicate: ${predicate.debug})';
  }
}

class TripleMetadataStatement extends MetadataStatementKey {
  final RdfSubject subject;
  final RdfPredicate predicate;
  final RdfObject object;

  const TripleMetadataStatement(this.subject, this.predicate, this.object);

  @override
  bool operator ==(Object other) {
    if (other is! TripleMetadataStatement) {
      return false;
    }
    return subject == other.subject &&
        predicate == other.predicate &&
        object == other.object;
  }

  @override
  int get hashCode => subject.hashCode ^ predicate.hashCode ^ object.hashCode;

  @override
  String toString() {
    return 'TripleMetadataStatement(subject: ${subject.debug}, predicate: ${predicate.debug}, object: ${object.debug})';
  }
}

/// Results from merging all subjects and their properties.
class MergeResults {
  /// All merged triples from all subjects
  final Set<Triple> mergedTriples;

  /// All merged statements (tombstones, etc.)
  final Map<MetadataStatementKey, MetadataStatement> mergedStatements;

  const MergeResults({
    required this.mergedTriples,
    required this.mergedStatements,
  });

  const MergeResults.empty()
      : this(mergedTriples: const {}, mergedStatements: const {});

  static MergeResults join(Iterable<MergeResults> results) =>
      results.fold(MergeResults(mergedTriples: {}, mergedStatements: {}),
          (acc, curr) {
        acc.mergedTriples.addAll(curr.mergedTriples);
        for (final entry in curr.mergedStatements.entries) {
          acc.mergedStatements.update(
            entry.key,
            (existing) => existing.merge(entry.value),
            ifAbsent: () => entry.value,
          );
        }
        return acc;
      });

  static MergeResults subjectFromGraph(OrganizedGraph graph, RdfObjectKey key) {
    final subject = key.value as RdfSubject;
    final triples = subjectAndInlineTriples(graph, subject);
    final statements = graph.getAllStatementsForSubject(key);

    return MergeResults(
        mergedTriples: triples.toSet(),
        mergedStatements: {for (final s in statements) s.key: s});
  }
}

Iterable<Triple> subjectAndInlineTriples(
        OrganizedGraph graph, RdfSubject subject) =>
    graph.fullGraph
        .subgraph(
          subject,
          filter: (triple, depth) => switch (triple.object) {
            IriTerm() ||
            LiteralTerm() =>
              TraversalDecision.includeButDontDescend,
            BlankNodeTerm()
                when graph.blankNodeMappings
                    .isIdentified(triple.object as BlankNodeTerm) =>
              TraversalDecision.includeButDontDescend,
            // Descend into unidentified blank nodes
            BlankNodeTerm() => TraversalDecision.include,
          },
        )
        .triples;

enum _RdfObjectComparison {
  num,
  dateTime,
  //duration,
  string;

  RdfObject _max(Iterable<RdfObject> objects) => switch (this) {
        _RdfObjectComparison.num => objects
            .map((obj) => (obj, obj.numericValue))
            .reduce((a, b) => a.$2 > b.$2 ? a : b)
            .$1,
        _RdfObjectComparison.dateTime => objects
            .map((obj) => (obj, obj.dateTimeValue))
            .reduce((a, b) => a.$2.isAfter(b.$2) ? a : b)
            .$1,
        _RdfObjectComparison.string => objects
            .map((obj) => (obj, obj.stringValue))
            .reduce((a, b) => a.$2.compareTo(b.$2) > 0 ? a : b)
            .$1
      };

  static _RdfObjectComparison forRdfObject(RdfObject obj) {
    if (obj.isNumeric) {
      return _RdfObjectComparison.num;
    } else if (obj.isDateTime) {
      return _RdfObjectComparison.dateTime;
    } else if (obj.hasStringValue) {
      return _RdfObjectComparison.string;
    } else {
      throw StateError('Unsupported value type for comparison in CRDT: $obj');
    }
  }

  static RdfObject max(Iterable<RdfObject> values) {
    if (values.isEmpty) {
      throw StateError('Cannot determine maximum of empty value set');
    }
    final compareGroups = values.map(_RdfObjectComparison.forRdfObject).toSet();
    final compareGroup = compareGroups.length == 1
        ? compareGroups.first
        : _RdfObjectComparison.string;
    return compareGroup._max(values);
  }
}

class GRegister implements CrdtType {
  const GRegister();
  @override
  IriTerm get iri => AlgoG_Register.classIri;
  bool get isSingleValueSupported => true;

  @override
  Metadata localValueChange(
      {required PropertyValueContext? oldPropertyValue,
      required PropertyValueContext newPropertyValue,
      required RdfGraph? oldFrameworkGraph,
      required CrdtMergeContext mergeContext,
      required int physicalClock}) {
    final allValues = {
      ...newPropertyValue.values,
      if (oldPropertyValue != null) ...oldPropertyValue.values,
    };
    if (allValues.isEmpty) {
      return noMetadata;
    }
    final result = _RdfObjectComparison.max(allValues);
    if (!newPropertyValue.values.contains(result)) {
      throw new StateError(
          'G-Register local value change must only add new maximum value. '
          'Old values: ${oldPropertyValue?.values}, New values: ${newPropertyValue.values}, Merged max: $result');
    }
    // No metadata changes needed
    return noMetadata;
  }

  @override
  MergeResults? remoteMerge({
    required MergeSubject subject,
    required RdfPredicate predicate,
    required OrganizedGraph local,
    required OrganizedGraph remote,
    required RemoteCrdtMergeContext mergeContext,
  }) {
    // Get values for this property from both graphs
    final allValues = {
      ...objectsIfSubjectNonNull(
        local.fullGraph,
        subject.local,
        predicate,
      ),
      ...objectsIfSubjectNonNull(
        remote.fullGraph,
        subject.remote,
        predicate,
      )
    };
    if (allValues.isEmpty) {
      return null;
    }

    // Take maximum value
    final maxValue = _RdfObjectComparison.max(allValues);

    // Return merged triple
    return MergeResults(
      mergedTriples: {Triple(subject.subject, predicate, maxValue)},
      mergedStatements: {},
    );
  }
}

/// Last-Writer-Wins Register for single-value properties.
/// Uses Hybrid Logical Clock for conflict resolution.
class LwwRegister implements CrdtType {
  const LwwRegister();

  @override
  IriTerm get iri => AlgoLWW_Register.classIri;

  bool get isSingleValueSupported => true;

  @override
  Metadata localValueChange({
    required PropertyValueContext? oldPropertyValue,
    required PropertyValueContext newPropertyValue,
    required RdfGraph? oldFrameworkGraph,
    required CrdtMergeContext mergeContext,
    required int physicalClock,
  }) {
    // LWW-Register property-level causality (issue #50):
    //
    // Without per-property causality tracking, two installations concurrently
    // editing DIFFERENT properties of the same document would resolve at
    // document granularity and uncontested writes would be silently dropped
    // by the physical-time tie-break. To make per-(s,p) merge decisions
    // possible, we stamp every locally-changed LWW property with an
    // immutable, content-addressed `crdt:VersionedClock` snapshot via a
    // `sync:PropertyStatement` keyed by (subject, predicate).
    //
    // PropertyStatement IRI is content-addressed over (s, p) so re-saves of
    // the same property produce the same IRI; only the attached `crdt:vclk`
    // changes \u2014 which is itself merged via LWW with document-clock fallback,
    // resolving recursive bootstrap deterministically.
    //
    // Old vclk subgraphs (referenced only by this PropertyStatement) are
    // collected into triplesToRemove so the document does not accumulate
    // stale snapshots on every save.
    //
    // Stamping is OPT-IN per call site: the caller selects via
    // `mergeContext.vclkIri` whether the current pass should record
    // per-property causality. `CrdtDocumentManager` enables it only for the
    // app-data pass — the framework-data pass passes `null` so framework
    // infrastructure subjects (PropertyStatement / VersionedClock nodes,
    // document-level CRDT plumbing, shard-entry headers) do not get
    // recursively stamped. See the rationale comment at the second
    // `_localDocumentMerger.generateMetadata` call in
    // `crdt_document_manager._computeSaveCore`. For those subjects the
    // `remoteMerge` path falls back to document-clock comparison, which is
    // the semantically correct resolution.
    final vclkIri = mergeContext.vclkIri;
    if (vclkIri == null) {
      // No clock context (raw template processing) OR caller deliberately
      // opted out of per-property stamping for this pass (framework-data
      // pass; see policy comment above).
      return noMetadata;
    }
    final documentIri = newPropertyValue.documentIri;
    final subject =
        IdTerm.create(newPropertyValue.subject, newPropertyValue.blankNodes);
    final predicate = newPropertyValue.predicate;

    // Proposal 028 PS-suppression: when this property's effective vclk equals
    // the document-wide implicit default (crdt:appBaseClock or, when absent,
    // the docClock), emitting an explicit sync:PropertyStatement would be
    // pure overhead — the remote-merge resolveVclk chain falls back to the
    // same vclk via the document-level appBaseClock triple. We still need to
    // GC any stale PS from a previous save that DID materialise one, so the
    // garbage-collection branch below runs regardless.
    final suppressStatement = mergeContext.implicitDefaultVclkIri == vclkIri;

    final statements = suppressStatement
        ? const <Node>[]
        : mergeContext.metadataGenerator.createPropertyStatement(
            documentIri,
            subject,
            predicate,
            (stmt) => [
              Triple(stmt, Crdt.vclk, vclkIri),
            ],
          );

    // Garbage-collect stale vclk references on the (s, p) PropertyStatement
    // and any vclk subgraphs that become unreachable as a result.
    //
    // PropertyStatement IRIs are content-addressed over (s, p), so a re-save
    // of the same property yields an identical IRI. `_constructCrdtDocument`
    // copies the old PropertyStatement subgraph via the sync:hasStatement
    // traversal AND re-adds the freshly emitted node — without removing the
    // old structural triples (rdf:type, sync:resource, sync:property) and the
    // hasStatement edge, the resulting List<Triple> document buffer would
    // accumulate duplicates that trip cardinality validation in
    // findSingleObject during subsequent merges.
    final triplesToRemove = <Triple>{};
    if (oldFrameworkGraph != null) {
      final newStmtIris = subject.localSubjectIris
          .map((s) => mergeContext.metadataGenerator
              .propertyStatementIriFor(documentIri, s, predicate))
          .toSet();
      for (final stmtIri in newStmtIris) {
        // Remove all old triples that the new emission will re-introduce,
        // plus the inbound hasStatement edge. The new emission re-adds them
        // via `addNodes(documentIri, sync:hasStatement, ...)`.
        triplesToRemove.addAll(oldFrameworkGraph.findTriples(subject: stmtIri));
        triplesToRemove.addAll(oldFrameworkGraph.findTriples(
            predicate: SyncManagedDocument.hasStatement, object: stmtIri));

        // Vclk subgraph GC: if the OLD vclk this stmt pointed to is now
        // unreferenced by any OTHER PropertyStatement, drop its subgraph too.
        final staleVclks = oldFrameworkGraph
            .findTriples(subject: stmtIri, predicate: Crdt.vclk)
            .where((t) => t.object != vclkIri)
            .toList();
        for (final stale in staleVclks) {
          final staleVclkIri = stale.object;
          if (staleVclkIri is! IriTerm) continue;
          final otherReferences = oldFrameworkGraph
              .findTriples(predicate: Crdt.vclk, object: staleVclkIri)
              .where((t) => t.subject != stmtIri);
          if (otherReferences.isNotEmpty) continue;
          triplesToRemove.addAll(
              _collectVclkSubgraphTriples(staleVclkIri, oldFrameworkGraph));
        }
      }
    }

    return (
      statementsToAdd: statements,
      triplesToRemove: triplesToRemove,
    );
  }

  @override
  MergeResults? remoteMerge({
    required MergeSubject subject,
    required RdfPredicate predicate,
    required OrganizedGraph local,
    required OrganizedGraph remote,
    required RemoteCrdtMergeContext mergeContext,
  }) {
    // LWW-Register property-level resolution (issue #50):
    //
    // 1. Attempt per-property causality via `sync:PropertyStatement` →
    //    `crdt:vclk` (a content-addressed `crdt:VersionedClock` snapshot of
    //    the writer's HLC at save time). When PropertyStatements exist on
    //    BOTH sides, compare their vclks as proper vector clocks and resolve
    //    independently from other properties.
    // 2. Fall back to the document-wide clock comparison when per-property
    //    snapshots are missing on either side (legacy documents, properties
    //    saved before this feature, or non-LWW peers).
    //
    // Tie-break on `ClockComparison.concurrent` uses the maximum
    // `crdt:physicalTime` across the side's vclk entries when available,
    // otherwise the document-level `maxPhysicalTime`.
    final perPropertyComparison =
        _resolvePerPropertyClockComparison(subject, predicate, local, remote);

    final (ClockComparison comparison, int localPhysical, int remotePhysical) =
        perPropertyComparison ??
            (
              mergeContext.clockComparison,
              local.maxPhysicalTime,
              remote.maxPhysicalTime,
            );

    final Iterable<Triple>? winningTriples = switch (comparison) {
      ClockComparison.localDominates => subject.local != null
          ? local.fullGraph
              .findTriples(subject: subject.local!, predicate: predicate)
          : null,
      ClockComparison.remoteDominates => subject.remote != null
          ? remote.fullGraph
              .findTriples(subject: subject.remote!, predicate: predicate)
          : null,
      ClockComparison.concurrent => _physicalTimeTieBreakTriples(
          subject.local != null
              ? local.fullGraph
                  .findTriples(subject: subject.local!, predicate: predicate)
              : null,
          subject.remote != null
              ? remote.fullGraph
                  .findTriples(subject: subject.remote!, predicate: predicate)
              : null,
          localPhysical,
          remotePhysical,
        ),
      ClockComparison.identical => _handleIdenticalClocksTriples(
          subject.local,
          subject.remote,
          predicate,
          local.fullGraph,
          remote.fullGraph,
        ),
      ClockComparison.bothEmpty => _handleBothEmptyClocksTriples(
          subject.local,
          subject.remote,
          predicate,
          local.fullGraph,
          remote.fullGraph,
        ),
    };

    if (winningTriples == null || winningTriples.isEmpty) {
      return null;
    }

    // Map to use the merged subject
    final mergedTriples = winningTriples
        .map((t) => Triple(subject.subject, predicate, t.object))
        .toSet();

    final allTriples = addInlineTriples(mergedTriples, local, remote);

    // Preserve per-property causality on the merge result (proposal 028 /
    // issue #50): when the winning side carried an explicit
    // `sync:PropertyStatement(s,p) → crdt:vclk(V)`, re-emit that PS subgraph
    // (structural triples, the vclk subgraph, and the inbound
    // `sync:hasStatement` edge) on the merged document. Without this, the
    // merged document would lose its per-property vclk and a subsequent peer
    // re-pulling this state would fall back to document-clock comparison,
    // re-triggering issue #50 (a later concurrent update to a DIFFERENT
    // property would be silently dropped by the doc-level tie-break).
    //
    // PS IRIs are content-addressed over (documentIri, subject, predicate),
    // so we can deterministically reconstruct the IRI and look up its
    // subgraph in the winning side's framework graph. Absent on that side
    // (PS suppression for the appBaseClock-equivalent case, or non-IRI
    // subject) → emit nothing; the merged document's `appBaseClock` provides
    // the same effective vclk via the resolveVclk fallback chain.
    final winningGraph = _selectWinningSide(
      comparison: comparison,
      subject: subject,
      local: local,
      remote: remote,
      localPhysical: localPhysical,
      remotePhysical: remotePhysical,
    );
    if (winningGraph != null) {
      final winningSubject =
          identical(winningGraph, local) ? subject.local : subject.remote;
      final psTriples = _collectExplicitPropertyStatementTriples(
        winningGraph.documentIri,
        winningSubject,
        predicate,
        winningGraph.fullGraph,
        mergeContext.metadataGenerator,
      );
      if (psTriples.isNotEmpty) {
        allTriples.addAll(psTriples);
      }
    }

    return MergeResults(
      mergedTriples: allTriples,
      mergedStatements: {},
    );
  }
}

/// Determines which side's data won the per-property merge so that the
/// caller can preserve auxiliary metadata (e.g. `sync:PropertyStatement`
/// subgraphs) from that side onto the merge result. Mirrors the side
/// selection encoded in the `winningTriples` switch in
/// `LwwRegister.remoteMerge` — keep in sync.
OrganizedGraph? _selectWinningSide({
  required ClockComparison comparison,
  required MergeSubject subject,
  required OrganizedGraph local,
  required OrganizedGraph remote,
  required int localPhysical,
  required int remotePhysical,
}) {
  switch (comparison) {
    case ClockComparison.localDominates:
      return subject.local != null ? local : null;
    case ClockComparison.remoteDominates:
      return subject.remote != null ? remote : null;
    case ClockComparison.concurrent:
      if (localPhysical > remotePhysical) {
        return subject.local != null ? local : null;
      } else if (remotePhysical > localPhysical) {
        return subject.remote != null ? remote : null;
      }
      // Equal physical times → local tie-break (matches
      // `_physicalTimeTieBreakTriples`).
      return subject.local != null
          ? local
          : (subject.remote != null ? remote : null);
    case ClockComparison.identical:
    case ClockComparison.bothEmpty:
      // Values are guaranteed equal (or the merge would have thrown); either
      // side's PS — if any — encodes equivalent causality. Default to local.
      return subject.local != null
          ? local
          : (subject.remote != null ? remote : null);
  }
}

/// Collects the `sync:PropertyStatement` subgraph (structural triples +
/// `crdt:vclk` subgraph + inbound `sync:hasStatement` edge) for the
/// `(subject, predicate)` slot from [framework], or an empty set when the
/// winning side did not materialise a PS (PS suppression, blank-node
/// subject, or non-IRI predicate).
Set<Triple> _collectExplicitPropertyStatementTriples(
  IriTerm documentIri,
  RdfSubject? subject,
  RdfPredicate predicate,
  RdfGraph framework,
  MetadataGenerator metadataGenerator,
) {
  if (subject is! IriTerm) return const {};
  if (predicate is! IriTerm) return const {};
  final psIri = metadataGenerator.propertyStatementIriFor(
      documentIri, subject, predicate);
  final psTriples = framework.findTriples(subject: psIri).toSet();
  if (psTriples.isEmpty) return const {};

  final result = <Triple>{
    ...psTriples,
    // The OR-Set merge of `sync:hasStatement` on the documentIri subject
    // already picks up this IRI when it exists on either side, but emitting
    // it here makes the LWW path self-contained and tolerant of merge
    // orderings.
    Triple(documentIri, SyncManagedDocument.hasStatement, psIri),
  };
  for (final t in psTriples) {
    if (t.predicate == Crdt.vclk) {
      final vclkObj = t.object;
      if (vclkObj is IriTerm) {
        result.addAll(_collectVclkSubgraphTriples(vclkObj, framework));
      }
    }
  }
  return result;
}

/// Resolves a per-`(subject, predicate)` `ClockComparison` from
/// `sync:PropertyStatement → crdt:vclk` snapshots on both sides, returning
/// `null` when neither an explicit PropertyStatement NOR a document-level
/// `crdt:appBaseClock` fallback resolves on either side (forcing
/// document-wide fallback). Returns the comparison together with the max
/// physicalTime per side for concurrent tie-break.
///
/// Resolution order per side (proposal 028 `resolveVclk` chain):
///   1. `sync:PropertyStatement(s,p).crdt:vclk`
///   2. `<documentIri> crdt:appBaseClock <vclk>`
///   3. fall through (caller uses document-clock comparison)
(ClockComparison, int, int)? _resolvePerPropertyClockComparison(
  MergeSubject subject,
  RdfPredicate predicate,
  OrganizedGraph local,
  OrganizedGraph remote,
) {
  final localVclkIri = _resolveEffectiveVclkIri(subject.localKey, predicate,
      local.documentIri, local.statements, local.fullGraph);
  final remoteVclkIri = _resolveEffectiveVclkIri(subject.remoteKey, predicate,
      remote.documentIri, remote.statements, remote.fullGraph);
  if (localVclkIri == null || remoteVclkIri == null) return null;

  final localEntries = _resolveVclkEntries(localVclkIri, local.fullGraph);
  final remoteEntries = _resolveVclkEntries(remoteVclkIri, remote.fullGraph);
  if (localEntries.isEmpty || remoteEntries.isEmpty) return null;

  final logicalLocal = {
    for (final e in localEntries.entries) e.key: (e.value.$1, e.value.$2)
  };
  final logicalRemote = {
    for (final e in remoteEntries.entries) e.key: (e.value.$1, e.value.$2)
  };

  final comparison =
      ClockComparison.compareClockMaps(logicalLocal, logicalRemote);

  final localPhysical = localEntries.values
      .map((e) => e.$2)
      .fold<int>(0, (a, b) => a > b ? a : b);
  final remotePhysical = remoteEntries.values
      .map((e) => e.$2)
      .fold<int>(0, (a, b) => a > b ? a : b);

  return (comparison, localPhysical, remotePhysical);
}

/// Implements the proposal 028 per-side `resolveVclk` chain:
///   PropertyStatement(s,p).vclk  →  document.appBaseClock  →  null
///
/// `appBaseClock` is a document-scoped triple; per ManagedDocument there is
/// at most one such triple, so a graph-wide `findTriples` lookup is
/// unambiguous and saves us threading the documentIri through the call
/// site.
///
/// IMPORTANT: the `appBaseClock` fallback is APP-DATA-ONLY. Framework-data
/// predicates whose subject is the `documentIri` itself (e.g.
/// `crdt:clockHash`, `sync:managedResourceType`, `sync:isGovernedBy`,
/// `foaf:primaryTopic`) MUST NOT consult `appBaseClock` — they are never
/// PS-stamped and their merge semantics fall through to document-clock
/// comparison. Without this guard, two installations that share a common
/// `appBaseClock` would resolve identical vclks for framework predicates,
/// triggering a spurious `ClockComparison.identical` and a fatal
/// "different values for predicate" error in `_handleIdenticalClocksTriples`.
IriTerm? _resolveEffectiveVclkIri(
  RdfObjectKey? subjectKey,
  RdfPredicate predicate,
  IriTerm documentIri,
  OrganizedStatements statements,
  RdfGraph fullGraph,
) {
  if (subjectKey != null) {
    final stmt = statements.getStatement(subjectKey, predicate, null);
    if (stmt != null) {
      final vclkIri = _firstVclkIri(stmt);
      if (vclkIri != null) return vclkIri;
    }
  }
  // Framework-data subjects (subject == documentIri) never participate in
  // the appBaseClock fallback — see method dartdoc.
  if (subjectKey is IriSubjectKey && subjectKey.iri == documentIri) {
    return null;
  }
  return fullGraph
      .findTriples(predicate: Crdt.appBaseClock)
      .map((t) => t.object)
      .whereType<IriTerm>()
      .firstOrNull;
}

IriTerm? _firstVclkIri(MetadataStatement stmt) {
  final objects = stmt.predicateObjectMap[Crdt.vclk];
  if (objects == null || objects.isEmpty) return null;
  for (final o in objects) {
    if (o is IriTerm) return o;
  }
  return null;
}

/// Resolves the vclk subgraph anchored at [vclkIri] into a
/// `forClockEntry → (logicalTime, physicalTime)` map. Returns an empty map
/// when the vclk is unreachable or malformed (treated by the caller as a
/// fallback trigger).
Map<IriTerm, (int, int)> _resolveVclkEntries(IriTerm vclkIri, RdfGraph graph) {
  final result = <IriTerm, (int, int)>{};
  final entryNodes = graph
      .findTriples(
          subject: vclkIri, predicate: CrdtVersionedClock.hasClockEntry)
      .map((t) => t.object)
      .whereType<RdfSubject>();
  for (final entryNode in entryNodes) {
    final forEntry = graph
        .findTriples(subject: entryNode, predicate: Crdt.forClockEntry)
        .map((t) => t.object)
        .whereType<IriTerm>()
        .firstOrNull;
    if (forEntry == null) continue;
    final logical = graph
        .findTriples(subject: entryNode, predicate: CrdtClockEntry.logicalTime)
        .map((t) => t.object)
        .whereType<LiteralTerm>()
        .map((l) => int.tryParse(l.value))
        .firstWhere((v) => v != null, orElse: () => null);
    final physical = graph
        .findTriples(subject: entryNode, predicate: CrdtClockEntry.physicalTime)
        .map((t) => t.object)
        .whereType<LiteralTerm>()
        .map((l) => int.tryParse(l.value))
        .firstWhere((v) => v != null, orElse: () => null);
    if (logical == null || physical == null) continue;
    result[forEntry] = (logical, physical);
  }
  return result;
}

Set<Triple> addInlineTriples(
    Set<Triple> triples, OrganizedGraph local, OrganizedGraph remote) {
  final localUnidentifiedBlankNodes = <BlankNodeTerm>{};
  final remoteUnidentifiedBlankNodes = <BlankNodeTerm>{};
  for (final triple in triples) {
    if (triple.object is BlankNodeTerm) {
      final bnode = triple.object as BlankNodeTerm;
      if (!local.blankNodeMappings.isIdentified(bnode)) {
        localUnidentifiedBlankNodes.add(bnode);
      }
      if (!remote.blankNodeMappings.isIdentified(bnode)) {
        remoteUnidentifiedBlankNodes.add(bnode);
      }
    }
  }
  if (localUnidentifiedBlankNodes.isEmpty &&
      remoteUnidentifiedBlankNodes.isEmpty) {
    return triples;
  }
  return {
    ...triples,
    ...localUnidentifiedBlankNodes
        .expand((bnode) => subjectAndInlineTriples(local, bnode)),
    ...remoteUnidentifiedBlankNodes
        .expand((bnode) => subjectAndInlineTriples(remote, bnode)),
  };
}

/// Collects all triples belonging to a `crdt:VersionedClock` subgraph:
/// the vclk node itself plus the contained `crdt:hasClockEntry` blank nodes
/// (and all triples about those blank nodes). Used by LWW-Register to
/// garbage-collect stale vclk snapshots whose only reference has been
/// replaced. Safe because vclk entry blank nodes are exclusively reachable
/// from their owning vclk (see `<#versioned-clock>` mapping).
Set<Triple> _collectVclkSubgraphTriples(IriTerm vclkIri, RdfGraph graph) {
  final result = <Triple>{};
  final vclkTriples = graph.findTriples(subject: vclkIri).toList();
  result.addAll(vclkTriples);
  final entryBlankNodes = vclkTriples
      .where((t) => t.predicate == CrdtVersionedClock.hasClockEntry)
      .map((t) => t.object)
      .whereType<BlankNodeTerm>();
  for (final bn in entryBlankNodes) {
    result.addAll(graph.findTriples(subject: bn));
  }
  return result;
}

class Immutable implements CrdtType {
  const Immutable();

  @override
  IriTerm get iri => AlgoImmutable.classIri;

  bool get isSingleValueSupported => true;

  @override
  Metadata localValueChange({
    required PropertyValueContext? oldPropertyValue,
    required PropertyValueContext newPropertyValue,
    required RdfGraph? oldFrameworkGraph,
    required CrdtMergeContext mergeContext,
    required int physicalClock,
  }) {
    // No metadata needed for changing a Immutable value - there are not changes allowed.
    return noMetadata;
  }

  @override
  MergeResults? remoteMerge({
    required MergeSubject subject,
    required RdfPredicate predicate,
    required OrganizedGraph local,
    required OrganizedGraph remote,
    required RemoteCrdtMergeContext mergeContext,
  }) {
    // Immutable: Value cannot change once set
    // If both have values, they must be identical or there's a conflict
    // Use whichever exists, preferring local if both exist

    final localValues =
        objectsIfSubjectNonNull(local.fullGraph, subject.local, predicate);
    final remoteValues =
        objectsIfSubjectNonNull(local.fullGraph, subject.local, predicate);

    // If both have values, they must be identical
    if (localValues.isNotEmpty && remoteValues.isNotEmpty) {
      if (!_iterableEquality.equals(localValues, remoteValues)) {
        throw StateError(
          'Immutable value conflict: Local and remote have different values. '
          'Local: $localValues, Remote: $remoteValues. '
          'Immutable properties cannot change once set.',
        );
      }
    }

    // Return whichever exists, preferring local if both exist
    final winningValues = localValues.isNotEmpty ? localValues : remoteValues;

    if (winningValues.isEmpty) {
      return null;
    }

    // Map to use the merged subject
    final mergedTriples = winningValues
        .map((object) => Triple(subject.subject, predicate, object))
        .toSet();

    return MergeResults(
      mergedTriples: addInlineTriples(mergedTriples, local, remote),
      mergedStatements: {},
    );
  }
}

/// Observed-Remove Set for multi-value properties.
class OrSet implements CrdtType {
  @override
  IriTerm get iri => AlgoOR_Set.classIri;

  bool get isSingleValueSupported => false;

  @override
  MergeResults? remoteMerge({
    required MergeSubject subject,
    required RdfPredicate predicate,
    required OrganizedGraph local,
    required OrganizedGraph remote,
    required RemoteCrdtMergeContext mergeContext,
  }) {
    final comparison = mergeContext.clockComparison;
    // OR-Set with Add-Wins semantics
    // Per CRDT spec section 3.3: Merge all elements, then filter by tombstones

    // We have to use merge objects here to properly handle identified blank nodes
    final mergeObjects = MergeObject.createMergeObjects(
      local,
      objectsIfSubjectNonNull(local.fullGraph, subject.local, predicate),
      remote,
      objectsIfSubjectNonNull(remote.fullGraph, subject.remote, predicate),
    );

    // Filter elements by checking tombstones
    final mergedValues = <RdfObject>{};
    final mergedStatements = <MetadataStatementKey, MetadataStatement>{};

    for (final mergeObject in mergeObjects) {
      final existsRemote = mergeObject.remote != null;
      final existsLocal = mergeObject.local != null;
      final remoteStatement = remote.getStatementForKey(
          // we fallback to localKey to catch statements that exist remote
          // for the canonical blank node iris of local, but since blank node
          // does not exist remote any more, there is no remote key
          subject.remoteKey ?? subject.localKey!,
          predicate,
          mergeObject.remoteKey ?? mergeObject.localKey!);

      final localStatement = local.getStatementForKey(
          // we fallback to remoteKey to catch statements that exist local
          // for the canonical blank node iris of remote, but since blank node
          // does not exist local any more, there is no local key
          subject.localKey ?? subject.remoteKey!,
          predicate,
          mergeObject.localKey ?? mergeObject.remoteKey!);
      final mergeInstructions = computeMergeInstructions(
          comparison,
          localStatement,
          existsLocal,
          local,
          remoteStatement,
          existsRemote,
          remote);
      switch (mergeInstructions) {
        case MergeInstruction.keepLocal:
          if (existsLocal) {
            mergedValues.add(mergeObject.object);
          }
          if (localStatement != null) {
            mergedStatements[localStatement.key] = localStatement;
          }
        case MergeInstruction.keepRemote:
          if (existsRemote) {
            mergedValues.add(mergeObject.object);
          }
          if (remoteStatement != null) {
            mergedStatements[remoteStatement.key] = remoteStatement;
          }
        case MergeInstruction.mergeRequired:
          // TODO: should we ever have non-tombstone statements, we might need to merge them here
          if (existsLocal) {
            mergedValues.add(mergeObject.object);
          }
          if (existsRemote) {
            mergedValues.add(mergeObject.object);
          }
        case MergeInstruction.none:
          // should never happen, but does not matter. Just ignore.
          break;
      }
    }

    if (mergedValues.isEmpty && mergedStatements.isEmpty) {
      return null;
    }

    // Create triples with merged subject
    final mergedTriples =
        mergedValues.map((v) => Triple(subject.subject, predicate, v)).toSet();

    return MergeResults(
      mergedTriples: addInlineTriples(mergedTriples, local, remote),
      mergedStatements: mergedStatements,
    );
  }

  @override
  Metadata localValueChange({
    required PropertyValueContext? oldPropertyValue,
    required PropertyValueContext newPropertyValue,
    required RdfGraph? oldFrameworkGraph,
    required CrdtMergeContext mergeContext,
    required int physicalClock,
  }) {
    _validateBlankNodeValues(
        newPropertyValue.values, newPropertyValue.blankNodes, "Or Set values");
    if (oldPropertyValue == null || oldFrameworkGraph == null) {
      // Initial value - no deletions
      return noMetadata;
    }
    assert(oldPropertyValue.documentIri == newPropertyValue.documentIri);
    assert(oldPropertyValue.predicate == newPropertyValue.predicate);
    _validateBlankNodeValues(oldPropertyValue.values,
        oldPropertyValue.blankNodes, "Old Or Set values");
    final identifiedNewValues = newPropertyValue.values
        .map((v) => _identify(v, newPropertyValue.blankNodes))
        .toSet();
    final identifiedOldValues = oldPropertyValue.values
        .map((v) => _identify(v, oldPropertyValue.blankNodes))
        .toSet();
    // for an OR set, we need to add tombstones for removed values
    final removedValues = identifiedOldValues.toSet();
    removedValues.removeAll(identifiedNewValues);
    final deletionDate = physicalClock;
    final deletionDateTerm =
        LiteralTermExtensions.dateTimeFromMillisecondsSinceEpoch(deletionDate);
    final newSubject =
        IdTerm.create(newPropertyValue.subject, newPropertyValue.blankNodes);

    final statements =
        removedValues.expand(_expandIdentifiedValues).expand((value) {
      return mergeContext.metadataGenerator.createPropertyValueMetadata(
          newPropertyValue.documentIri,
          newSubject,
          newPropertyValue.predicate,
          IdTerm.create(value, oldPropertyValue.blankNodes),
          (metadataSubject) => removedValues
              .map((rv) => Triple(metadataSubject, RdfStatement.crdtDeletedAt,
                  deletionDateTerm))
              .toList());
    });

    // Find and remove outdated tombstones for re-added values
    final reAddedValues = identifiedNewValues.toSet();
    reAddedValues.removeAll(identifiedOldValues);

    final triplesToRemove = _findTombstonesToRemove(
        reAddedValues.expand(_expandIdentifiedValues).toSet(),
        oldFrameworkGraph,
        newPropertyValue,
        newSubject);

    return (statementsToAdd: statements, triplesToRemove: triplesToRemove);
  }

  /// Finds tombstone statements that should be removed for re-added values.
  ///
  /// When a value is re-added after being deleted, its old tombstone becomes
  /// outdated and should be removed from the framework graph. This implements
  /// the "Add-Wins" semantics by cleaning up obsolete deletion markers.
  ///
  /// Only removes tombstones that have no other predicates besides the standard
  /// RDF reification triples (subject, predicate, object, hasStatement) and
  /// crdt:deletedAt. If a tombstone has additional properties, it is preserved.
  Iterable<Triple> _findTombstonesToRemove(
    Set<RdfObject> reAddedCanonicalValues,
    RdfGraph oldFrameworkGraph,
    PropertyValueContext newPropertyValue,
    IdTerm<RdfSubject> canonicalOldSubject,
  ) {
    return _findStatementTriplesToRemove(
      newPropertyValue.documentIri,
      canonicalOldSubject.localSubjectIris,
      newPropertyValue.predicate,
      reAddedCanonicalValues,
      {RdfStatement.crdtDeletedAt},
      oldFrameworkGraph,
    );
  }
}

class CrdtMergeContext {
  final FrameworkIriGenerator iriGenerator;
  final MetadataGenerator metadataGenerator;

  /// Content-addressed IRI of the `crdt:VersionedClock` snapshot for the
  /// current save, pre-computed once per save by the caller. Causality-tracking
  /// CRDT types (e.g. LWW-Register) reference this IRI from
  /// `sync:PropertyStatement` nodes; the vclk subgraph itself is emitted once
  /// per save by the orchestrator, not inline per property, to avoid duplicate
  /// triples in `List<Triple>` document buffers.
  ///
  /// `null` signals "skip per-property causality stamping for this pass". The
  /// caller chooses per pass whether stamping is enabled:
  ///   * App-data pass: non-null → property-level causality recorded.
  ///   * Framework-data pass: null → fall back to document-clock comparison
  ///     during remoteMerge. This avoids stamping framework infrastructure
  ///     (PropertyStatement / VersionedClock nodes, document-level CRDT
  ///     plumbing, shard-entry headers) where per-property vclks would
  ///     either recurse into themselves or be redundant with the document
  ///     clock derivation.
  ///   * Raw template / standalone processing: null (no clock context).
  final IriTerm? vclkIri;

  /// Content-addressed IRI of the document-wide *implicit default* vclk for
  /// app properties (proposal 028, `crdt:appBaseClock`). A property whose
  /// effective `crdt:vclk` equals this IRI does NOT need an explicit
  /// `sync:PropertyStatement` — the remote-merge `resolveVclk` chain will
  /// fall back to this same vclk via the document's `appBaseClock` triple
  /// (or, when no `appBaseClock` is set, via the document's `docClock`).
  ///
  /// Used by causality-tracking CRDT types to suppress PS emission when the
  /// stamp would be redundant. `null` is interpreted as "no implicit default
  /// is known to the orchestrator" — in that case any non-null `vclkIri`
  /// triggers explicit PS emission (the conservative pre-proposal-028
  /// behaviour).
  final IriTerm? implicitDefaultVclkIri;

  CrdtMergeContext({
    required this.iriGenerator,
    required this.metadataGenerator,
    this.vclkIri,
    this.implicitDefaultVclkIri,
  });
}

class RemoteCrdtMergeContext {
  final ClockComparison clockComparison;

  /// Used by causality-tracking CRDT types (LWW-Register) to deterministically
  /// compute `sync:PropertyStatement` IRIs when re-emitting per-property vclk
  /// snapshots on the merge result. The content-addressed IRI is identical to
  /// the one the winning side originally produced, allowing the framework
  /// graph to be looked up via `fullGraph.findTriples(subject: psIri)`.
  final MetadataGenerator metadataGenerator;

  RemoteCrdtMergeContext({
    required this.clockComparison,
    required this.metadataGenerator,
  });
}

class CrdtTypeRegistry {
  final Map<IriTerm, CrdtType> _typesByIri;
  static const CrdtType fallback = LwwRegister();
  CrdtTypeRegistry._(List<CrdtType> types)
      : _typesByIri = {for (var type in types) type.iri: type};

  CrdtTypeRegistry.forStandardTypes()
      : this._([
          LwwRegister(),
          //FwwRegister(),
          Immutable(),
          OrSet(),
          GRegister(),
        ]);

  /// Get the CRDT type instance for the given IRI - fallbacks to LWW Register.
  CrdtType getType(IriTerm? typeIri,
          {CrdtType fallback = CrdtTypeRegistry.fallback}) =>
      typeIri == null ? fallback : _typesByIri[typeIri] ?? fallback;

  bool hasType(IriTerm algo) => _typesByIri.containsKey(algo);
}

/// Removes specific properties from RDF statement reifications that match
/// the given triple patterns (subjects, predicate, objects).
///
/// This method finds statement reifications (using RDF reification vocabulary)
/// that describe triples matching the provided patterns, then determines whether
/// to remove only specific properties or the entire statement reification.
///
/// **How it works:**
/// 1. Finds all statement reifications matching: `(subjects, predicate, objects)`
/// 2. For each matching statement, checks if it has properties beyond:
///    - Core RDF reification: rdf:type, rdf:subject, rdf:predicate, rdf:object
///    - Properties to delete: specified in [predicatesToDelete]
/// 3. Decision:
///    - If statement has **additional properties**: Remove only [predicatesToDelete]
///    - If statement has **only core + to-delete**: Remove entire statement including
///      the document's `sync:hasStatement` link
///
/// **Use case - OR-Set tombstone cleanup:**
/// When a value is re-added after deletion, its tombstone becomes outdated.
/// This method removes the `crdt:deletedAt` property. If the statement reification
/// has no other custom properties, the entire statement is safely removed.
///
/// **Canonical Subjects:**
/// [subjects] supports multiple subjects to handle the "canonical subject" concept,
/// where identified blank nodes may have multiple equivalent representations.
///
/// **Parameters:**
/// - [documentIri]: The document containing the statements (for hasStatement link)
/// - [subjects]: Subject(s) of the triples to find (supports canonical identification)
/// - [predicate]: Predicate of the triples to find
/// - [objects]: Object(s) of the triples to find
/// - [predicatesToDelete]: Properties to remove from the statement (e.g., crdt:deletedAt)
/// - [frameworkGraph]: The framework metadata graph to search
///
/// **Returns:**
/// Triples to remove from the framework graph - either specific properties only,
/// or the entire statement reification plus its hasStatement link.
///
/// **Example:**
/// ```dart
/// // Remove crdt:deletedAt from statements about `:recipe schema:keywords "spicy"`
/// _removeStatementProperty(
///   documentIri,
///   [:recipe],                        // canonical subjects
///   schema.keywords,                  // predicate
///   ["spicy"],                        // objects
///   {RdfStatement.crdtDeletedAt},    // properties to delete
///   frameworkGraph,
/// );
/// ```
Iterable<Triple> _findStatementTriplesToRemove(
  IriTerm documentIri,
  Iterable<RdfSubject> subjects,
  RdfPredicate predicate,
  Iterable<RdfObject> objects,
  Iterable<IriTerm> predicatesToDelete,
  RdfGraph frameworkGraph,
) {
  if (objects.isEmpty) {
    return [];
  }
  final statementSubjectsForSubject = frameworkGraph
      .findTriples(
        predicate: RdfStatement.subject,
        objectIn: subjects,
      )
      .map((t) => t.subject)
      .toSet();
  final statementSubjectsForPredicate = frameworkGraph
      .findTriples(
          subjectIn: statementSubjectsForSubject,
          predicate: RdfStatement.predicate,
          object: switch (predicate) { final IriTerm iri => iri })
      .map((t) => t.subject)
      .toSet();
  final statementSubjects = frameworkGraph
      .findTriples(
          subjectIn: statementSubjectsForPredicate,
          predicate: RdfStatement.object,
          objectIn: objects)
      .map((t) => t.subject)
      .toSet();
  return statementSubjects.expand((subj) {
    final stmt = frameworkGraph.matching(subject: subj);

    final stillNeeded = stmt.predicates.difference(
        {..._coreStatementPredicates, ...predicatesToDelete}).isNotEmpty;

    if (stillNeeded) {
      return frameworkGraph.findTriples(
          subject: subj, predicateIn: predicatesToDelete);
    }
    return [
      Triple(documentIri, SyncManagedDocument.hasStatement, subj),
      ...stmt.triples
    ];
  });
}

Object _identify(RdfObject v, IdentifiedBlankNodes<IriTerm> newBlankNodes) {
  if (v is BlankNodeTerm) {
    return IdentifiedBlankNodeSubject(v, newBlankNodes.getIdentifiedNodes(v));
  } else {
    return v;
  }
}

void _validateBlankNodeValues(Iterable<RdfObject> values,
    IdentifiedBlankNodes<IriTerm> blankNodes, String lbl) {
  for (final value in values) {
    if (value is BlankNodeTerm) {
      if (!blankNodes.hasIdentifiedNodes(value)) {
        throw UnidentifiedBlankNodeException(value, lbl);
      }
    }
  }
}

List<RdfObject> _expandIdentifiedValues(Object identifiedValue) =>
    switch (identifiedValue) {
      final IdentifiedBlankNodeSubject ibn => ibn.identifiers,
      _ => [identifiedValue as RdfObject],
    };

/// Performs physical time tie-breaking for concurrent operations.
///
/// Per CRDT spec section 2.3: When operations are concurrent (no causal
/// relationship), use physical time for "most recent wins" semantics.
Iterable<Triple>? _physicalTimeTieBreakTriples(
  Iterable<Triple>? localTriples,
  Iterable<Triple>? remoteTriples,
  int localPhysicalTime,
  int remotePhysicalTime,
) {
  if (localPhysicalTime > remotePhysicalTime) {
    return localTriples;
  } else if (remotePhysicalTime > localPhysicalTime) {
    return remoteTriples;
  } else {
    // Equal physical times - use local as deterministic tie-breaker
    return localTriples;
  }
}

/// Handles the case where local and remote clocks are identical.
/// According to CRDT semantics, identical clocks should only occur with identical values.
/// If values differ, this indicates a system bug or race condition.
///
/// Throws [StateError] if values differ with identical clocks.
Iterable<Triple>? _handleIdenticalClocksTriples(
  RdfSubject? localSubject,
  RdfSubject? remoteSubject,
  RdfPredicate predicate,
  RdfGraph localGraph,
  RdfGraph remoteGraph,
) {
  final localTriples = localSubject != null
      ? localGraph
          .findTriples(subject: localSubject, predicate: predicate)
          .toSet()
      : <Triple>{};
  final remoteTriples = remoteSubject != null
      ? remoteGraph
          .findTriples(subject: remoteSubject, predicate: predicate)
          .toSet()
      : <Triple>{};

  final localValues = localTriples.map((t) => t.object).toSet();
  final remoteValues = remoteTriples.map((t) => t.object).toSet();

  // Check if values actually differ
  if (!_iterableEquality.equals(localValues, remoteValues)) {
    final localValuesAllBlankNodes =
        !localValues.any((v) => v is! BlankNodeTerm);
    final remoteValuesAllBlankNodes =
        !remoteValues.any((v) => v is! BlankNodeTerm);
    if (!(localValuesAllBlankNodes && remoteValuesAllBlankNodes)) {
      final localSubgraphs = localValues
          .whereType<RdfSubject>()
          .map((v) => localGraph.subgraph(v))
          .toSet();
      final remoteSubgraphs = remoteValues
          .whereType<RdfSubject>()
          .map((v) => remoteGraph.subgraph(v))
          .toSet();
      final localSubgraphsInfo = localSubgraphs.isEmpty
          ? ''
          : '''
${'-' * 10} Local Subgraph ${'-' * 10}  
${turtle.encode(RdfGraph.fromTriples(localSubgraphs.expand((g) => g.triples).toSet()))}
''';
      final remoteSubgraphsInfo = remoteSubgraphs.isEmpty
          ? ''
          : '''
${'-' * 10} Remote Subgraph ${'-' * 10}  
${turtle.encode(RdfGraph.fromTriples(remoteSubgraphs.expand((g) => g.triples).toSet()))}
''';
      final subgraphsInfo =
          localSubgraphsInfo.isNotEmpty || remoteSubgraphsInfo.isNotEmpty
              ? localSubgraphsInfo + remoteSubgraphsInfo + ('-' * 10) + '\n'
              : '';
      throw StateError(
        '''
Clock conflict detected: Identical clocks with different values for predicate ${predicate} subject local: ${localSubject.debug} remote: ${remoteSubject.debug}. 
Local values: $localValues
Remote values: $remoteValues
$subgraphsInfo
This indicates a system bug or clock synchronization issue.
''',
      );
    }
  }

  // Values are identical, return either (they're the same)
  return localTriples;
}

/// Handles the case where both local and remote clocks are empty.
/// This typically occurs with template resources or uninitialized data.
/// Local value wins by default (spec-compliant), but we log for visibility.
///
/// Logs at info level if values differ.
Iterable<Triple>? _handleBothEmptyClocksTriples(
  RdfSubject? localSubject,
  RdfSubject? remoteSubject,
  RdfPredicate predicate,
  RdfGraph localGraph,
  RdfGraph remoteGraph,
) {
  final localTriples = localSubject != null
      ? localGraph
          .findTriples(subject: localSubject, predicate: predicate)
          .toSet()
      : <Triple>{};
  final remoteTriples = remoteSubject != null
      ? remoteGraph
          .findTriples(subject: remoteSubject, predicate: predicate)
          .toSet()
      : <Triple>{};

  final localValues = localTriples.map((t) => t.object).toSet();
  final remoteValues = remoteTriples.map((t) => t.object).toSet();

  // Log if values differ - this is informational, not an error
  if (!_iterableEquality.equals(localValues, remoteValues)) {
    _log.info(
      'Both clocks empty with different values. '
      'Local: $localValues, Remote: $remoteValues. '
      'This may occur with template resources. Local value wins.',
    );
  }

  // Local wins on both empty (spec-compliant)
  return localTriples;
}

// ============================================================================
// Shared helper functions for CRDT merge operations
// ============================================================================

const _iterableEquality = UnorderedIterableEquality<RdfObject>();

/// Compares two value iterables for equality using deep comparison.
/// Handles null, empty, and set comparison using [IterableEquality].
///
/// Returns true if both are null, both are empty, or both contain the same elements
/// (order-independent, since we treat them as sets).
bool valuesEqual(Iterable<RdfObject>? a, Iterable<RdfObject>? b) {
  if (a == null && b == null) return true;
  if (a == null || b == null) return false;

  return _iterableEquality.equals(a, b);
}

Iterable<RdfObject> objectsIfSubjectNonNull(
    RdfGraph graph, RdfSubject? subject, RdfPredicate predicate) {
  if (subject == null) {
    return const {};
  }
  return graph
      .findTriples(subject: subject, predicate: predicate)
      .map((t) => t.object)
      .toSet();
}

enum MergeInstruction {
  keepLocal,
  keepRemote,
  mergeRequired,
  none,
}

enum MergeObjectState {
  present,
  tombstoned,
  unknown;

  static MergeObjectState from(MetadataStatement? statement, bool exists) {
    if (exists && statement.isTombstoned()) {
      // Stale subject-level tombstone: the subject has triples (exists)
      // but old CRDT metadata still carries a deletion marker. This can
      // happen when a shard entry is removed and re-added before the
      // tombstone is cleaned up. Treat as present (add-wins semantics).
      _log.warning('Subject exists but has stale tombstone metadata '
          '— treating as present (add-wins) ${statement?.key}');
      return MergeObjectState.present;
    }
    if (exists) {
      return MergeObjectState.present;
    } else if (statement.isTombstoned()) {
      return MergeObjectState.tombstoned;
    } else {
      return MergeObjectState.unknown;
    }
  }
}

MergeInstruction computeMergeInstructions(
  ClockComparison comparison,
  MetadataStatement? localValueStatement,
  bool localValueExists,
  OrganizedGraph local,
  MetadataStatement? remoteValueStatement,
  bool remoteValueExists,
  OrganizedGraph remote,
) {
  final localState =
      MergeObjectState.from(localValueStatement, localValueExists);
  final remoteState =
      MergeObjectState.from(remoteValueStatement, remoteValueExists);
  return switch ((localState, remoteState)) {
    // Both present - normal merge required
    (MergeObjectState.present, MergeObjectState.present) =>
      MergeInstruction.mergeRequired,

    // Tombstoned remote, exists local - check if tombstone wins
    (MergeObjectState.present, MergeObjectState.tombstoned) =>
      remoteTombstoneWins(comparison, remote, local)
          ? MergeInstruction.keepRemote
          : MergeInstruction.keepLocal,

    // Only exists local, remote has never seen it - keep local
    (MergeObjectState.present, MergeObjectState.unknown) =>
      MergeInstruction.keepLocal,

    // Tombstoned local, exists remote - check if tombstone wins
    (MergeObjectState.tombstoned, MergeObjectState.present) =>
      localTombstoneWins(comparison, remote, local)
          ? MergeInstruction.keepLocal
          : MergeInstruction.keepRemote,

    // Both tombstoned - decide which tombstone to keep based on clock
    (MergeObjectState.tombstoned, MergeObjectState.tombstoned) =>
      remoteTombstoneWins(comparison, remote, local)
          ? MergeInstruction.keepRemote
          : MergeInstruction.keepLocal,

    // Only tombstoned local, remote has never seen it - keep local tombstone
    (MergeObjectState.tombstoned, MergeObjectState.unknown) =>
      MergeInstruction.keepLocal,

    // Only exists remote, local has never seen it - keep remote
    (MergeObjectState.unknown, MergeObjectState.present) =>
      MergeInstruction.keepRemote,

    // Only tombstoned remote, local has never seen it - keep remote tombstone
    (MergeObjectState.unknown, MergeObjectState.tombstoned) =>
      MergeInstruction.keepRemote,

    // Neither knows about it - nothing to do - but this should not happen
    (MergeObjectState.unknown, MergeObjectState.unknown) => () {
        assert(false, 'Unexpected merge state: both unknown');
        return MergeInstruction.none;
      }(),
  };
}

bool localTombstoneWins(
    ClockComparison comparison, OrganizedGraph remote, OrganizedGraph local) {
  return switch (comparison) {
    ClockComparison.localDominates => true, // Local Delete dominates add
    ClockComparison.remoteDominates => false, // Add dominates delete
    ClockComparison.concurrent => local.clock.physicalTime >
        remote.clock.physicalTime, // Physical time tie-break
    ClockComparison.identical => false, // Add-Wins on identical
    ClockComparison.bothEmpty => false, // Add-Wins on both empty
  };
}

bool remoteTombstoneWins(
    ClockComparison comparison, OrganizedGraph remote, OrganizedGraph local) {
  return switch (comparison) {
    ClockComparison.localDominates => false, // Local add
    ClockComparison.remoteDominates => true, // Remote delete dominates
    ClockComparison.concurrent => remote.clock.physicalTime >
        local.clock.physicalTime, // Physical time tie-break
    ClockComparison.identical => false, // Add-Wins on identical
    ClockComparison.bothEmpty => false, // Add-Wins on both empty
  };
}
