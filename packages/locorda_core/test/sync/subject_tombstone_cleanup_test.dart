import 'package:locorda_core/src/crdt/crdt_types.dart';
import 'package:locorda_core/src/hlc_service.dart' show CurrentCrdtClock;
import 'package:locorda_core/src/local_document_merger.dart';
import 'package:locorda_core/src/mapping/framework_iri_generator.dart';
import 'package:locorda_core/src/mapping/merge_contract.dart';
import 'package:locorda_core/src/vocab/generated/_index.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:test/test.dart';

import '../util/setup_logging.dart';

void main() {
  group('MergeObjectState.from', () {
    test('returns present when exists is true and no statement', () {
      expect(MergeObjectState.from(null, true), MergeObjectState.present);
    });

    test('returns tombstoned when exists is false and statement is tombstoned',
        () {
      final statement = MetadataStatement(
        MetadataStatementKey.fromSubject(IriTerm('urn:s')),
        {SyncManagedDocument.crdtDeletedAt: [LiteralTerm.string('2024')]},
        {},
      );
      expect(MergeObjectState.from(statement, false),
          MergeObjectState.tombstoned);
    });

    test('returns unknown when exists is false and no statement', () {
      expect(MergeObjectState.from(null, false), MergeObjectState.unknown);
    });

    test(
        'returns present (add-wins) when exists is true but statement is tombstoned',
        () {
      setupTestLogging();
      // This is the scenario that previously threw a StateError.
      // With add-wins semantics, a subject that exists but has a stale
      // tombstone should be treated as present.
      final statement = MetadataStatement(
        MetadataStatementKey.fromSubject(IriTerm('urn:s')),
        {SyncManagedDocument.crdtDeletedAt: [LiteralTerm.string('2024')]},
        {},
      );
      expect(MergeObjectState.from(statement, true), MergeObjectState.present);
    });
  });

  group('Subject-level tombstone cleanup', () {
    late LocalDocumentMerger merger;
    late FrameworkIriGenerator iriGenerator;
    late CrdtTypeRegistry crdtTypeRegistry;

    setUp(() {
      setupTestLogging();
      crdtTypeRegistry = CrdtTypeRegistry.forStandardTypes();
      iriGenerator = FrameworkIriGenerator();
      merger = LocalDocumentMerger(
        frameworkIriGenerator: iriGenerator,
        crdtTypeRegistry: crdtTypeRegistry,
      );
    });

    test('removes stale subject-level tombstone when subject is re-added', () {
      final docIri = IriTerm('tag:locorda.org,2025:l:dHlwZQ:ZG9j');
      final subjectIri =
          IriTerm('tag:locorda.org,2025:l:dHlwZQ:ZG9j#entry1');
      final nameIri = IriTerm('https://schema.org/name');
      final typeIri = IriTerm('https://example.org/Entry');

      // Merge contract with LWW for schema:name
      final mergeContract = MergeContract(
        {
          typeIri: ClassMergeRules(
            typeIri,
            {
              nameIri: PredicateMergeRule(
                predicateIri: nameIri,
                mergeWith: Algo.LWW_Register,
              ),
            },
          ),
        },
        {},
      );

      // Old app data: subject existed before deletion
      final oldAppData = RdfGraph(triples: [
        Triple(subjectIri, Rdf.type, typeIri),
        Triple(subjectIri, nameIri, LiteralTerm.string('Hello')),
      ]);

      // Generate metadata for initial state (subject exists)
      final initialResult = merger.generateMetadata(
        docIri,
        oldAppData,
        null, // no old data = subject is "added"
        null, // no old framework graph
        mergeContract,
        _testClock(1000),
        appDataTypeIri: typeIri,
        computeCanonicalBlankNodes: false,
      );

      // Build a framework graph that includes the initial metadata
      final initialFrameworkTriples = <Triple>[];
      for (final stmt in initialResult.metadata.statements) {
        initialFrameworkTriples.add(
            Triple(docIri, SyncManagedDocument.hasStatement, stmt.$1));
        initialFrameworkTriples.addAll(stmt.$2.triples);
      }
      final initialFrameworkGraph =
          RdfGraph(triples: initialFrameworkTriples);

      // Now simulate deletion: subject removed from app data
      final emptyAppData = RdfGraph(triples: []);

      final deleteResult = merger.generateMetadata(
        docIri,
        emptyAppData,
        oldAppData,
        initialFrameworkGraph,
        mergeContract,
        _testClock(2000),
        appDataTypeIri: typeIri,
        computeCanonicalBlankNodes: false,
      );

      // Build framework graph with deletion tombstones added
      final afterDeleteTriples = initialFrameworkGraph.triples.toList()
        ..addAll(deleteResult.metadata.statements.expand((stmt) => [
              Triple(docIri, SyncManagedDocument.hasStatement, stmt.$1),
              ...stmt.$2.triples,
            ]));
      // Remove what was marked for removal
      final removeSet = deleteResult.metadata.triplesToRemove.toSet();
      afterDeleteTriples.removeWhere((t) => removeSet.contains(t));
      final afterDeleteFrameworkGraph =
          RdfGraph(triples: afterDeleteTriples);

      // Verify tombstone exists: there should be a statement with
      // crdtDeletedAt and rdf:subject pointing to our subject
      final tombstoneNodes = afterDeleteFrameworkGraph
          .findTriples(
              predicate: RdfStatement.subject, object: subjectIri)
          .map((t) => t.subject)
          .where((node) => afterDeleteFrameworkGraph.hasTriples(
              subject: node, predicate: SyncManagedDocument.crdtDeletedAt))
          .toList();
      expect(tombstoneNodes, isNotEmpty,
          reason: 'Should have a subject-level tombstone after deletion');

      // Now re-add the subject (simulates the subject coming back)
      final reAddedAppData = RdfGraph(triples: [
        Triple(subjectIri, Rdf.type, typeIri),
        Triple(subjectIri, nameIri, LiteralTerm.string('World')),
      ]);

      final reAddResult = merger.generateMetadata(
        docIri,
        reAddedAppData,
        emptyAppData,
        afterDeleteFrameworkGraph,
        mergeContract,
        _testClock(3000),
        appDataTypeIri: typeIri,
        computeCanonicalBlankNodes: false,
      );

      // The triplesToRemove should include the old subject-level
      // tombstone triples so they get cleaned up
      final removedTriples = reAddResult.metadata.triplesToRemove.toList();

      // The tombstone's crdtDeletedAt triple should be in triplesToRemove
      final removedDeletedAtTriples = removedTriples.where((t) =>
          t.predicate == SyncManagedDocument.crdtDeletedAt);
      expect(removedDeletedAtTriples, isNotEmpty,
          reason:
              'Re-adding a subject should remove the stale subject-level tombstone');

      // The hasStatement link to the tombstone should also be removed
      final removedHasStmtTriples = removedTriples.where((t) =>
          t.subject == docIri &&
          t.predicate == SyncManagedDocument.hasStatement);
      expect(removedHasStmtTriples, isNotEmpty,
          reason:
              'Re-adding a subject should remove the hasStatement link to the tombstone');
    });
  });
}

CurrentCrdtClock _testClock(int physicalTime) => (
      logicalTime: 1,
      physicalTime: physicalTime,
      fullClock: [],
      hash: 'test-hash',
    );
