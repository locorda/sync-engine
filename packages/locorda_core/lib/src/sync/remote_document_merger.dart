import 'package:locorda_core/src/crdt/crdt_types.dart';
import 'package:locorda_core/src/vocab/generated/_index.dart';
import 'package:locorda_core/src/hlc_service.dart';
import 'package:locorda_core/src/mapping/framework_iri_generator.dart';
import 'package:locorda_core/src/mapping/identified_blank_node_builder.dart';
import 'package:locorda_core/src/mapping/merge_contract.dart';
import 'package:locorda_core/src/mapping/metadata_generator.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/storage/storage_interface.dart';
import 'package:locorda_core/src/sync/data_types.dart';
import 'package:logging/logging.dart';
import 'package:locorda_rdf_core/core.dart';

final _log = Logger('RemoteDocumentMerger');

/// Result of merging local and remote document states.
class MergeResult {
  /// The merged document (may be same as local if remote had no new changes).
  final RdfGraph mergedGraph;

  MergeResult({
    required this.mergedGraph,
  });
}

/// Handles CRDT-based merging of local and remote document states.
///
/// Implements property-level CRDT merge following the specification in
/// CRDT-SPECIFICATION.md Section 5 (Merge Process Details).
class RemoteDocumentMerger {
  // Storage will be needed for property change history during actual merge
  // ignore: unused_field
  final Storage _storage;
  final HlcService _hlcService;

  final CrdtTypeRegistry _crdtTypeRegistry;
  final FrameworkIriGenerator _iriGenerator;

  late final IdentifiedBlankNodeBuilder _identifiedBlankNodeBuilder =
      IdentifiedBlankNodeBuilder(iriGenerator: _iriGenerator);

  late final MetadataGenerator _metadataGenerator =
      MetadataGenerator(frameworkIriGenerator: _iriGenerator);

  RemoteDocumentMerger({
    required Storage storage,
    required HlcService hlcService,
    required CrdtTypeRegistry crdtTypeRegistry,
    required FrameworkIriGenerator frameworkIriGenerator,
  })  : _storage = storage,
        _hlcService = hlcService,
        _crdtTypeRegistry = crdtTypeRegistry,
        _iriGenerator = frameworkIriGenerator;

  /// Merge local document with remote version using CRDT rules.
  ///
  /// Implements the merge algorithm from CRDT-SPECIFICATION.md Section 5:
  /// 1. Identify Statement and Clock subjects (framework metadata)
  /// 2. Merge Clocks (max of logical/physical times + increment own installation)
  /// 3. Organize Statements for efficient lookup during property merge
  /// 4. Iterate over all subjects (except Statement/Clock subjects)
  /// 5. For each subject, iterate over properties and merge using CRDT algorithms
  /// 6. Property merge returns merged values AND merged statements (tombstones)
  /// 7. Build result document with merged triples, statements, and merged clock
  ///
  /// Parameters:
  /// - [mergeContract]: Contract defining CRDT algorithms per property
  /// - [documentIri]: The document being synchronized
  /// - [localGraph]: Current local state (may be null if new from remote)
  /// - [remoteGraph]: Remote state (may be null if deleted remotely)
  ///
  /// Returns: Merge result indicating merged state and sync direction.
  MergeResult merge({
    required MergeContract mergeContract,
    required IriTerm documentIri,
    required RdfGraph? localGraph,
    required RdfGraph? remoteGraph,
  }) {
    _log.fine('Merging document ${documentIri.debug}');

    // Handle null cases
    if (remoteGraph == null) {
      _log.fine('Remote is null - keeping local');
      return MergeResult(
        mergedGraph: localGraph!,
      );
    }

    if (localGraph == null) {
      _log.fine('Local is null - accepting remote');
      return MergeResult(
        mergedGraph: remoteGraph,
      );
    }

    // Organize the graphs
    final localOGraph =
        OrganizedGraph.fromGraph(documentIri, localGraph, _hlcService);
    final remoteOGraph =
        OrganizedGraph.fromGraph(documentIri, remoteGraph, _hlcService);
    final clockComparison =
        ClockComparison.compareClocks(localOGraph, remoteOGraph);
    final resourceIri = localOGraph.fullGraph.findSingleObject<IriTerm>(
            documentIri, SyncManagedDocument.foafPrimaryTopic) ??
        remoteOGraph.fullGraph.findSingleObject<IriTerm>(
            documentIri, SyncManagedDocument.foafPrimaryTopic)!;
    final types = {
      ...localOGraph.fullGraph
          .getMultiValueObjects<IriTerm>(resourceIri, Rdf.type),
      ...remoteOGraph.fullGraph
          .getMultiValueObjects<IriTerm>(resourceIri, Rdf.type),
    };
    final resourceTypeIri = types.length == 1
        ? types.first
        : ({...types}.toList()..sort((a, b) => a.value.compareTo(b.value)))
            .first;
    // Step 4-7: Iterate subjects, merge properties per CRDT type
    final mergeResults = _mergeSubjectsAndProperties(
        documentIri,
        localOGraph,
        remoteOGraph,
        mergeContract,
        RemoteCrdtMergeContext(clockComparison: clockComparison),
        appDataTypeIri: resourceTypeIri);

    _log.fine('Merged ${mergeResults.mergedTriples.length} triples ');

    // Step 8: Build final result document
    final result = _buildResultDocument(
      documentIri: documentIri,
      mergeResults: mergeResults,
      localGraph: localGraph,
      remoteGraph: remoteGraph,
      mergeContract: mergeContract,
    );

    return result;
  }

