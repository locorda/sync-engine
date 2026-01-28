import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_drift/locorda_drift.dart';
import 'package:locorda_rdf_core/core.dart';

import 'test_sync_database.dart';

void main() {
  // Disable drift's multiple database warning for tests
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('DriftStorage', () {
    late DriftStorage storage;

    setUp(() async {
      // Create storage with test database for tests
      final testDatabase = TestSyncDatabase.memory();
      storage = DriftStorage.withDatabase(testDatabase);
      await storage.initialize();
    });

    tearDown(() async {
      await storage.close();
    });

    group('Document Operations', () {
      testWidgets('saves and retrieves document with metadata', (tester) async {
        // Arrange
        final documentIri = const IriTerm('https://example.com/doc1');
        final graph = RdfGraph(); // Empty graph for test

        final metadata = DocumentMetadata(
          ourPhysicalClock: 1000,
          updatedAt: 2000,
        );

        // Act
        final typeIri = const IriTerm('https://example.com/TestType');
        final result = await storage
            .saveDocument(documentIri, typeIri, graph, metadata, []);
        final retrieved = await storage.getDocument(documentIri);

        // Assert
        expect(result.currentCursor, equals('2000'));
        expect(result.previousCursor, isNull); // First document of this type
        expect(retrieved, isNotNull);
        expect(retrieved!.documentIri, equals(documentIri));
        expect(retrieved.metadata.ourPhysicalClock, equals(1000));
        expect(retrieved.metadata.updatedAt, equals(2000));
      });

      testWidgets('updates existing document', (tester) async {
        // Arrange
        final documentIri = const IriTerm('https://example.com/doc1');
        final graph1 = RdfGraph();
        final graph2 = RdfGraph();

        // Act
        final typeIri = const IriTerm('https://example.com/TestType');
        final result1 = await storage.saveDocument(documentIri, typeIri, graph1,
            DocumentMetadata(ourPhysicalClock: 1000, updatedAt: 2000), []);
        final result2 = await storage.saveDocument(documentIri, typeIri, graph2,
            DocumentMetadata(ourPhysicalClock: 1500, updatedAt: 2500), []);

        final retrieved = await storage.getDocument(documentIri);

        // Assert
        expect(result1.previousCursor, isNull); // First save
        expect(result1.currentCursor, equals('2000'));
        expect(result2.previousCursor,
            equals('2000')); // Previous cursor from first save
        expect(result2.currentCursor, equals('2500'));
        expect(retrieved, isNotNull);
        expect(retrieved!.metadata.ourPhysicalClock, equals(1500));
        expect(retrieved.metadata.updatedAt, equals(2500));
      });

      testWidgets('returns null for non-existent document', (tester) async {
        // Act
        final result = await storage
            .getDocument(const IriTerm('https://example.com/nonexistent'));

        // Assert
        expect(result, isNull);
      });

      testWidgets('saves document with property changes in transaction',
          (tester) async {
        // Arrange
        final documentIri = const IriTerm('https://example.com/doc1');
        final graph = RdfGraph();

        final changes = [
          PropertyChange(
            resourceIri: const IriTerm('https://example.com/doc1#it'),
            propertyIri: const IriTerm('https://schema.org/name'),
            changedAtMs: 1500,
            changeLogicalClock: 10,
          ),
          PropertyChange(
            resourceIri: const IriTerm('https://example.com/doc1#it'),
            propertyIri: const IriTerm('https://schema.org/description'),
            changedAtMs: 1600,
            changeLogicalClock: 11,
          ),
        ];

        // Act
        final typeIri = const IriTerm('https://example.com/TestType');
        await storage.saveDocument(
          documentIri,
          typeIri,
          graph,
          DocumentMetadata(ourPhysicalClock: 1000, updatedAt: 2000),
          changes,
        );

        // Assert
        final retrievedChanges = await storage.getPropertyChanges(documentIri);
        expect(retrievedChanges, hasLength(2));

        final nameChange = retrievedChanges.firstWhere(
          (c) => c.propertyIri == const IriTerm('https://schema.org/name'),
        );
        expect(nameChange.changedAtMs, equals(1500));
        expect(nameChange.changeLogicalClock, equals(10));
      });
    });

    group('Property Change Operations', () {
      testWidgets('retrieves property changes for document', (tester) async {
        // Arrange
        final documentIri = const IriTerm('https://example.com/doc1');
        final graph = RdfGraph();

        final changes = [
          PropertyChange(
            resourceIri: const IriTerm('https://example.com/doc1#it'),
            propertyIri: const IriTerm('https://schema.org/name'),
            changedAtMs: 1500,
            changeLogicalClock: 10,
          ),
          PropertyChange(
            resourceIri: const IriTerm('https://example.com/doc1#it'),
            propertyIri: const IriTerm('https://schema.org/description'),
            changedAtMs: 1600,
            changeLogicalClock: 15,
          ),
        ];

        final typeIri = const IriTerm('https://example.com/TestType');
        await storage.saveDocument(
          documentIri,
          typeIri,
          graph,
          DocumentMetadata(ourPhysicalClock: 1000, updatedAt: 2000),
          changes,
        );

        // Act
        final retrievedChanges = await storage.getPropertyChanges(documentIri);

        // Assert
        expect(retrievedChanges, hasLength(2));
        expect(
            retrievedChanges.map((c) => (c.propertyIri as IriTerm).value),
            containsAll(
                ['https://schema.org/name', 'https://schema.org/description']));
      });

      testWidgets('filters property changes by logical clock', (tester) async {
        // Arrange
        final documentIri = const IriTerm('https://example.com/doc1');
        final graph = RdfGraph();

        final changes = [
          PropertyChange(
            resourceIri: const IriTerm('https://example.com/doc1#it'),
            propertyIri: const IriTerm('https://schema.org/name'),
            changedAtMs: 1500,
            changeLogicalClock: 10,
          ),
          PropertyChange(
            resourceIri: const IriTerm('https://example.com/doc1#it'),
            propertyIri: const IriTerm('https://schema.org/description'),
            changedAtMs: 1600,
            changeLogicalClock: 15,
          ),
        ];

        final typeIri = const IriTerm('https://example.com/TestType');
        await storage.saveDocument(
          documentIri,
          typeIri,
          graph,
          DocumentMetadata(ourPhysicalClock: 1000, updatedAt: 2000),
          changes,
        );

        // Act
        final filteredChanges = await storage.getPropertyChanges(documentIri,
            sinceLogicalClock: 12);

        // Assert
        expect(filteredChanges, hasLength(1));
        expect((filteredChanges.first.propertyIri as IriTerm).value,
            equals('https://schema.org/description'));
        expect(filteredChanges.first.changeLogicalClock, equals(15));
      });

      testWidgets('returns empty list for non-existent document',
          (tester) async {
        // Act
        final changes = await storage.getPropertyChanges(
            const IriTerm('https://example.com/nonexistent'));

        // Assert
        expect(changes, isEmpty);
      });
    });

    group('Sync Query Operations', () {
      testWidgets('gets documents modified since timestamp', (tester) async {
        // Arrange
        final doc1Iri = const IriTerm('https://example.com/doc1');
        final doc2Iri = const IriTerm('https://example.com/doc2');
        final doc3Iri = const IriTerm('https://example.com/doc3');
        final graph = RdfGraph();

        final typeIri = const IriTerm('https://example.com/TestType');
        await storage.saveDocument(doc1Iri, typeIri, graph,
            DocumentMetadata(ourPhysicalClock: 1000, updatedAt: 2000), []);
        await storage.saveDocument(doc2Iri, typeIri, graph,
            DocumentMetadata(ourPhysicalClock: 1100, updatedAt: 2500), []);
        await storage.saveDocument(doc3Iri, typeIri, graph,
            DocumentMetadata(ourPhysicalClock: 1200, updatedAt: 3000), []);

        // Act - watch the stream and collect first emission
        final docsResult = await storage
            .getDocumentsModifiedSince(typeIri, '2200', limit: 100);

        // Assert
        expect(docsResult.documents, hasLength(2));
        expect(
            docsResult.documents.map((d) => d.documentIri.value),
            containsAll(
                ['https://example.com/doc2', 'https://example.com/doc3']));

        // Should be ordered by updatedAt ascending
        expect(docsResult.documents[0].metadata.updatedAt,
            lessThan(docsResult.documents[1].metadata.updatedAt));
      });

      testWidgets('gets documents changed by us since timestamp',
          (tester) async {
        // Arrange
        final doc1Iri = const IriTerm('https://example.com/doc1');
        final doc2Iri = const IriTerm('https://example.com/doc2');
        final doc3Iri = const IriTerm('https://example.com/doc3');
        final graph = RdfGraph();

        final typeIri = const IriTerm('https://example.com/TestType');
        await storage.saveDocument(doc1Iri, typeIri, graph,
            DocumentMetadata(ourPhysicalClock: 1000, updatedAt: 2000), []);
        await storage.saveDocument(doc2Iri, typeIri, graph,
            DocumentMetadata(ourPhysicalClock: 1500, updatedAt: 2500), []);
        await storage.saveDocument(doc3Iri, typeIri, graph,
            DocumentMetadata(ourPhysicalClock: 2000, updatedAt: 3000), []);

        // Act - watch the stream and collect first emission
        final docsResult = await storage
            .getDocumentsChangedByUsSince(typeIri, '1200', limit: 100);

        // Assert
        expect(docsResult.documents, hasLength(2));
        expect(
            docsResult.documents.map((d) => d.documentIri.value),
            containsAll(
                ['https://example.com/doc2', 'https://example.com/doc3']));

        // Should be ordered by ourPhysicalClock ascending
        expect(docsResult.documents[0].metadata.ourPhysicalClock,
            lessThan(docsResult.documents[1].metadata.ourPhysicalClock));
      });

      testWidgets('emits updates when documents change', (tester) async {
        // Arrange
        final graph = RdfGraph();
        final typeIri = const IriTerm('https://example.com/TestType');

        // Save initial documents
        await storage.saveDocument(
          IriTerm.validated('https://example.com/doc0'),
          typeIri,
          graph,
          DocumentMetadata(ourPhysicalClock: 1000, updatedAt: 2000),
          [],
        );

        // Act - Start watching from cursor 1500
        final stream = storage.watchDocumentsModifiedSince(typeIri, '1500');

        // Wait for initial emission
        final firstResult = await stream.first;

        // Assert - Initial emission should contain doc0 (updatedAt=2000 > 1500)
        expect(firstResult.documents, hasLength(1));
        expect(firstResult.documents[0].documentIri.value,
            'https://example.com/doc0');

        // Act - Add a new document and verify stream emits update
        final streamFuture = stream.first;
        await storage.saveDocument(
          IriTerm.validated('https://example.com/doc1'),
          typeIri,
          graph,
          DocumentMetadata(ourPhysicalClock: 1001, updatedAt: 2001),
          [],
        );

        // Assert - Stream should emit updated result with both documents
        final secondResult = await streamFuture;
        expect(secondResult.documents, hasLength(2));
      }, skip: true /* TODO: fix watch tests */);
    });

    group('Initialization and Cleanup', () {
      testWidgets('initializes only once', (tester) async {
        // Act
        await storage.initialize();
        await storage.initialize(); // Second call should be safe

        // Assert - no exceptions thrown
      });

      testWidgets('closes database properly', (tester) async {
        // Act
        await storage.close();

        // Assert - calling close again should be safe
        await storage.close();
      });
    });

    group('Factory Constructor', () {
      testWidgets('creates storage with test database', (tester) async {
        // Act
        final testDatabase = TestSyncDatabase.memory();
        final storage = DriftStorage.withDatabase(testDatabase);

        // Assert
        expect(storage, isNotNull);
        expect(storage.documentDao, isNotNull);
        expect(storage.propertyChangeDao, isNotNull);

        // Clean up
        await storage.close();
      });
    });
  });
}
