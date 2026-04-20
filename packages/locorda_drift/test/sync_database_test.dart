import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_drift/src/sync_database.dart';
import 'package:locorda_rdf_core/core.dart';

import 'test_sync_database.dart';

/// Helper to convert test strings to Uint8List for blob content columns.
Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

const IriTerm typeIri = IriTerm('https://example.com/TestType');

void main() {
  // Disable drift's multiple database warning for tests
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('SyncDatabase', () {
    late SyncDatabase database;

    setUp(() async {
      // Create database with in-memory database for tests
      database = TestSyncDatabase.memory();
    });

    tearDown(() async {
      await database.close();
    });

    group('IriBatchLoader Mixin', () {
      late SyncDocumentDao dao;

      setUp(() {
        dao = database.syncDocumentDao;
      });

      testWidgets('creates and retrieves IRI IDs in batch', (tester) async {
        // Arrange
        final iris = {
          'https://example.com/doc1',
          'https://example.com/doc2',
          'https://example.com/doc3',
        };

        // Act
        final iriToIdMap = await dao.getOrCreateIriIdsBatch(iris);

        // Assert
        expect(iriToIdMap.keys, containsAll(iris));
        expect(iriToIdMap.values.toSet(),
            hasLength(3)); // All IDs should be unique
      });

      testWidgets('reuses existing IRI IDs', (tester) async {
        // Arrange
        final iris1 = {'https://example.com/doc1', 'https://example.com/doc2'};
        final iris2 = {'https://example.com/doc2', 'https://example.com/doc3'};

        // Act
        final firstBatch = await dao.getOrCreateIriIdsBatch(iris1);
        final secondBatch = await dao.getOrCreateIriIdsBatch(iris2);

        // Assert
        expect(firstBatch['https://example.com/doc2'],
            equals(secondBatch['https://example.com/doc2']));
        expect(
            secondBatch.keys,
            containsAll(
                ['https://example.com/doc2', 'https://example.com/doc3']));
        expect(secondBatch.values.toSet(), hasLength(2));
      });

      testWidgets('handles empty IRI set', (tester) async {
        // Act
        final result = await dao.getOrCreateIriIdsBatch(<String>{});

        // Assert
        expect(result, isEmpty);
      });

      testWidgets('retrieves IRIs by IDs in batch', (tester) async {
        // Arrange
        final iris = {'https://example.com/doc1', 'https://example.com/doc2'};
        final iriToIdMap = await dao.getOrCreateIriIdsBatch(iris);
        final iriIds = iriToIdMap.values.toSet();

        // Act
        final idToIriMap = await dao.getIrisBatch(iriIds);

        // Assert
        expect(idToIriMap.keys, containsAll(iriIds));
        expect(idToIriMap.values.toSet(), containsAll(iris));
      });

      testWidgets('handles empty ID set in getIrisBatch', (tester) async {
        // Act
        final result = await dao.getIrisBatch(<int>{});

        // Assert
        expect(result, isEmpty);
      });

      testWidgets('handles large batch sizes efficiently', (tester) async {
        // Arrange - Create more than the batch size limit (999)
        final iris = <String>{};
        for (int i = 0; i < 1500; i++) {
          iris.add('https://example.com/doc$i');
        }

        // Act
        final iriToIdMap = await dao.getOrCreateIriIdsBatch(iris);

        // Assert
        expect(iriToIdMap.keys, containsAll(iris));
        expect(iriToIdMap.values.toSet(), hasLength(1500));
      });
    });

    group('SyncDocumentDao', () {
      late SyncDocumentDao dao;

      setUp(() {
        dao = database.syncDocumentDao;
      });

      testWidgets('saves and retrieves document content', (tester) async {
        // Arrange
        const documentIri = 'https://example.com/doc1';
        final content = _bytes(
            '<https://example.com/doc1#it> <https://schema.org/name> "Test" .');

        // Act
        final documentId = await dao.saveDocument(
          documentIri: documentIri,
          typeIri: typeIri.value,
          content: content,
          ourPhysicalClock: 1000,
          updatedAt: 2000,
        );

        final retrievedContent = await dao.getDocumentContent(documentIri);
        final document = await dao.getDocument(documentIri);
        final retrievedDocumentId = await dao.getDocumentId(documentIri);

        // Assert
        expect(documentId, isPositive);
        expect(retrievedContent, equals(content));
        expect(document, isNotNull);
        expect(document!.documentContent, equals(content));
        expect(document.ourPhysicalClock, equals(1000));
        expect(document.updatedAt, equals(2000));
        expect(retrievedDocumentId, equals(documentId));
      });

      testWidgets('updates existing document on conflict', (tester) async {
        // Arrange
        const documentIri = 'https://example.com/doc1';
        final content1 = _bytes(
            '<https://example.com/doc1#it> <https://schema.org/name> "First" .');
        final content2 = _bytes(
            '<https://example.com/doc1#it> <https://schema.org/name> "Second" .');

        // Act
        final firstId = await dao.saveDocument(
          documentIri: documentIri,
          typeIri: typeIri.value,
          content: content1,
          ourPhysicalClock: 1000,
          updatedAt: 2000,
        );

        final secondId = await dao.saveDocument(
          documentIri: documentIri,
          typeIri: typeIri.value,
          content: content2,
          ourPhysicalClock: 1500,
          updatedAt: 2500,
        );

        final document = await dao.getDocument(documentIri);

        // Assert
        expect(firstId, equals(secondId)); // Should reuse the same document ID
        expect(document!.documentContent, equals(content2));
        expect(document.ourPhysicalClock, equals(1500));
        expect(document.updatedAt, equals(2500));
      });

      testWidgets('returns null for non-existent document', (tester) async {
        // Act
        final content =
            await dao.getDocumentContent('https://example.com/nonexistent');
        final document =
            await dao.getDocument('https://example.com/nonexistent');
        final documentId =
            await dao.getDocumentId('https://example.com/nonexistent');

        // Assert
        expect(content, isNull);
        expect(document, isNull);
        expect(documentId, isNull);
      });

      testWidgets('gets documents modified since timestamp', (tester) async {
        // Arrange
        await dao.saveDocument(
          documentIri: 'https://example.com/doc1',
          typeIri: typeIri.value,
          content: _bytes('content1'),
          ourPhysicalClock: 1000,
          updatedAt: 2000,
        );
        await dao.saveDocument(
          documentIri: 'https://example.com/doc2',
          typeIri: typeIri.value,
          content: _bytes('content2'),
          ourPhysicalClock: 1100,
          updatedAt: 2500,
        );
        await dao.saveDocument(
          documentIri: 'https://example.com/doc3',
          typeIri: typeIri.value,
          content: _bytes('content3'),
          ourPhysicalClock: 1200,
          updatedAt: 3000,
        );

        // Act - Watch stream and get first emission
        final docs = await dao.getDocumentsModifiedSince(typeIri.value, '2200',
            limit: 100);

        // Assert
        expect(docs, hasLength(2));
        expect(
            docs.map((d) => d.iri),
            containsAll(
                ['https://example.com/doc2', 'https://example.com/doc3']));
        // Should be ordered by updatedAt ascending
        expect(
            docs[0].document.updatedAt, lessThan(docs[1].document.updatedAt));
      });

      testWidgets('gets documents changed by us since timestamp',
          (tester) async {
        // Arrange
        await dao.saveDocument(
          documentIri: 'https://example.com/doc1',
          typeIri: typeIri.value,
          content: _bytes('content1'),
          ourPhysicalClock: 1000,
          updatedAt: 2000,
        );
        await dao.saveDocument(
          documentIri: 'https://example.com/doc2',
          typeIri: typeIri.value,
          content: _bytes('content2'),
          ourPhysicalClock: 1500,
          updatedAt: 2500,
        );
        await dao.saveDocument(
          documentIri: 'https://example.com/doc3',
          typeIri: typeIri.value,
          content: _bytes('content3'),
          ourPhysicalClock: 2000,
          updatedAt: 3000,
        );

        // Act - Watch stream and get first emission
        final docs = await dao
            .getDocumentsChangedByUsSince(typeIri.value, '1200', limit: 100);

        // Assert
        expect(docs, hasLength(2));
        expect(
            docs.map((d) => d.iri),
            containsAll(
                ['https://example.com/doc2', 'https://example.com/doc3']));
        // Should be ordered by ourPhysicalClock ascending
        expect(docs[0].document.ourPhysicalClock,
            lessThan(docs[1].document.ourPhysicalClock));
      });

      testWidgets('respects limit parameter in queries', (tester) async {
        // Arrange
        for (int i = 0; i < 5; i++) {
          await dao.saveDocument(
            documentIri: 'https://example.com/doc$i',
            typeIri: typeIri.value,
            content: _bytes('content$i'),
            ourPhysicalClock: 1000 + i,
            updatedAt: 2000 + i,
          );
        }

        // Act - Watch streams and get first emissions
        final modifiedDocs = await dao
            .getDocumentsModifiedSince(typeIri.value, '2001', limit: 100);
        final changedDocs = await dao
            .getDocumentsChangedByUsSince(typeIri.value, '1000', limit: 100);

        // Assert - Stream returns all matching documents (no limit)
        expect(modifiedDocs,
            hasLength(3)); // doc2, doc3, doc4 all have updatedAt > 2001
        expect(changedDocs,
            hasLength(4)); // doc1-4 all have ourPhysicalClock > 1001
      });
    });

    group('SyncPropertyChangeDao', () {
      late SyncPropertyChangeDao propertyDao;
      late SyncDocumentDao documentDao;

      setUp(() {
        propertyDao = database.syncPropertyChangeDao;
        documentDao = database.syncDocumentDao;
      });

      testWidgets('records and retrieves property changes in batch',
          (tester) async {
        // Arrange
        final documentId = await documentDao.saveDocument(
          documentIri: 'https://example.com/doc1',
          typeIri: typeIri.value,
          content: _bytes('content'),
          ourPhysicalClock: 1000,
          updatedAt: 2000,
        );
        expect(documentId, isNotNull);

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

        // Act
        await propertyDao.recordPropertyChangesBatch(
          documentId: documentId,
          changes: changes,
        );

        final retrievedChanges =
            await propertyDao.getPropertyChanges(documentId);

        // Assert
        expect(retrievedChanges, hasLength(2));

        final nameChange = retrievedChanges.firstWhere(
          (c) => c.propertyIri == 'https://schema.org/name',
        );
        expect(nameChange.resourceIri, equals('https://example.com/doc1#it'));
        expect(nameChange.changedAtMs, equals(1500));
        expect(nameChange.changeLogicalClock, equals(10));

        final descChange = retrievedChanges.firstWhere(
          (c) => c.propertyIri == 'https://schema.org/description',
        );
        expect(descChange.changedAtMs, equals(1600));
        expect(descChange.changeLogicalClock, equals(15));
      });

      testWidgets('handles empty property changes batch', (tester) async {
        // Arrange
        final documentId = await documentDao.saveDocument(
          documentIri: 'https://example.com/doc1',
          typeIri: typeIri.value,
          content: _bytes('content'),
          ourPhysicalClock: 1000,
          updatedAt: 2000,
        );

        // Act
        await propertyDao.recordPropertyChangesBatch(
          documentId: documentId,
          changes: [],
        );

        final retrievedChanges =
            await propertyDao.getPropertyChanges(documentId);

        // Assert
        expect(retrievedChanges, isEmpty);
      });

      testWidgets('filters property changes by logical clock', (tester) async {
        // Arrange
        final documentId = await documentDao.saveDocument(
          documentIri: 'https://example.com/doc1',
          typeIri: typeIri.value,
          content: _bytes('content'),
          ourPhysicalClock: 1000,
          updatedAt: 2000,
        );
        expect(documentId, isNotNull);

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
          PropertyChange(
            resourceIri: const IriTerm('https://example.com/doc1#it'),
            propertyIri: const IriTerm('https://schema.org/title'),
            changedAtMs: 1700,
            changeLogicalClock: 20,
          ),
        ];

        await propertyDao.recordPropertyChangesBatch(
          documentId: documentId,
          changes: changes,
        );

        // Act
        final filteredChanges = await propertyDao.getPropertyChanges(
          documentId,
          sinceLogicalClock: 12,
        );

        // Assert
        expect(filteredChanges, hasLength(2));
        expect(
          filteredChanges.every((c) => c.changeLogicalClock > 12),
          isTrue,
        );
        expect(
          filteredChanges.map((c) => c.propertyIri),
          containsAll(
              ['https://schema.org/description', 'https://schema.org/title']),
        );
      });

      testWidgets('handles large batch of property changes', (tester) async {
        // Arrange
        final documentId = await documentDao.saveDocument(
          documentIri: 'https://example.com/doc1',
          typeIri: typeIri.value,
          content: _bytes('content'),
          ourPhysicalClock: 1000,
          updatedAt: 2000,
        );
        expect(documentId, isNotNull);

        final changes = <PropertyChange>[];
        for (int i = 0; i < 100; i++) {
          changes.add(PropertyChange(
            resourceIri: IriTerm.validated('https://example.com/resource$i'),
            propertyIri: IriTerm.validated('https://schema.org/property$i'),
            changedAtMs: 1500 + i,
            changeLogicalClock: 10 + i,
          ));
        }

        // Act
        await propertyDao.recordPropertyChangesBatch(
          documentId: documentId,
          changes: changes,
        );

        final retrievedChanges =
            await propertyDao.getPropertyChanges(documentId);

        // Assert
        expect(retrievedChanges, hasLength(100));
        // Verify all unique IRIs were created
        final resourceIris = retrievedChanges.map((c) => c.resourceIri).toSet();
        final propertyIris = retrievedChanges.map((c) => c.propertyIri).toSet();
        expect(resourceIris, hasLength(100));
        expect(propertyIris, hasLength(100));
      });
    });

    group('Database Schema', () {
      testWidgets('creates all tables and indices', (tester) async {
        // Act - Database should be initialized in setUp
        final tables = await database
            .customSelect("SELECT name FROM sqlite_master WHERE type='table'")
            .get();
        final indices = await database
            .customSelect("SELECT name FROM sqlite_master WHERE type='index'")
            .get();

        // Assert
        final tableNames = tables.map((t) => t.data['name']).toList();
        expect(
            tableNames,
            containsAll(
                ['sync_iris', 'sync_documents', 'sync_property_changes']));

        final indexNames = indices.map((i) => i.data['name']).toList();
        expect(indexNames, contains('idx_sync_documents_iri'));
        //expect(indexNames, contains('idx_sync_documents_updated'));
        expect(indexNames, contains('idx_sync_iris_iri'));
        expect(indexNames, contains('idx_property_changes_document'));
      });

      testWidgets('enforces foreign key constraints', (tester) async {
        // Arrange
        final documentDao = database.syncDocumentDao;
        final propertyDao = database.syncPropertyChangeDao;

        final documentId = await documentDao.saveDocument(
          documentIri: 'https://example.com/doc1',
          typeIri: typeIri.value,
          content: _bytes('content'),
          ourPhysicalClock: 1000,
          updatedAt: 2000,
        );
        expect(documentId, isNotNull);

        // Act & Assert - Should not throw for valid document ID
        await propertyDao.recordPropertyChangesBatch(
          documentId: documentId,
          changes: [
            PropertyChange(
              resourceIri: const IriTerm('https://example.com/doc1#it'),
              propertyIri: const IriTerm('https://schema.org/name'),
              changedAtMs: 1500,
              changeLogicalClock: 10,
            ),
          ],
        );

        // Should throw for invalid document ID
        expect(
          () => propertyDao.recordPropertyChangesBatch(
            documentId: 99999, // Non-existent document ID
            changes: [
              PropertyChange(
                resourceIri: const IriTerm('https://example.com/doc1#it'),
                propertyIri: const IriTerm('https://schema.org/name'),
                changedAtMs: 1500,
                changeLogicalClock: 10,
              ),
            ],
          ),
          throwsA(isA<Exception>()),
        );
      });
    });

    group('Transaction Behavior', () {
      testWidgets('transaction rollback preserves database consistency',
          (tester) async {
        // Arrange
        final documentDao = database.syncDocumentDao;

        // Act & Assert
        try {
          await database.transaction(() async {
            await documentDao.saveDocument(
              documentIri: 'https://example.com/doc1',
              typeIri: typeIri.value,
              content: _bytes('content'),
              ourPhysicalClock: 1000,
              updatedAt: 2000,
            );

            // Force an error to trigger rollback
            throw Exception('Forced error');
          });
        } catch (e) {
          // Expected exception
        }

        // Verify that the document was not saved due to rollback
        final document =
            await documentDao.getDocument('https://example.com/doc1');
        expect(document, isNull);
      });
    });

    group('IndexDao', () {
      late IndexDao indexDao;

      setUp(() {
        indexDao = database.indexDao;
      });

      testWidgets(
          'preserves createdAt when updating existing group subscription',
          (tester) async {
        const firstCreatedAt = 111111;
        const secondCreatedAt = 222222;

        final iriIds = await database.syncDocumentDao.getOrCreateIriIdsBatch({
          'https://example.com/index/group/1',
          'https://example.com/index/template/1',
          'https://example.com/type/note',
        });

        final groupIndexIriId = iriIds['https://example.com/index/group/1']!;
        final groupIndexTemplateIriId =
            iriIds['https://example.com/index/template/1']!;
        final indexedTypeIriId = iriIds['https://example.com/type/note']!;

        await indexDao.saveGroupIndexSubscription(
          groupIndexIriId: groupIndexIriId,
          groupIndexTemplateIriId: groupIndexTemplateIriId,
          indexedTypeIriId: indexedTypeIriId,
          rootResourceFetchPolicy: 'onRequest',
          createdAt: firstCreatedAt,
        );

        await indexDao.saveGroupIndexSubscription(
          groupIndexIriId: groupIndexIriId,
          groupIndexTemplateIriId: groupIndexTemplateIriId,
          indexedTypeIriId: indexedTypeIriId,
          rootResourceFetchPolicy: 'prefetch',
          createdAt: secondCreatedAt,
        );

        final row = await (database.select(database.groupIndexSubscriptions)
              ..where((t) => t.groupIndexIriId.equals(groupIndexIriId)))
            .getSingle();

        expect(row.createdAt, firstCreatedAt);
        expect(row.itemFetchPolicy, 'prefetch');
      });

      // Regression: both local-change queries must exclude is_remote_only = 1
      // entries. After the syncRemoteOnlyShardEntries updated_at fix (which
      // writes updated_at = now instead of 0), remote-only rows were
      // incorrectly returned by these queries, causing Stage7c crashes.
      group('local change detection excludes remote-only entries', () {
        const sinceTimestamp = 1000;

        late Map<String, int> iriIds;

        setUp(() async {
          iriIds = await database.syncDocumentDao.getOrCreateIriIdsBatch({
            'https://example.com/shard/1',
            'https://example.com/index/1',
            'https://example.com/Type',
            'https://example.com/res/local',
            'https://example.com/res/remote-only',
          });
        });

        Future<void> insertEntry({
          required String resourceIriKey,
          required bool isRemoteOnly,
        }) async {
          await indexDao.saveIndexEntry(
            shardIriId: iriIds['https://example.com/shard/1']!,
            indexIriId: iriIds['https://example.com/index/1']!,
            resourceIriId: iriIds[resourceIriKey]!,
            resourceTypeIriId: iriIds['https://example.com/Type']!,
            clockHash: isRemoteOnly ? 'remote-hash' : 'local-hash',
            isDeleted: false,
            isRemoteOnly: isRemoteOnly,
            // Simulates syncRemoteOnlyShardEntries writing updated_at = now
            updatedAt: sinceTimestamp + 1,
            ourPhysicalClock: isRemoteOnly ? 0 : 42,
          );
        }

        group('getShardsWithLocalChangesSince', () {
          testWidgets('excludes shard when only remote-only entry changed',
              (tester) async {
            await insertEntry(
                resourceIriKey: 'https://example.com/res/remote-only',
                isRemoteOnly: true);

            final shards = await indexDao
                .getShardsWithLocalChangesSince(sinceTimestamp, limit: 20);

            expect(shards, isEmpty);
          });

          testWidgets('includes shard when local entry changed',
              (tester) async {
            await insertEntry(
                resourceIriKey: 'https://example.com/res/local',
                isRemoteOnly: false);

            final shards = await indexDao
                .getShardsWithLocalChangesSince(sinceTimestamp, limit: 20);

            expect(shards, contains('https://example.com/shard/1'));
          });

          testWidgets(
              'includes shard when both local and remote-only entries changed',
              (tester) async {
            await insertEntry(
                resourceIriKey: 'https://example.com/res/local',
                isRemoteOnly: false);
            await insertEntry(
                resourceIriKey: 'https://example.com/res/remote-only',
                isRemoteOnly: true);

            final shards = await indexDao
                .getShardsWithLocalChangesSince(sinceTimestamp, limit: 20);

            expect(shards, contains('https://example.com/shard/1'));
          });
        });

        group('getLocallyChangedEntriesForShard', () {
          testWidgets('excludes remote-only entry with recent updatedAt',
              (tester) async {
            await insertEntry(
                resourceIriKey: 'https://example.com/res/remote-only',
                isRemoteOnly: true);

            final entries = await indexDao.getLocallyChangedEntriesForShard(
                iriIds['https://example.com/shard/1']!, sinceTimestamp);

            expect(entries, isEmpty);
          });

          testWidgets('includes local entry with recent updatedAt',
              (tester) async {
            await insertEntry(
                resourceIriKey: 'https://example.com/res/local',
                isRemoteOnly: false);

            final entries = await indexDao.getLocallyChangedEntriesForShard(
                iriIds['https://example.com/shard/1']!, sinceTimestamp);

            expect(entries, hasLength(1));
            expect(entries.first.resourceIriId,
                equals(iriIds['https://example.com/res/local']));
          });

          testWidgets('excludes remote-only entry when mixed with local entry',
              (tester) async {
            await insertEntry(
                resourceIriKey: 'https://example.com/res/local',
                isRemoteOnly: false);
            await insertEntry(
                resourceIriKey: 'https://example.com/res/remote-only',
                isRemoteOnly: true);

            final entries = await indexDao.getLocallyChangedEntriesForShard(
                iriIds['https://example.com/shard/1']!, sinceTimestamp);

            expect(entries, hasLength(1));
            expect(entries.first.resourceIriId,
                equals(iriIds['https://example.com/res/local']));
          });
        });
      });
    });
  });
}
