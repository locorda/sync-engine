import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:test/test.dart';

void main() {
  group('InMemoryStorage batch helper methods', () {
    late InMemoryStorage storage;

    setUp(() async {
      storage = InMemoryStorage();
      await storage.initialize();
    });

    tearDown(() async {
      await storage.close();
    });

    test('getDocumentsByIri returns all requested documents', () async {
      final doc1 = IriTerm.validated('tag:locorda.org,2025:l:test/doc-1');
      final doc2 = IriTerm.validated('tag:locorda.org,2025:l:test/doc-2');
      final type = IriTerm.validated('https://example.com/Type');

      await storage.saveDocument(
        doc1,
        type,
        RdfGraph(),
        DocumentMetadata(ourPhysicalClock: 1, updatedAt: 1),
        const [],
      );
      await storage.saveDocument(
        doc2,
        type,
        RdfGraph(),
        DocumentMetadata(ourPhysicalClock: 2, updatedAt: 2),
        const [],
      );

      final result = await storage.getDocumentsByIri([doc1, doc2]);

      expect(result, hasLength(2));
      expect(result[doc1], isNotNull);
      expect(result[doc2], isNotNull);
    });

    test('setRemoteETags and getRemoteETags work in batch', () async {
      final remoteId = RemoteId('test', 'remote');
      final doc1 = IriTerm.validated('tag:locorda.org,2025:l:test/doc-1');
      final doc2 = IriTerm.validated('tag:locorda.org,2025:l:test/doc-2');

      await storage.setRemoteETags(
        remoteId,
        {
          doc1: 'etag-1',
          doc2: 'etag-2',
        },
      );

      final etags = await storage.getRemoteETags(remoteId, [doc1, doc2]);

      expect(etags, hasLength(2));
      expect(etags[doc1], 'etag-1');
      expect(etags[doc2], 'etag-2');
    });

    test('saveDocuments persists all batch entries', () async {
      final doc1 = IriTerm.validated('tag:locorda.org,2025:l:test/doc-1');
      final doc2 = IriTerm.validated('tag:locorda.org,2025:l:test/doc-2');
      final type = IriTerm.validated('https://example.com/Type');

      final results = await storage.saveDocuments([
        SaveDocumentRequest(
          documentIri: doc1,
          typeIri: type,
          document: RdfGraph(),
          metadata: DocumentMetadata(ourPhysicalClock: 10, updatedAt: 10),
          changes: const [],
        ),
        SaveDocumentRequest(
          documentIri: doc2,
          typeIri: type,
          document: RdfGraph(),
          metadata: DocumentMetadata(ourPhysicalClock: 20, updatedAt: 20),
          changes: const [],
        ),
      ]);

      final resultDocs = await storage.getDocumentsByIri([doc1, doc2]);

      expect(results, hasLength(2));
      expect(resultDocs[doc1], isNotNull);
      expect(resultDocs[doc2], isNotNull);
      expect(resultDocs[doc2]!.metadata.updatedAt, 20);
    });

    test('saveIndexEntries persists batch and updates active shard entries',
        () async {
      final shard = IriTerm.validated('tag:locorda.org,2025:l:test/shard#it');
      final index =
          IriTerm.validated('tag:locorda.org,2025:l:test/full-index#it');
      final resource1 =
          IriTerm.validated('tag:locorda.org,2025:l:test/resource-1#it');
      final resource2 =
          IriTerm.validated('tag:locorda.org,2025:l:test/resource-2#it');
      final type = IriTerm.validated('https://example.com/Type');

      await storage.saveIndexEntries([
        SaveIndexEntryRequest(
          shardIri: shard,
          indexIri: index,
          resourceIri: resource1,
          resourceType: type,
          clockHash: 'h1',
          ourPhysicalClock: 1,
          updatedAt: 1,
        ),
        SaveIndexEntryRequest(
          shardIri: shard,
          indexIri: index,
          resourceIri: resource2,
          resourceType: type,
          clockHash: 'h2',
          ourPhysicalClock: 2,
          updatedAt: 2,
        ),
      ]);

      final entries = await storage.getActiveIndexEntriesForShard(shard);

      expect(entries, hasLength(2));
      expect(entries.map((entry) => entry.resourceIri), contains(resource1));
      expect(entries.map((entry) => entry.resourceIri), contains(resource2));
    });
  });
}
