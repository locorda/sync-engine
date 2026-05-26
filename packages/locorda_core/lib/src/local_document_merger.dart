/// Main facade for the CRDT sync system.
library;

import 'package:collection/collection.dart';
import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_core/src/crdt/crdt_types.dart';
import 'package:locorda_core/src/crdt/property_clock.dart';
import 'package:locorda_core/src/hlc_service.dart';
import 'package:locorda_core/src/mapping/framework_iri_generator.dart';
import 'package:locorda_core/src/mapping/identified_blank_node_builder.dart';
import 'package:locorda_core/src/mapping/merge_contract.dart';
import 'package:locorda_core/src/mapping/metadata_generator.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/sync/shard_entry_utils.dart';
import 'package:locorda_core/src/vocab/generated/_index.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:logging/logging.dart';

final _log = Logger('LocalDocumentMerger');

/// Merges local document changes and generates necessary CRDT metadata.
///
/// Note that this is not for merging local and remote changes, but only
/// for local modifications to a document.
class LocalDocumentMerger {
  final CrdtTypeRegistry _crdtTypeRegistry;
  final FrameworkIriGenerator _iriGenerator;

  late final IdentifiedBlankNodeBuilder _identifiedBlankNodeBuilder =
      IdentifiedBlankNodeBuilder(iriGenerator: _iriGenerator);
  late final MetadataGenerator _metadataGenerator =
      MetadataGenerator(frameworkIriGenerator: _iriGenerator);

  LocalDocumentMerger({
    required FrameworkIriGenerator frameworkIriGenerator,
    required CrdtTypeRegistry crdtTypeRegistry,
  })  : _crdtTypeRegistry = crdtTypeRegistry,
        _iriGenerator = frameworkIriGenerator;

