import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_drift/locorda_drift.dart';
import 'package:locorda_rdf_core/core.dart';

import 'test_sync_database.dart';

class _PerflogCall {
  final String operation;
  final List<String> args;

  const _PerflogCall({required this.operation, required this.args});
}

class _RecordingPerflog implements Perflog {
  final List<_PerflogCall> calls;

  const _RecordingPerflog(this.calls);

  @override
  Perflog create(String name, Object target, {bool? includeArgs}) => this;

  @override
  Future<T> measure<T>(
    String operation,
    Future<T> Function() action, {
    List<String>? args,
    int? minDurationMs,
    List<String> Function(T)? resultArgsBuilder,
  }) async {
    final result = await action();
    final mergedArgs = <String>[...?args];
    if (resultArgsBuilder != null) {
      mergedArgs.addAll(resultArgsBuilder(result));
    }
    calls.add(_PerflogCall(operation: operation, args: mergedArgs));
    return result;
  }

  @override
  Future<void> dispose() async {}
}

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

      testWidgets('gets multiple documents by IRI including missing entries',
          (tester) async {
        final doc1 = const IriTerm('https://example.com/doc1');
        final doc2 = const IriTerm('https://example.com/doc2');
        final missing = const IriTerm('https://example.com/missing');
        final typeIri = const IriTerm('https://example.com/TestType');

        await storage.saveDocument(
          doc1,
          typeIri,
          RdfGraph(),
          DocumentMetadata(ourPhysicalClock: 1000, updatedAt: 2000),
          const [],
        );
        await storage.saveDocument(
          doc2,
          typeIri,
          RdfGraph(),
          DocumentMetadata(ourPhysicalClock: 1100, updatedAt: 2100),
          const [],
        );

        final result = await storage.getDocumentsByIri([doc1, doc2, missing]);

        expect(result, hasLength(3));
        expect(result[doc1], isNotNull);
        expect(result[doc2], isNotNull);
        expect(result[missing], isNull);
      });

      testWidgets('saves documents in batch', (tester) async {
        final doc1 = const IriTerm('https://example.com/doc-batch-1');
        final doc2 = const IriTerm('https://example.com/doc-batch-2');
        final typeIri = const IriTerm('https://example.com/TestType');

        final results = await storage.saveDocuments([
          SaveDocumentRequest(
            documentIri: doc1,
            typeIri: typeIri,
            document: RdfGraph(),
            metadata: DocumentMetadata(ourPhysicalClock: 1200, updatedAt: 2200),
            changes: const [],
          ),
          SaveDocumentRequest(
            documentIri: doc2,
            typeIri: typeIri,
            document: RdfGraph(),
            metadata: DocumentMetadata(ourPhysicalClock: 1300, updatedAt: 2300),
            changes: const [],
          ),
        ]);

        final docs = await storage.getDocumentsByIri([doc1, doc2]);

        expect(results, hasLength(2));
        expect(results.first.currentCursor, '2200');
        expect(results.last.currentCursor, '2300');
        expect(docs[doc1], isNotNull);
        expect(docs[doc2], isNotNull);
      });

      testWidgets('saveDocuments is atomic on optimistic-lock conflict',
          (tester) async {
        final existing = const IriTerm('https://example.com/doc-existing');
        final newDoc = const IriTerm('https://example.com/doc-new');
        final typeIri = const IriTerm('https://example.com/TestType');

        await storage.saveDocument(
          existing,
          typeIri,
          RdfGraph(),
          DocumentMetadata(ourPhysicalClock: 1000, updatedAt: 2000),
          const [],
        );

        await expectLater(
          () => storage.saveDocuments([
            SaveDocumentRequest(
              documentIri: existing,
              typeIri: typeIri,
              document: RdfGraph(),
              metadata:
                  DocumentMetadata(ourPhysicalClock: 1100, updatedAt: 2100),
              changes: const [],
              ifMatchUpdatedAt: 1999,
            ),
            SaveDocumentRequest(
              documentIri: newDoc,
              typeIri: typeIri,
              document: RdfGraph(),
              metadata:
                  DocumentMetadata(ourPhysicalClock: 1200, updatedAt: 2200),
              changes: const [],
            ),
          ]),
          throwsA(isA<ConcurrentUpdateException>()),
        );

        final persisted = await storage.getDocumentsByIri([existing, newDoc]);
        expect(persisted[existing], isNotNull);
        expect(persisted[existing]!.metadata.updatedAt, 2000);
        expect(persisted[newDoc], isNull);
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

    group('Remote ETag Operations', () {
      testWidgets('sets and gets remote ETags in batch', (tester) async {
        final remote = RemoteId('solid', 'https://alice.example/');
        final doc1 = const IriTerm('https://example.com/doc-1');
        final doc2 = const IriTerm('https://example.com/doc-2');
        final missing = const IriTerm('https://example.com/doc-missing');

        await storage.setRemoteETags(remote, {
          doc1: 'etag-1',
          doc2: 'etag-2',
        });

        final etags =
            await storage.getRemoteETags(remote, [doc1, doc2, missing]);

        expect(etags, hasLength(3));
        expect(etags[doc1], 'etag-1');
        expect(etags[doc2], 'etag-2');
        expect(etags[missing], isNull);
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

    group('Index Entry Operations', () {
      testWidgets('saves index entries in batch', (tester) async {
        final shardIri = const IriTerm('https://example.com/shard#it');
        final indexIri = const IriTerm('https://example.com/index#it');
        final resourceType = const IriTerm('https://example.com/TestType');

        await storage.saveIndexEntries([
          SaveIndexEntryRequest(
            shardIri: shardIri,
            indexIri: indexIri,
            resourceIri: const IriTerm('https://example.com/resource-1#it'),
            resourceType: resourceType,
            clockHash: 'hash-1',
            ourPhysicalClock: 100,
            updatedAt: 200,
          ),
          SaveIndexEntryRequest(
            shardIri: shardIri,
            indexIri: indexIri,
            resourceIri: const IriTerm('https://example.com/resource-2#it'),
            resourceType: resourceType,
            clockHash: 'hash-2',
            ourPhysicalClock: 101,
            updatedAt: 201,
          ),
        ]);

        final entries = await storage.getActiveIndexEntriesForShard(shardIri);

        expect(entries, hasLength(2));
        expect(entries.map((entry) => entry.clockHash), contains('hash-1'));
        expect(entries.map((entry) => entry.clockHash), contains('hash-2'));
      });

      testWidgets('uses shard cache for shard lookup after warmup',
          (tester) async {
        final perflogCalls = <_PerflogCall>[];
        final testDatabase = TestSyncDatabase.memory();
        final cacheAwareStorage = DriftStorage.withDatabase(
          testDatabase,
          perflog: _RecordingPerflog(perflogCalls),
        );
        await cacheAwareStorage.initialize();

        final shardIri = const IriTerm('https://example.com/shard-cached#it');
        final indexIri = const IriTerm('https://example.com/index-cached#it');
        final resourceType = const IriTerm('https://example.com/CachedType');

        await cacheAwareStorage.warmupIriIds([shardIri]);
        await cacheAwareStorage.saveIndexEntry(
          shardIri: shardIri,
          indexIri: indexIri,
          resourceIri: const IriTerm('https://example.com/resource-cached#it'),
          resourceType: resourceType,
          clockHash: 'hash-cached',
          ourPhysicalClock: 10,
          updatedAt: 20,
        );

        final entries =
            await cacheAwareStorage.getActiveIndexEntriesForShard(shardIri);

        expect(entries, hasLength(1));
        final resolveCalls = perflogCalls
            .where((call) =>
                call.operation ==
                'storage.getActiveIndexEntriesForShard.resolveShardIriId')
            .toList(growable: false);
        expect(resolveCalls, isNotEmpty);
        expect(resolveCalls.last.args, contains('cacheSource=shardCache'));

        await cacheAwareStorage.close();
      });
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

    group('Index Instance Sync State', () {
      testWidgets('upserts and reads per-remote index state', (tester) async {
        const indexInstanceIri = IriTerm('https://example.com/index/instance1');
        final remote = RemoteId('solid', 'https://alice.example/');

        await storage.upsertIndexInstanceSyncState(
          indexInstanceIri: indexInstanceIri,
          remoteId: remote,
          phase: RemoteSyncPhase.ready,
          lastSuccessfulSyncAt: DateTime.utc(2026, 2, 1, 10),
          lastAttemptStartedAt: DateTime.utc(2026, 2, 1, 9, 59),
          lastAttemptFinishedAt: DateTime.utc(2026, 2, 1, 10),
        );

        final snapshot =
            await storage.getIndexInstanceSyncState(indexInstanceIri);
        final entry = snapshot.perRemote[remote];

        expect(entry, isNotNull);
        expect(entry!.phase, RemoteSyncPhase.ready);
        expect(entry.lastSuccessfulSyncAt, DateTime.utc(2026, 2, 1, 10));
      });

      testWidgets('preserves lastSuccessfulSyncAt on later error',
          (tester) async {
        const indexInstanceIri = IriTerm('https://example.com/index/instance2');
        final remote = RemoteId('solid', 'https://bob.example/');
        final successAt = DateTime.utc(2026, 2, 2, 12);

        await storage.upsertIndexInstanceSyncState(
          indexInstanceIri: indexInstanceIri,
          remoteId: remote,
          phase: RemoteSyncPhase.ready,
          lastSuccessfulSyncAt: successAt,
        );

        await storage.upsertIndexInstanceSyncState(
          indexInstanceIri: indexInstanceIri,
          remoteId: remote,
          phase: RemoteSyncPhase.error,
          lastErrorMessage: 'network timeout',
        );

        final snapshot =
            await storage.getIndexInstanceSyncState(indexInstanceIri);
        final entry = snapshot.perRemote[remote];

        expect(entry, isNotNull);
        expect(entry!.phase, RemoteSyncPhase.error);
        expect(entry.lastSuccessfulSyncAt, successAt);
        expect(entry.lastErrorMessage, 'network timeout');
      });

      testWidgets('keeps lastSuccessfulSyncAt when explicitly null',
          (tester) async {
        const indexInstanceIri = IriTerm('https://example.com/index/instance3');
        final remote = RemoteId('solid', 'https://dave.example/');
        final successAt = DateTime.utc(2026, 2, 3, 14);

        await storage.upsertIndexInstanceSyncState(
          indexInstanceIri: indexInstanceIri,
          remoteId: remote,
          phase: RemoteSyncPhase.ready,
          lastSuccessfulSyncAt: successAt,
        );

        await storage.upsertIndexInstanceSyncState(
          indexInstanceIri: indexInstanceIri,
          remoteId: remote,
          phase: RemoteSyncPhase.error,
          lastSuccessfulSyncAt: null,
          lastErrorMessage: 'timeout',
        );

        final snapshot =
            await storage.getIndexInstanceSyncState(indexInstanceIri);
        final entry = snapshot.perRemote[remote];

        expect(entry, isNotNull);
        expect(entry!.phase, RemoteSyncPhase.error);
        expect(entry.lastSuccessfulSyncAt, successAt);
        expect(entry.lastErrorMessage, 'timeout');
      });

      testWidgets('watches configured remotes', (tester) async {
        final expectedRemote = RemoteId('solid', 'https://carol.example/');

        await storage.updateLastRemoteSyncTimestamp(
          expectedRemote,
          100,
        );

        final remotes = await storage.getConfiguredRemoteIds();
        expect(remotes, contains(expectedRemote));
      });
    });
  });
}
