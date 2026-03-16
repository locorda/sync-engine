import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_core/src/index/shard_determiner.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:test/test.dart';

void main() {
  group('ShardDeterminationLookupCache', () {
    test('caches existing documents and calls loader once per IRI', () async {
      final cache = ShardDeterminationLookupCache();
      final docIri = IriTerm('https://example.org/index/full/index');
      var loaderCalls = 0;

      Future<StoredDocument?> loader(IriTerm iri) async {
        loaderCalls++;
        return _storedDocument(iri);
      }

      final first = await cache.getOrLoad(docIri, loader);
      final second = await cache.getOrLoad(docIri, loader);

      expect(first, isNotNull);
      expect(identical(first, second), isTrue);
      expect(loaderCalls, 1);
    });

    test('caches missing documents and does not re-load null results',
        () async {
      final cache = ShardDeterminationLookupCache();
      final docIri = IriTerm('https://example.org/index/group/index');
      var loaderCalls = 0;

      Future<StoredDocument?> loader(IriTerm iri) async {
        loaderCalls++;
        return null;
      }

      final first = await cache.getOrLoad(docIri, loader);
      final second = await cache.getOrLoad(docIri, loader);

      expect(first, isNull);
      expect(second, isNull);
      expect(loaderCalls, 1);
    });

    test('clear invalidates cache entries', () async {
      final cache = ShardDeterminationLookupCache();
      final docIri = IriTerm('https://example.org/index/group/template');
      var loaderCalls = 0;

      Future<StoredDocument?> loader(IriTerm iri) async {
        loaderCalls++;
        return _storedDocument(iri);
      }

      await cache.getOrLoad(docIri, loader);
      cache.clear();
      await cache.getOrLoad(docIri, loader);

      expect(loaderCalls, 2);
    });
  });
}

StoredDocument _storedDocument(IriTerm documentIri) {
  return StoredDocument(
    documentIri: documentIri,
    document: RdfGraph(),
    metadata: DocumentMetadata(ourPhysicalClock: 1, updatedAt: 1),
  );
}