  ({
    IdentifiedBlankNodes<IriTerm> oldBlankNodes,
    IdentifiedBlankNodes<IriTerm> newBlankNodes,
    CrdtMetadataResult metadata,
  }) generateMetadata(
    IriTerm documentIri,
    RdfGraph appData,
    RdfGraph? oldAppData,
    RdfGraph? oldFrameworkGraph,
    MergeContract mergeContract,
    CurrentCrdtClock clock, {
    required IriTerm appDataTypeIri,
    bool isFrameworkData = false,
    bool computeCanonicalBlankNodes = true,
    IriTerm? ownClockEntryIri,
  }) {
    // 4. Detect property changes between old and new app graphs and generate CRDT metadata
    final appBlankNodes = computeCanonicalBlankNodes
        ? _identifiedBlankNodeBuilder.computeCanonicalBlankNodes(
            documentIri, appData, mergeContract)
        : IdentifiedBlankNodes.empty<IriTerm>();
    final oldAppBlankNodes = (oldAppData == null || !computeCanonicalBlankNodes)
        ? IdentifiedBlankNodes.empty<IriTerm>()
        : _identifiedBlankNodeBuilder.computeCanonicalBlankNodes(
            documentIri, oldAppData, mergeContract);
    final crdtMetadata = _generateCrdtMetadataForChanges(
        documentIri,
        appData,
        appBlankNodes,
        oldAppData,
        oldFrameworkGraph,
        oldAppBlankNodes,
        mergeContract,
        clock,
        appDataTypeIri: appDataTypeIri,
        isFrameworkData: isFrameworkData,
        ownClockEntryIri: ownClockEntryIri);
    return (
      oldBlankNodes: oldAppBlankNodes,
      newBlankNodes: appBlankNodes,
      metadata: crdtMetadata
    );
  }

/**
 * For really simple cases like replacing index shards, we can avoid full CRDT merge
 * and just replace the relevant triples directly, generating necessary metadata.
 */
  RdfGraph replaceInDocument({
    required IriTerm documentIri,
    required RdfGraph document,
    required MergeContract mergeContract,
    required int physicalClock,
    required Iterable<
            ({
              RdfSubject subject,
              IriTerm subjectTypeIri,
              RdfPredicate predicate,
              Set<RdfObject> newObjects,
            })>
        changes,
  }) {
    // Build updated document
    final updatedTriples = document.triples.toSet();

    for (final (
          subject: subject,
          subjectTypeIri: subjectTypeIri,
          predicate: predicate,
          newObjects: newObjects,
        ) in changes) {
      // Extract old shards
      final oldPredicateTriples = document.findTriples(
        subject: subject,
        predicate: predicate,
      );

      // If shards haven't changed, return original document
      final oldObjects = oldPredicateTriples.map((t) => t.object).toSet();
      if (SetEquality<RdfTerm>().equals(oldObjects, newObjects)) {
        break;
      }

      // Determine CRDT algorithm for idx:belongsToIndexShard
      final algorithmIri =
          mergeContract.getEffectiveMergeWith(subjectTypeIri, predicate);
      final crdtType = _crdtTypeRegistry.getType(algorithmIri);

      // Generate CRDT metadata for the shard change
      final metadata = crdtType.localValueChange(
        oldPropertyValue: oldPredicateTriples.isNotEmpty
            ? (
                documentIri: documentIri,
                appData:
                    document, // Using document as appData since shards are framework metadata
                // We are deliberately not supporting blank nodes here at the moment
                blankNodes: IdentifiedBlankNodes.empty<IriTerm>(),
                subject: subject,
                predicate: predicate,
                values: oldObjects,
              )
            : null,
        newPropertyValue: (
          documentIri: documentIri,
          appData: document,
          // We are deliberately not supporting blank nodes here at the moment
          blankNodes: IdentifiedBlankNodes.empty<IriTerm>(),
          subject: subject,
          predicate: predicate,
          values: newObjects,
        ),
        oldFrameworkGraph: document,
        mergeContext: CrdtMergeContext(
          iriGenerator: _iriGenerator,
          metadataGenerator: _metadataGenerator,
        ),
        physicalClock: physicalClock,
      );

      // Remove old shard triples
      oldPredicateTriples.forEach(updatedTriples.remove);

      // Add new shard triples
      updatedTriples
          .addAll(newObjects.map((obj) => Triple(subject, predicate, obj)));

      // Apply metadata changes
      for (final node in metadata.statementsToAdd) {
        updatedTriples
            .addNodes(documentIri, SyncManagedDocument.hasStatement, [node]);
      }
      for (final triple in metadata.triplesToRemove) {
        updatedTriples.remove(triple);
      }
    }

    return RdfGraph.fromTriples(updatedTriples);
  }

  Iterable<IdentifiedRdfSubject> _getIdentifiedSubjects(
          RdfGraph graph, IdentifiedBlankNodes<IriTerm> blankNodes) =>
      graph.subjects.map((subject) {
        if (subject is IriTerm) {
          return IdentifiedIriSubject(subject);
        } else if (subject is BlankNodeTerm) {
          if (blankNodes.hasIdentifiedNodes(subject)) {
            return IdentifiedBlankNodeSubject(
                subject, blankNodes.getIdentifiedNodes(subject));
          }
        }
        return null; // Unidentified blank node
      }).whereType<IdentifiedRdfSubject>();