  /// Merges all subjects and their properties using CRDT algorithms.
  ///
  /// For each subject (excluding clock and statement subjects):
  /// 1. Compute identified blank nodes for both graphs
  /// 2. Get all properties on the subject
  /// 3. For each property, call appropriate CRDT merge algorithm
  /// 4. Collect merged values and statements
  ///
  /// Returns merged triples and metadata about the merge.
  MergeResults _mergeSubjectsAndProperties(
      IriTerm documentIri,
      OrganizedGraph localGraph,
      OrganizedGraph remoteGraph,
      MergeContract mergeContract,
      RemoteCrdtMergeContext mergeContext,
      {required IriTerm appDataTypeIri}) {
    final isShard = appDataTypeIri == IdxShard.classIri;
    final mergedSubjects =
        MergeSubject.createMergeSubjects(localGraph, remoteGraph)
            .map((subject) => _mergeSubject(
                  documentIri,
                  subject,
                  localGraph,
                  remoteGraph,
                  mergeContract,
                  mergeContext,
                  isShard: isShard,
                ));

    return MergeResults.join(mergedSubjects);
  }

  MergeResults _mergeSubject(
      IriTerm documentIri,
      MergeSubject subject,
      OrganizedGraph localGraph,
      OrganizedGraph remoteGraph,
      MergeContract mergeContract,
      RemoteCrdtMergeContext mergeContext,
      {required bool isShard}) {
    /*
        ok, another conceptual hurdle: unidentified blank nodes should "survive" 
        only if the reference to them survives - else we will end up with dangling blank nodes.
        So how should we handle them here?
        */
    if (subject.type == MergeSubjectType.blankNodeIdentifier ||
        subject.type == MergeSubjectType.statement) {
      // Skip blank node identifier and statement subjects - they need to be handled
      // differently (as part of property merges).
      // Note though, that the clock entries will be merged here like all other subjects
      return MergeResults.empty();
    }
    if (subject.localKey is UnIdentifiedBlankNodeKey ||
        subject.remoteKey is UnIdentifiedBlankNodeKey) {
      final inconsistentLocal = subject.localKey is! UnIdentifiedBlankNodeKey &&
          subject.localKey != null;
      final inconsistentRemote =
          subject.remoteKey is! UnIdentifiedBlankNodeKey &&
              subject.remoteKey != null;
      if (inconsistentLocal || inconsistentRemote) {
        throw StateError(
            'Cannot merge unidentified blank node subject with identified reference on one side. Subject: $subject');
      }

      // Cannot merge unidentified blank nodes at subject level - they must be handled as part of property merges.
      return MergeResults.empty();
    }
    final localStatement = localGraph.getStatementForKey(subject.localKey);
    final remoteStatement = remoteGraph.getStatementForKey(subject.remoteKey);

    final localExists = subject.local != null;
    final remoteExists = subject.remote != null;

    final mergeInstructions = computeMergeInstructions(
      mergeContext.clockComparison,
      localStatement,
      localExists,
      localGraph,
      remoteStatement,
      remoteExists,
      remoteGraph,
    );

    switch (mergeInstructions) {
      case MergeInstruction.keepLocal:
        return MergeResults.subjectFromGraph(localGraph, subject.localKey!);
      case MergeInstruction.keepRemote:
        return MergeResults.subjectFromGraph(remoteGraph, subject.remoteKey!);
      case MergeInstruction.mergeRequired:
        return _mergeSubjectProperties(
            subject, localGraph, remoteGraph, mergeContract, mergeContext,
            isShard: isShard);
      case MergeInstruction.none:
        // Does not exist on either side - nothing to merge (should not happen)
        return MergeResults.empty();
    }
  }

