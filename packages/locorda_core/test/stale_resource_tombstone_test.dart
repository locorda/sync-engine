import 'package:locorda_core/src/crdt_document_manager.dart';
import 'package:locorda_core/src/vocab/generated/_index.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:test/test.dart';

/// Unit tests for [removeStaleResourceTombstones].
///
/// Verifies that resource tombstones for subjects still present in [appData]
/// are purged, while property-level tombstones and tombstones for absent
/// subjects are preserved.
void main() {
  final docIri = IriTerm.validated('https://example.org/doc/note-1');
  final appSubjectIri =
      IriTerm.validated('https://example.org/doc/note-1#note');
  final otherSubjectIri =
      IriTerm.validated('https://example.org/doc/note-1#other');
  final stmtIri =
      IriTerm.validated('https://example.org/doc/note-1#lcrd-stmt-dead');
  final stmtIri2 =
      IriTerm.validated('https://example.org/doc/note-1#lcrd-stmt-prop');

  // A minimal datetime literal; exact value does not matter for these tests.
  final deletedAtLiteral = LiteralTerm.typed(
      '2026-04-20T08:01:58Z', 'http://www.w3.org/2001/XMLSchema#dateTime');

  RdfGraph buildFrameworkGraphWithResourceTombstone() {
    return RdfGraph.fromTriples([
      // Document links to statement node
      Triple(docIri, SyncManagedDocument.hasStatement, stmtIri),
      // Statement is a resource tombstone: rdf:subject present, no rdf:predicate
      Triple(stmtIri, RdfStatement.subject, appSubjectIri),
      Triple(stmtIri, RdfStatement.crdtDeletedAt, deletedAtLiteral),
    ]);
  }

  group('removeStaleResourceTombstones', () {
    test('removes resource tombstone for a subject that is still live', () {
      final old = buildFrameworkGraphWithResourceTombstone();

      final result =
          removeStaleResourceTombstones(docIri, old, {appSubjectIri});

      expect(result, isNotNull);
      // hasStatement link removed
      expect(
        result!.findTriples(
            subject: docIri,
            predicate: SyncManagedDocument.hasStatement,
            object: stmtIri),
        isEmpty,
      );
      // Statement's own triples removed
      expect(result.findTriples(subject: stmtIri), isEmpty);
    });

    test('preserves resource tombstone when subject is NOT live', () {
      final old = buildFrameworkGraphWithResourceTombstone();

      final result = removeStaleResourceTombstones(
          docIri, old, {otherSubjectIri}); // different live subject

      expect(result, same(old)); // no changes → same instance
      expect(result!.findTriples(subject: stmtIri), isNotEmpty);
    });

    test('preserves property-level tombstone even when subject is live', () {
      final propertyIri = IriTerm.validated('https://schema.org/name');
      final oldWithPropertyTombstone = RdfGraph.fromTriples([
        Triple(docIri, SyncManagedDocument.hasStatement, stmtIri2),
        Triple(stmtIri2, RdfStatement.subject, appSubjectIri),
        Triple(
            stmtIri2, RdfStatement.predicate, propertyIri), // ← has predicate
        Triple(stmtIri2, RdfStatement.crdtDeletedAt, deletedAtLiteral),
      ]);

      final result = removeStaleResourceTombstones(
          docIri, oldWithPropertyTombstone, {appSubjectIri});

      // Property tombstone must survive: only resource-level ones are purged
      expect(result!.findTriples(subject: stmtIri2), isNotEmpty);
    });

    test('returns null when oldFrameworkGraph is null', () {
      expect(
        removeStaleResourceTombstones(docIri, null, {appSubjectIri}),
        isNull,
      );
    });

    test('returns original graph when liveAppSubjects is empty', () {
      final old = buildFrameworkGraphWithResourceTombstone();
      final result = removeStaleResourceTombstones(docIri, old, {});
      expect(result, same(old));
    });

    test('returns original graph when no tombstones match', () {
      final old = buildFrameworkGraphWithResourceTombstone();
      final result =
          removeStaleResourceTombstones(docIri, old, {otherSubjectIri});
      expect(result, same(old));
    });

    test('removes only tombstone statements when graph contains other entries',
        () {
      final clockStmtIri =
          IriTerm.validated('https://example.org/doc/note-1#lcrd-stmt-clock');
      final clockLiteral =
          LiteralTerm.typed('100', 'http://www.w3.org/2001/XMLSchema#integer');
      final old = RdfGraph.fromTriples([
        // Resource tombstone (stale)
        Triple(docIri, SyncManagedDocument.hasStatement, stmtIri),
        Triple(stmtIri, RdfStatement.subject, appSubjectIri),
        Triple(stmtIri, RdfStatement.crdtDeletedAt, deletedAtLiteral),
        // Unrelated clock entry for a different purpose
        Triple(docIri, SyncManagedDocument.hasStatement, clockStmtIri),
        Triple(clockStmtIri, RdfStatement.subject, appSubjectIri),
        Triple(clockStmtIri, RdfStatement.predicate,
            IriTerm.validated('https://schema.org/name')),
        Triple(clockStmtIri, SyncManagedDocument.crdtClockHash, clockLiteral),
      ]);

      final result =
          removeStaleResourceTombstones(docIri, old, {appSubjectIri});

      // Tombstone removed
      expect(result!.findTriples(subject: stmtIri), isEmpty);
      // Property-level entry preserved
      expect(result.findTriples(subject: clockStmtIri), isNotEmpty);
    });
  });
}