  CrdtMetadataResult _generateCrdtMetadataForChanges(
      IriTerm documentIri,
      RdfGraph appData,
      IdentifiedBlankNodes<IriTerm> appBlankNodes,
      RdfGraph? oldAppGraph,
      RdfGraph? oldFrameworkGraph,
      IdentifiedBlankNodes<IriTerm> oldAppBlankNodes,
      MergeContract mergeContract,
      CurrentCrdtClock clock,
      {bool isFrameworkData = false,
      required IriTerm appDataTypeIri,
      IriTerm? ownClockEntryIri}) {
    final isShard = appDataTypeIri == IdxShard.classIri;
    final statements = <Node>[];
    final triplesToRemove = <Triple>{};
    final propertyChanges = <PropertyChange>[];

    // Tracks (resource, property) pairs that were modified locally and use
    // the LWW-Register CRDT, so we can emit a single consolidated
    // sync:PropertyClock per (resource, this-installation, save) instead
    // of one record per property. Only IRI subjects/predicates are
    // recorded — per-property tracking on blank-node subjects falls back
    // to the document-level concurrent tie-break.
    final lwwChangesByResource = <IriTerm, Set<IriTerm>>{};

    // Get all identifiable subjects from both graphs
    final identifiedSubjects =
        _getIdentifiedSubjects(appData, appBlankNodes).toSet();
    final oldIdentifiedSubjects = oldAppGraph == null
        ? const <IdentifiedRdfSubject>{}
        : _getIdentifiedSubjects(oldAppGraph, oldAppBlankNodes).toSet();

    // Partition subjects into added, deleted, and common
    final addedSubjects = identifiedSubjects.difference(oldIdentifiedSubjects);
    final deletedSubjects =
        oldIdentifiedSubjects.difference(identifiedSubjects);
    final commonSubjects = {
      for (final subject in identifiedSubjects)
        if (oldIdentifiedSubjects.contains(subject))
          subject: oldIdentifiedSubjects.lookup(subject)!
    };
    final context = CrdtMergeContext(
        iriGenerator: _iriGenerator, metadataGenerator: _metadataGenerator);

    // Process deleted subjects - add resource tombstones
    for (final deletedSubject in deletedSubjects) {
      _log.fine('Deleted subject detected: ${deletedSubject.subject.debug} ');
      statements.addAll(_metadataGenerator.createResourceMetadata(
          documentIri,
          IdTerm.create(deletedSubject.subject, oldAppBlankNodes),
          (metadataSubject) => [
                Triple(
                    metadataSubject,
                    SyncManagedDocument.crdtDeletedAt,
                    LiteralTermExtensions.dateTimeFromMillisecondsSinceEpoch(
                        clock.physicalTime))
              ]));
    }

    // Process added subjects - generate initial value metadata
    for (final addedSubject in addedSubjects) {
      final subjectTerm = addedSubject.subject;
      final subjectTriples = appData.matching(subject: subjectTerm);
      final predicates = subjectTriples.predicates;
      final isShardEntry = isShard &&
          predicates.contains(IdxShardEntry.resource) &&
          predicates.contains(IdxShardEntry.crdtClockHash);
      final resourceType =
          appData.findSingleObject<IriTerm>(subjectTerm, Rdf.type);

      for (final predicate in predicates) {
        final values =
            subjectTriples.getMultiValueObjectList(subjectTerm, predicate);

        final crdtType =
            _getCrdtType(isShardEntry, predicate, mergeContract, resourceType);

        // Generate initial value metadata
        final metadataGraph = crdtType.localValueChange(
            oldPropertyValue: null,
            newPropertyValue: (
              documentIri: documentIri,
              appData: appData,
              blankNodes: appBlankNodes,
              subject: subjectTerm,
              predicate: predicate,
              values: values,
            ),
            mergeContext: context,
            physicalClock: clock.physicalTime,
            oldFrameworkGraph: oldFrameworkGraph);

        statements.addAll(metadataGraph.statementsToAdd);
        triplesToRemove.addAll(metadataGraph.triplesToRemove);

        // Track LWW changes for per-property change clock emission.
        _recordLwwChange(lwwChangesByResource, crdtType, subjectTerm, predicate,
            ownClockEntryIri);

        // Record property change using canonical IRI (for identified blank nodes) or IRI
        for (final propertyChangeIri in addedSubject.propertyChangeIris) {
          propertyChanges.add(PropertyChange(
            resourceIri: propertyChangeIri,
            propertyIri: predicate,
            changedAtMs: clock.physicalTime,
            changeLogicalClock: clock.logicalTime,
            isFrameworkProperty: isFrameworkData,
          ));
        }
      }

      // Clean up stale subject-level tombstones for re-added subjects.
      // When a subject was previously deleted (tombstoned) and is now
      // re-added, the old tombstone must be removed — otherwise the
      // document ends up with both app data triples and a deletion
      // marker for the same subject, which crashes the remote merger.
      if (oldFrameworkGraph != null) {
        triplesToRemove.addAll(_findSubjectTombstonesToRemove(
          documentIri,
          IdTerm.create(addedSubject.subject, appBlankNodes).localSubjectIris,
          oldFrameworkGraph,
        ));
      }
    }

    // Process common subjects - detect changes and generate change metadata
    for (final entry in commonSubjects.entries) {
      final subjectTerm = entry.key.subject;
      final oldSubjectTerm = entry.value.subject;

      final newTriples = appData.matching(subject: subjectTerm);
      final oldTriples = oldAppGraph!.matching(subject: oldSubjectTerm);

      final newPropertiesByPredicate = newTriples.predicates;
      final oldPropertiesByPredicate = oldTriples.predicates;

      final resourceType =
          appData.findSingleObject<IriTerm>(subjectTerm, Rdf.type);
      final isShardEntry = isShard &&
          newPropertiesByPredicate.contains(IdxShardEntry.resource) &&
          newPropertiesByPredicate.contains(IdxShardEntry.crdtClockHash);

      // Get all predicates from both old and new
      final allPredicates = {
        ...newPropertiesByPredicate,
        ...oldPropertiesByPredicate
      };

      for (final predicate in allPredicates) {
        final newValues =
            newTriples.getMultiValueObjectList(subjectTerm, predicate);
        final oldValues =
            oldTriples.getMultiValueObjectList(oldSubjectTerm, predicate);

        // Check if values changed (considering blank node deep equality)
        if (_valuesEqual(oldValues, newValues, oldAppGraph, appData,
            oldAppBlankNodes, appBlankNodes)) {
          continue; // No change
        }

        // Get CRDT algorithm for this property
        final crdtType =
            _getCrdtType(isShardEntry, predicate, mergeContract, resourceType);

        // Generate change metadata
        final metadataGraph = crdtType.localValueChange(
          oldPropertyValue: (
            documentIri: documentIri,
            appData: oldAppGraph,
            blankNodes: oldAppBlankNodes,
            subject: oldSubjectTerm,
            predicate: predicate,
            values: oldValues,
          ),
          newPropertyValue: (
            documentIri: documentIri,
            appData: appData,
            blankNodes: appBlankNodes,
            subject: subjectTerm,
            predicate: predicate,
            values: newValues,
          ),
          mergeContext: context,
          physicalClock: clock.physicalTime,
          oldFrameworkGraph: oldFrameworkGraph,
        );

        statements.addAll(metadataGraph.statementsToAdd);
        triplesToRemove.addAll(metadataGraph.triplesToRemove);

        // Track LWW changes for per-property change clock emission.
        _recordLwwChange(lwwChangesByResource, crdtType, subjectTerm, predicate,
            ownClockEntryIri);

        // Record property change using canonical IRI (for identified blank nodes) or IRI
        for (final propertyChangeIri in entry.key.propertyChangeIris) {
          propertyChanges.add(PropertyChange(
            resourceIri: propertyChangeIri,
            propertyIri: predicate,
            changedAtMs: clock.physicalTime,
            changeLogicalClock: clock.logicalTime,
            isFrameworkProperty: isFrameworkData,
          ));
        }
        _log.fine(
            'Property change detected on ${subjectTerm.debug} for $predicate');
      }
    }

    // After all property changes are processed: emit per-property change
    // clocks (sync:PropertyClock) for this save. One record per (resource,
    // this-installation, this-save) consolidates all LWW properties changed
    // together. Also clean up overridden entries in pre-existing records
    // by this installation so the (resource, property, installation)
    // mapping remains 1:1.
    final propertyClockNodes = <Node>[];
    if (ownClockEntryIri != null && lwwChangesByResource.isNotEmpty) {
      _emitPropertyClocks(
        documentIri: documentIri,
        ownClockEntryIri: ownClockEntryIri,
        clock: clock,
        lwwChangesByResource: lwwChangesByResource,
        oldFrameworkGraph: oldFrameworkGraph,
        triplesToRemove: triplesToRemove,
        propertyClockNodes: propertyClockNodes,
      );
    }

    return CrdtMetadataResult(
      statements: statements,
      triplesToRemove: triplesToRemove,
      propertyChanges: propertyChanges,
      propertyClocks: propertyClockNodes,
    );
  }