  MergeResults _mergeSubjectProperties(
      MergeSubject subject,
      OrganizedGraph localGraph,
      OrganizedGraph remoteGraph,
      MergeContract mergeContract,
      RemoteCrdtMergeContext mergeContext,
      {required bool isShard}) {
    // Get all properties for this subject from both graphs
    final allPredicates = <RdfPredicate>{
      if (subject.local != null)
        ...localGraph.fullGraph.matching(subject: subject.local).predicates,
      if (subject.remote != null)
        ...remoteGraph.fullGraph.matching(subject: subject.remote).predicates,
    };
    final isShardEntry = isShard &&
        allPredicates.contains(IdxShardEntry.resource) &&
        allPredicates.contains(IdxShardEntry.crdtClockHash);
    // In the end: the type itself is merged as a property like any other, so
    // this is only for determining the CRDT algorithm to use per property.
    // We ensure to be deterministic by sorting and picking the first type IRI from the merged set.
    final localTypeIris = _getTypes(subject.local, localGraph);
    final remoteTypeIris = _getTypes(subject.remote, remoteGraph);
    final typeIri = ({...localTypeIris, ...remoteTypeIris}.toList()
          ..sort((a, b) => a.value.compareTo(b.value)))
        .firstOrNull;

    // Merge each property individually
    final predicateMergeResults = <MergeResults>[];
    for (final predicate in allPredicates) {
      final IriTerm? algorithmIri = isShardEntry &&
              predicate != IdxShardEntry.resource &&
              predicate != IdxShardEntry.crdtClockHash
          ? Algo.LWW_Register
          : mergeContract.getEffectiveMergeWith(typeIri, predicate);

      final type = _crdtTypeRegistry.getType(algorithmIri);
      final result = type.remoteMerge(
          subject: subject,
          predicate: predicate,
          local: localGraph,
          remote: remoteGraph,
          mergeContext: mergeContext);
      if (result != null) {
        predicateMergeResults.add(result);
      }
    }
    return MergeResults.join(predicateMergeResults);
  }

  Set<IriTerm> _getTypes(RdfSubject? subject, OrganizedGraph graph) {
    return subject == null
        ? const {}
        : graph.fullGraph.getMultiValueObjects<IriTerm>(subject, Rdf.type);
  }