  /// Records a (resource, predicate) pair when the change uses the
  /// LWW-Register CRDT. Per-property change clocks are only emitted for
  /// LWW properties — other CRDT types resolve concurrency via their own
  /// semantics (OR-Set additions, FWW first-write, etc.) and do not need
  /// the per-property HLC.
  void _recordLwwChange(
    Map<IriTerm, Set<IriTerm>> lwwChangesByResource,
    CrdtType crdtType,
    RdfSubject subjectTerm,
    RdfPredicate predicate,
    IriTerm? ownClockEntryIri,
  ) {
    if (ownClockEntryIri == null) return;
    if (crdtType.iri != Algo.LWW_Register) return;
    if (subjectTerm is! IriTerm || predicate is! IriTerm) return;
    lwwChangesByResource
        .putIfAbsent(subjectTerm, () => <IriTerm>{})
        .add(predicate);
  }

  /// Emits `sync:PropertyClock` records for the current save and removes
  /// overridden entries from pre-existing records by this installation.
  ///
  /// Per-(resource, this-installation) invariant: across all PropertyClock
  /// records on this document, each property appears under this
  /// installation in exactly one record (the most recent save that
  /// touched it). When a previous record is left with no properties for
  /// this installation, the entire record is removed.
  void _emitPropertyClocks({
    required IriTerm documentIri,
    required IriTerm ownClockEntryIri,
    required CurrentCrdtClock clock,
    required Map<IriTerm, Set<IriTerm>> lwwChangesByResource,
    required RdfGraph? oldFrameworkGraph,
    required Set<Triple> triplesToRemove,
    required List<Node> propertyClockNodes,
  }) {
    // Clean up overridden properties in existing PropertyClock records by
    // this installation. An "override" is a property already present in
    // changedProperty for (resource, ownClockEntryIri) that this save is
    // now changing again — its entry must move to the new record.
    if (oldFrameworkGraph != null) {
      final existing = parsePropertyClocks(documentIri, oldFrameworkGraph);
      for (final pc in existing) {
        if (pc.clockEntryIri != ownClockEntryIri) continue;
        final overridingProps = lwwChangesByResource[pc.resource];
        if (overridingProps == null) continue;
        final removed = pc.changedProperties.intersection(overridingProps);
        if (removed.isEmpty) continue;
        final remaining = pc.changedProperties.difference(overridingProps);
        if (remaining.isEmpty) {
          // No properties left → drop the entire record (and the doc-level
          // sync:hasPropertyClock pointer).
          triplesToRemove
              .addAll(oldFrameworkGraph.findTriples(subject: pc.clockIri));
          triplesToRemove.add(Triple(documentIri,
              SyncPropertyClock.hasPropertyClock, pc.clockIri));
        } else {
          // Remove only the overridden changedProperty triples.
          for (final p in removed) {
            triplesToRemove
                .add(Triple(pc.clockIri, SyncPropertyClock.changedProperty, p));
          }
        }
      }
    }

    // Emit one new PropertyClock per resource for this save.
    for (final entry in lwwChangesByResource.entries) {
      final resource = entry.key;
      final props = entry.value;
      if (props.isEmpty) continue;
      // Deterministic IRI: hash of (resource, installation clock entry,
      // logical time) using a stable blank-node label. Different
      // installations / different saves yield different IRIs. Same data →
      // same IRI on every node, so the remote merger naturally dedupes.
      final self = BlankNodeTerm();
      final clockIri = _iriGenerator.generateSimpleCanonicalIri(
        documentIri,
        'pc',
        [
          Triple(self, SyncPropertyClock.resource, resource),
          Triple(self, CrdtClockEntry.hasClockEntry, ownClockEntryIri),
          Triple(self, CrdtClockEntry.logicalTime,
              LiteralTerm.integer(clock.logicalTime)),
        ],
        labels: {self: 'self'},
      );
      final pc = PropertyClock(
        clockIri: clockIri,
        resource: resource,
        clockEntryIri: ownClockEntryIri,
        logicalTime: clock.logicalTime,
        physicalTime: clock.physicalTime,
        changedProperties: props,
      );
      // Build the Node: subject = clockIri, graph = pc triples (excluding
      // the document-level `<doc> sync:hasPropertyClock <pc>` pointer,
      // which the caller adds via addNodes()).
      final pcGraphTriples =
          pc.toTriples(documentIri).where((t) => t.subject == clockIri);
      propertyClockNodes
          .add((clockIri, RdfGraph.fromTriples(pcGraphTriples.toList())));
    }
  }

  /// Get CRDT algorithm for this property - but note
  /// that in index entries we always use LWW-Register for the user-defined
  /// "header" properties.
  CrdtType _getCrdtType(bool isShardEntry, RdfPredicate predicate,
      MergeContract mergeContract, IriTerm? resourceType) {
    return isShardEntry && !isShardEntryStructuralPredicate(predicate)
        ? _crdtTypeRegistry.getType(Algo.LWW_Register)
        : _getCrdtAlgorithm(mergeContract, resourceType, predicate);
  }

  CrdtType _getCrdtAlgorithm(MergeContract mergeContract, IriTerm? resourceType,
      RdfPredicate predicate) {
    // Get CRDT algorithm for this property
    final algorithmIri =
        mergeContract.getEffectiveMergeWith(resourceType, predicate);
    return _crdtTypeRegistry.getType(algorithmIri);
  }

  /// Check if two value lists are equal, considering deep equality for blank nodes
  bool _valuesEqual(
      List<RdfTerm> oldValues,
      List<RdfTerm> newValues,
      RdfGraph oldGraph,
      RdfGraph newGraph,
      IdentifiedBlankNodes<IriTerm> oldBlankNodes,
      IdentifiedBlankNodes<IriTerm> newBlankNodes) {
    if (oldValues.length != newValues.length) {
      return false;
    }

    // For each old value, try to find a matching new value
    final matchedNewValues = <RdfTerm>{};

    for (final oldValue in oldValues) {
      bool found = false;

      for (final newValue in newValues) {
        if (matchedNewValues.contains(newValue)) {
          continue; // Already matched to another old value
        }

        if (_valueEquals(oldValue, newValue, oldGraph, newGraph, oldBlankNodes,
            newBlankNodes)) {
          matchedNewValues.add(newValue);
          found = true;
          break;
        }
      }

      if (!found) {
        return false; // Old value has no match in new values
      }
    }

    return true;
  }