  /// Builds the final merged document with clock, data, and statements.
  ///
  /// Per CRDT spec Section 2.3:
  /// - Increments own installation's logical time in merged clock
  /// - Combines merged triples, statements, and clock
  /// - Determines if local or remote had changes (for sync decisions)
  ///
  /// Returns complete MergeResult ready for storage or transmission.
  MergeResult _buildResultDocument({
    required IriTerm documentIri,
    required MergeResults mergeResults,
    required RdfGraph localGraph,
    required RdfGraph remoteGraph,
    required MergeContract mergeContract,
  }) {
    final allTriples = <Triple>{
      ...mergeResults.mergedTriples
          // filter out old clock hash triples - clock hash will be recomputed
          // and appended below
          .where((t) => !(t.subject == documentIri &&
              t.predicate ==
                  SyncManagedDocument
                      .crdtClockHash)), // Exclude old clock entries
    };

    final preliminaryGraph = RdfGraph.fromTriples(allTriples);
    final identifiedBlankNodes =
        _identifiedBlankNodeBuilder.computeCanonicalBlankNodes(
            documentIri, preliminaryGraph, mergeContract);
    final identifiedBlankNodeTriples = identifiedBlankNodes
        .identifiedMap.entries
        .expand((e) => e.value.expand((canonicalIri) => [
              Triple(documentIri, SyncManagedDocument.hasBlankNodeMapping,
                  canonicalIri),
              Triple(canonicalIri, SyncBlankNodeMapping.blankNode, e.key)
            ]));

    // Add statement reification triples
    final statementTriples = mergeResults.mergedStatements.values
        .map((stmt) => switch (stmt.key) {
              SubjectMetadataStatement(subject: final subject) =>
                _metadataGenerator.createResourceMetadata(
                    documentIri,
                    IdTerm.create(subject, identifiedBlankNodes),
                    (subject) =>
                        _convertToTriples(stmt, identifiedBlankNodes, subject)),
              SubjectPredicateMetadataStatement(
                subject: final subject,
                predicate: final predicate
              ) =>
                _metadataGenerator.createPropertyMetadata(
                    documentIri,
                    IdTerm.create(subject, identifiedBlankNodes),
                    predicate,
                    (subject) =>
                        _convertToTriples(stmt, identifiedBlankNodes, subject)),
              TripleMetadataStatement(
                subject: final subject,
                predicate: final predicate,
                object: final object
              ) =>
                _metadataGenerator.createPropertyValueMetadata(
                  documentIri,
                  IdTerm.create(subject, identifiedBlankNodes),
                  predicate,
                  IdTerm.create(object, identifiedBlankNodes),
                  (subject) =>
                      _convertToTriples(stmt, identifiedBlankNodes, subject),
                ),
            })
        .expand((nodes) => nodes.expand((n) => [
              Triple(documentIri, SyncManagedDocument.hasStatement, n.$1),
              ...n.$2.triples
            ]));

    final mergedClock =
        _hlcService.getCurrentClock(preliminaryGraph, documentIri);

    // Materialize statement triples so we can inspect which statement IRIs
    // are already covered by property-level CRDT merges.
    final statementTriplesList = statementTriples.toList();

    // Preserve tombstone detail triples whose owning property was deleted on
    // both sides.  Property-level CRDT merges only run for predicates still
    // present on at least one side, so tombstone statements referencing a
    // fully-deleted property are never collected in mergedStatements.  Their
    // sync:hasStatement *references* survive (the OR-Set merge keeps the IRI
    // values), but the rdf:subject / rdf:predicate / rdf:object / cm:deletedAt
    // detail triples on the statement subject would be lost without this step.
    final coveredStatementIris = statementTriplesList
        .where((t) =>
            t.subject == documentIri &&
            t.predicate == SyncManagedDocument.hasStatement)
        .map((t) => t.object)
        .toSet();
    final referencedStatementIris = allTriples
        .where((t) =>
            t.subject == documentIri &&
            t.predicate == SyncManagedDocument.hasStatement)
        .map((t) => t.object)
        .whereType<RdfSubject>()
        .toSet();
    final uncoveredIris =
        referencedStatementIris.difference(coveredStatementIris);
    final orphanedStatementTriples = <Triple>[];
    final irrecoverableStatementIris = <RdfSubject>{};
    for (final stmtIri in uncoveredIris) {
      final detailTriples = <Triple>{
        ...localGraph.findTriples(subject: stmtIri),
        ...remoteGraph.findTriples(subject: stmtIri),
      };
      if (detailTriples.any((t) => t.predicate == RdfStatement.subject)) {
        // Recoverable: detail triples exist in at least one side
        orphanedStatementTriples.addAll(detailTriples);
      } else {
        // Irrecoverable: neither side has the rdf:subject detail triple.
        // Self-heal by dropping the dangling hasStatement reference.
        irrecoverableStatementIris.add(stmtIri);
        _log.severe('Self-healing: removing orphaned statement reference '
            '${stmtIri.debug} from document ${documentIri.debug} '
            '(detail triples missing on both sides)');
      }
    }

    // Remove dangling hasStatement references from the preliminary triples
    // so they don't persist across sync cycles.
    if (irrecoverableStatementIris.isNotEmpty) {
      allTriples.removeWhere((t) =>
          t.subject == documentIri &&
          t.predicate == SyncManagedDocument.hasStatement &&
          irrecoverableStatementIris.contains(t.object));
    }

    final mergedGraph = RdfGraph.fromTriples(allTriples).withTriples([
      Triple(documentIri, SyncManagedDocument.crdtClockHash,
          LiteralTerm(mergedClock.hash)),
      ...identifiedBlankNodeTriples,
      ...statementTriplesList,
      ...orphanedStatementTriples,
    ]);

    return MergeResult(
      mergedGraph: mergedGraph,
    );
  }

  Iterable<Triple> _convertToTriples(
    MetadataStatement stmt,
    IdentifiedBlankNodes<IriTerm> identifiedBlankNodes,
    RdfSubject subject,
  ) {
    return stmt.predicateObjectMap.entries.expand((e) => e.value
        .expand<RdfObject>((v) => switch (v) {
              IriTerm() || LiteralTerm() => [v],
              final BlankNodeTerm bnode =>
                identifiedBlankNodes.getCanonicalIris(bnode)
            })
        .map((v) => Triple(
              subject,
              e.key,
              v,
            )));
  }
}