  /// Check if two RDF values are equal, considering deep equality for blank nodes
  bool _valueEquals(
      RdfTerm oldValue,
      RdfTerm newValue,
      RdfGraph oldGraph,
      RdfGraph newGraph,
      IdentifiedBlankNodes<IriTerm> oldBlankNodes,
      IdentifiedBlankNodes<IriTerm> newBlankNodes) {
    // Simple case: same term
    if (oldValue == newValue) {
      return true;
    }

    // For blank nodes, check if they're identified and equal
    if (oldValue is BlankNodeTerm && newValue is BlankNodeTerm) {
      final oldIdentifiers = oldBlankNodes.hasIdentifiedNodes(oldValue)
          ? oldBlankNodes.getIdentifiedNodes(oldValue)
          : null;
      final newIdentifiers = newBlankNodes.hasIdentifiedNodes(newValue)
          ? newBlankNodes.getIdentifiedNodes(newValue)
          : null;

      // If both are identified, check if they share any identifier
      if (oldIdentifiers != null && newIdentifiers != null) {
        if (oldIdentifiers.any((oldId) => newIdentifiers.contains(oldId))) {
          return true; // Identified as the same blank node
        }
      }

      // For non-identified blank nodes, do deep structural comparison
      return _deepBlankNodeEquals(
          oldValue, newValue, oldGraph, newGraph, oldBlankNodes, newBlankNodes);
    }

    return false;
  }

  /// Perform deep structural comparison of blank nodes
  bool _deepBlankNodeEquals(
      BlankNodeTerm oldBlankNode,
      BlankNodeTerm newBlankNode,
      RdfGraph oldGraph,
      RdfGraph newGraph,
      IdentifiedBlankNodes<IriTerm> oldBlankNodes,
      IdentifiedBlankNodes<IriTerm> newBlankNodes,
      [Set<BlankNodeTerm>? visited]) {
    visited ??= {};

    // Prevent infinite recursion
    if (visited.contains(oldBlankNode)) {
      return true; // Assume equal if we're in a cycle
    }
    visited.add(oldBlankNode);

    final oldTriples = oldGraph.matching(subject: oldBlankNode);
    final newTriples = newGraph.matching(subject: newBlankNode);

    final oldProps = oldTriples.predicates;
    final newProps = newTriples.predicates;

    // Must have same predicates
    if (!_isEqualSet(oldProps, newProps)) {
      return false;
    }

    // Check each predicate's values
    for (final predicate in oldProps) {
      final oldValues =
          oldGraph.getMultiValueObjectList(oldBlankNode, predicate);
      final newValues =
          newGraph.getMultiValueObjectList(newBlankNode, predicate);

      if (!_valuesEqual(oldValues, newValues, oldGraph, newGraph, oldBlankNodes,
          newBlankNodes)) {
        return false;
      }
    }

    return true;
  }
}

bool _isEqualSet<T>(Set<T> set, Set<T> set2) =>
    SetEquality<T>().equals(set, set2);

/// Finds subject-level tombstone reifications to remove for re-added subjects.
///
/// When a subject is deleted, a statement reification with only `rdf:subject`
/// (no `rdf:predicate`) and `crdt:deletedAt` is created. If the subject is
/// later re-added, this stale tombstone must be removed to avoid the
/// "exists is true but statement is tombstoned" inconsistency during merge.
Iterable<Triple> _findSubjectTombstonesToRemove(
  IriTerm documentIri,
  Iterable<RdfSubject> subjects,
  RdfGraph frameworkGraph,
) {
  // Find all statement reifications whose rdf:subject matches any of the
  // re-added subject IRIs.
  final candidateStmtNodes = frameworkGraph
      .findTriples(predicate: RdfStatement.subject, objectIn: subjects)
      .map((t) => t.subject)
      .toSet();

  // Keep only those that are subject-level (no rdf:predicate) and tombstoned.
  return candidateStmtNodes
      .where((node) =>
          !frameworkGraph.hasTriples(
              subject: node, predicate: RdfStatement.predicate) &&
          frameworkGraph.hasTriples(
              subject: node, predicate: SyncManagedDocument.crdtDeletedAt))
      .expand((node) => [
            // Remove the hasStatement link from the document
            Triple(documentIri, SyncManagedDocument.hasStatement, node),
            // Remove all triples of the tombstone reification itself
            ...frameworkGraph.findTriples(subject: node),
          ]);
}

/// Result of CRDT metadata generation containing metadata triples and property changes
class CrdtMetadataResult {
  final List<Node> statements;

  /// Per-property change clock records (`sync:PropertyClock`) generated
  /// for LWW-Register properties touched during this save. Linked to the
  /// document via `sync:hasPropertyClock`.
  final List<Node> propertyClocks;

  final Set<Triple> triplesToRemove;
  final List<PropertyChange> propertyChanges;

  CrdtMetadataResult({
    required this.statements,
    required this.triplesToRemove,
    required this.propertyChanges,
    this.propertyClocks = const [],
  });
}
