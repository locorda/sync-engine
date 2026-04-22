import 'dart:async';

import 'package:locorda_core/src/vocab/generated/rdf.dart';
import 'package:locorda_core/src/mapping/recursive_rdf_loader.dart';

import 'package:locorda_rdf_core/core.dart';
import 'package:test/test.dart';

class MockRdfGraphFetcher implements RdfGraphFetcher {
  final Map<IriTerm, Future<RdfGraph>> _mockData = {};
  final Set<IriTerm> _fetchedUris = {};
  int fetchCount = 0;

  void setMockData(IriTerm uri, RdfGraph graph) {
    _mockData[uri] = Future.value(graph);
  }

  void setMockDataFuture(IriTerm uri, Future<RdfGraph> graph) {
    _mockData[uri] = graph;
  }

  void clear() {
    _mockData.clear();
    _fetchedUris.clear();
    fetchCount = 0;
  }

  Set<IriTerm> get fetchedUris => Set.unmodifiable(_fetchedUris);

  @override
  Future<RdfGraph> fetch(IriTerm iri) async {
    fetchCount++;
    _fetchedUris.add(iri);

    final graph = _mockData[iri];
    if (graph == null) {
      throw Exception('Document not found: ${iri}');
    }
    return await graph;
  }
}

class TestDependencyExtractor implements DependencyExtractor {
  final IriTerm? _forType;
  final Map<IriTerm, List<IriTerm>> _dependencies;

  TestDependencyExtractor(this._forType, this._dependencies);

  @override
  IriTerm? forType() => _forType;

  @override
  Iterable<IriTerm> extractDependencies(RdfSubject subj, RdfGraph graph) {
    final deps = _dependencies[subj];
    if (deps == null) return [];
    return deps.map((dep) => dep);
  }
}

void main() {
  late MockRdfGraphFetcher mockFetcher;
  late RecursiveRdfLoader loader;

  setUp(() {
    mockFetcher = MockRdfGraphFetcher();
    loader = RecursiveRdfLoader(
      fetcher: mockFetcher,
      iriFactory: IriTerm.validated,
    );
  });

  tearDown(() {
    mockFetcher.clear();
  });

  group('RecursiveRdfLoader', () {
    group('basic loading', () {
      test('loads single document without dependencies', () async {
        final testUri = const IriTerm('https://example.com/doc1');
        final testGraph = RdfGraph.fromTriples([
          Triple(
            testUri,
            Rdf.type,
            const IriTerm('https://example.com/TestType'),
          ),
        ]);

        mockFetcher.setMockData(testUri, testGraph);

        final result = await loader.loadRdfDocumentsRecursively([testUri]);

        expect(result, hasLength(1));
        expect(result.keys.first, equals(testUri));
        expect(result.values.first.triples, equals(testGraph.triples));
        expect(mockFetcher.fetchCount, equals(1));
        expect(mockFetcher.fetchedUris, contains(testUri));
      });

      test('loads multiple documents without dependencies', () async {
        final doc1Uri = const IriTerm('https://example.com/doc1');
        final doc2Uri = const IriTerm('https://example.com/doc2');

        final graph1 = RdfGraph.fromTriples([
          Triple(doc1Uri, Rdf.type, const IriTerm('https://example.com/Type1')),
        ]);
        final graph2 = RdfGraph.fromTriples([
          Triple(doc2Uri, Rdf.type, const IriTerm('https://example.com/Type2')),
        ]);

        mockFetcher.setMockData(doc1Uri, graph1);
        mockFetcher.setMockData(doc2Uri, graph2);

        final result = await loader.loadRdfDocumentsRecursively([
          doc1Uri,
          doc2Uri,
        ]);

        expect(result, hasLength(2));
        expect(result.keys.map((k) => k), containsAll([doc1Uri, doc2Uri]));
        expect(mockFetcher.fetchCount, equals(2));
        expect(mockFetcher.fetchedUris, containsAll([doc1Uri, doc2Uri]));
      });

      test('handles fragment IRIs by loading document IRI', () async {
        final fragmentUri = const IriTerm('https://example.com/doc1#fragment');
        final documentUri = const IriTerm('https://example.com/doc1');

        final testGraph = RdfGraph.fromTriples([
          Triple(
            fragmentUri, // Graph should contain the fragment as subject
            Rdf.type,
            const IriTerm('https://example.com/TestType'),
          ),
        ]);

        mockFetcher.setMockData(documentUri, testGraph);

        final result = await loader.loadRdfDocumentsRecursively([fragmentUri]);

        expect(result, hasLength(1));
        expect(result.keys.first, equals(documentUri));
        expect(mockFetcher.fetchedUris, contains(documentUri));
        expect(mockFetcher.fetchedUris, isNot(contains(fragmentUri)));
      });

      test('avoids duplicate loading of same document', () async {
        final testUri = const IriTerm('https://example.com/doc1');
        final testGraph = RdfGraph.fromTriples([
          Triple(
              testUri, Rdf.type, const IriTerm('https://example.com/TestType')),
        ]);

        mockFetcher.setMockData(testUri, testGraph);

        final result = await loader.loadRdfDocumentsRecursively([
          testUri,
          testUri, // Duplicate
          IriTerm.validated(
              '${testUri.value}#fragment'), // Same document with fragment
        ]);

        expect(result, hasLength(1));
        expect(mockFetcher.fetchCount, equals(1));
        expect(mockFetcher.fetchedUris, hasLength(1));
      });
    });

    group('dependency extraction', () {
      test('loads dependencies with single extractor', () async {
        final mainUri = const IriTerm('https://example.com/main');
        final depUri = const IriTerm('https://example.com/dependency');

        final mainGraph = RdfGraph.fromTriples([
          Triple(
              mainUri, Rdf.type, const IriTerm('https://example.com/MainType')),
        ]);
        final depGraph = RdfGraph.fromTriples([
          Triple(
              depUri, Rdf.type, const IriTerm('https://example.com/DepType')),
        ]);

        mockFetcher.setMockData(mainUri, mainGraph);
        mockFetcher.setMockData(depUri, depGraph);

        final extractor = TestDependencyExtractor(
          const IriTerm('https://example.com/MainType'),
          {
            mainUri: [depUri]
          },
        );

        final result = await loader.loadRdfDocumentsRecursively(
          [mainUri],
          extractors: [extractor],
        );

        expect(result, hasLength(2));
        expect(result.keys.map((k) => k), containsAll([mainUri, depUri]));
        expect(mockFetcher.fetchCount, equals(2));
      });

      test('loads nested dependencies recursively', () async {
        final rootUri = const IriTerm('https://example.com/root');
        final level1Uri = const IriTerm('https://example.com/level1');
        final level2Uri = const IriTerm('https://example.com/level2');

        final rootGraph = RdfGraph.fromTriples([
          Triple(
              rootUri, Rdf.type, const IriTerm('https://example.com/TestType')),
        ]);
        final level1Graph = RdfGraph.fromTriples([
          Triple(level1Uri, Rdf.type,
              const IriTerm('https://example.com/TestType')),
        ]);
        final level2Graph = RdfGraph.fromTriples([
          Triple(level2Uri, Rdf.type,
              const IriTerm('https://example.com/TestType')),
        ]);

        mockFetcher.setMockData(rootUri, rootGraph);
        mockFetcher.setMockData(level1Uri, level1Graph);
        mockFetcher.setMockData(level2Uri, level2Graph);

        final extractor = TestDependencyExtractor(
          const IriTerm('https://example.com/TestType'),
          {
            rootUri: [level1Uri],
            level1Uri: [level2Uri],
          },
        );

        final result = await loader.loadRdfDocumentsRecursively(
          [rootUri],
          extractors: [extractor],
        );

        expect(result, hasLength(3));
        expect(result.keys.map((k) => k),
            containsAll([rootUri, level1Uri, level2Uri]));
        expect(mockFetcher.fetchCount, equals(3));
      });

      test('handles multiple extractors with different type filters', () async {
        final mainUri = const IriTerm('https://example.com/main');
        final dep1Uri = const IriTerm('https://example.com/dep1');
        final dep2Uri = const IriTerm('https://example.com/dep2');

        final mainGraph = RdfGraph.fromTriples([
          Triple(
              mainUri, Rdf.type, const IriTerm('https://example.com/MainType')),
        ]);
        final dep1Graph = RdfGraph.fromTriples([
          Triple(
              dep1Uri, Rdf.type, const IriTerm('https://example.com/DepType1')),
        ]);
        final dep2Graph = RdfGraph.fromTriples([
          Triple(
              dep2Uri, Rdf.type, const IriTerm('https://example.com/DepType2')),
        ]);

        mockFetcher.setMockData(mainUri, mainGraph);
        mockFetcher.setMockData(dep1Uri, dep1Graph);
        mockFetcher.setMockData(dep2Uri, dep2Graph);

        final extractor1 = TestDependencyExtractor(
          const IriTerm('https://example.com/MainType'),
          {
            mainUri: [dep1Uri]
          },
        );
        final extractor2 = TestDependencyExtractor(
          const IriTerm('https://example.com/DepType1'),
          {
            dep1Uri: [dep2Uri]
          },
        );

        final result = await loader.loadRdfDocumentsRecursively(
          [mainUri],
          extractors: [extractor1, extractor2],
        );

        expect(result, hasLength(3));
        expect(result.keys.map((k) => k),
            containsAll([mainUri, dep1Uri, dep2Uri]));
        expect(mockFetcher.fetchCount, equals(3));
      });

      test('handles extractors with no type filter (applies to all)', () async {
        final mainUri = const IriTerm('https://example.com/main');
        final depUri = const IriTerm('https://example.com/dependency');

        final mainGraph = RdfGraph.fromTriples([
          Triple(
              mainUri, Rdf.type, const IriTerm('https://example.com/MainType')),
        ]);
        final depGraph = RdfGraph.fromTriples([
          Triple(
              depUri, Rdf.type, const IriTerm('https://example.com/DepType')),
        ]);

        mockFetcher.setMockData(mainUri, mainGraph);
        mockFetcher.setMockData(depUri, depGraph);

        final extractor = TestDependencyExtractor(
          null, // No type filter - applies to all
          {
            mainUri: [depUri]
          },
        );

        final result = await loader.loadRdfDocumentsRecursively(
          [mainUri],
          extractors: [extractor],
        );

        expect(result, hasLength(2));
        expect(result.keys.map((k) => k), containsAll([mainUri, depUri]));
      });

      test('avoids circular dependencies', () async {
        final doc1Uri = const IriTerm('https://example.com/doc1');
        final doc2Uri = const IriTerm('https://example.com/doc2');

        final doc1Graph = RdfGraph.fromTriples([
          Triple(
              doc1Uri, Rdf.type, const IriTerm('https://example.com/TestType')),
        ]);
        final doc2Graph = RdfGraph.fromTriples([
          Triple(
              doc2Uri, Rdf.type, const IriTerm('https://example.com/TestType')),
        ]);

        mockFetcher.setMockData(doc1Uri, doc1Graph);
        mockFetcher.setMockData(doc2Uri, doc2Graph);

        final extractor = TestDependencyExtractor(
          const IriTerm('https://example.com/TestType'),
          {
            doc1Uri: [doc2Uri],
            doc2Uri: [doc1Uri], // Circular dependency
          },
        );

        final result = await loader.loadRdfDocumentsRecursively(
          [doc1Uri],
          extractors: [extractor],
        );

        expect(result, hasLength(2));
        expect(result.keys.map((k) => k), containsAll([doc1Uri, doc2Uri]));
        expect(mockFetcher.fetchCount,
            equals(2)); // Each document fetched only once
      });
    });

    group('concurrent loading', () {
      test('deduplicates shared dependencies within single call', () async {
        final rootUri = const IriTerm('https://example.com/root');
        final sharedDepUri = const IriTerm('https://example.com/shared');
        final dep1Uri = const IriTerm('https://example.com/dep1');
        final dep2Uri = const IriTerm('https://example.com/dep2');

        final rootGraph = RdfGraph.fromTriples([
          Triple(
              rootUri, Rdf.type, const IriTerm('https://example.com/TestType')),
        ]);
        final sharedGraph = RdfGraph.fromTriples([
          Triple(sharedDepUri, Rdf.type,
              const IriTerm('https://example.com/TestType')),
        ]);
        final dep1Graph = RdfGraph.fromTriples([
          Triple(
              dep1Uri, Rdf.type, const IriTerm('https://example.com/TestType')),
        ]);
        final dep2Graph = RdfGraph.fromTriples([
          Triple(
              dep2Uri, Rdf.type, const IriTerm('https://example.com/TestType')),
        ]);

        final Completer<RdfGraph> sharedCompleter = Completer<RdfGraph>();

        mockFetcher.setMockData(rootUri, rootGraph);
        mockFetcher.setMockData(dep1Uri, dep1Graph);
        mockFetcher.setMockData(dep2Uri, dep2Graph);
        mockFetcher.setMockDataFuture(sharedDepUri, sharedCompleter.future);

        final extractor = TestDependencyExtractor(
          const IriTerm('https://example.com/TestType'),
          {
            rootUri: [dep1Uri, dep2Uri],
            dep1Uri: [sharedDepUri], // Both dep1 and dep2 depend on shared
            dep2Uri: [sharedDepUri], // This should be deduplicated
          },
        );

        // Start single recursive load
        final loadFuture = loader.loadRdfDocumentsRecursively(
          [rootUri],
          extractors: [extractor],
        );

        // Give time for dependencies to be discovered and start loading
        await Future.delayed(Duration(milliseconds: 50));

        // Complete the shared dependency
        sharedCompleter.complete(sharedGraph);

        final result = await loadFuture;

        expect(result, hasLength(4));
        expect(result.keys,
            containsAll([rootUri, dep1Uri, dep2Uri, sharedDepUri]));

        // Shared dependency should only be fetched once despite being referenced twice
        expect(mockFetcher.fetchCount,
            equals(4)); // root + dep1 + dep2 + shared (only once)
      });

      test('handles concurrent dependency loading', () async {
        final rootUri = const IriTerm('https://example.com/root');
        final sharedDepUri = const IriTerm('https://example.com/shared');
        final dep1Uri = const IriTerm('https://example.com/dep1');
        final dep2Uri = const IriTerm('https://example.com/dep2');

        final rootGraph = RdfGraph.fromTriples([
          Triple(
              rootUri, Rdf.type, const IriTerm('https://example.com/TestType')),
        ]);
        final sharedGraph = RdfGraph.fromTriples([
          Triple(sharedDepUri, Rdf.type,
              const IriTerm('https://example.com/TestType')),
        ]);
        final dep1Graph = RdfGraph.fromTriples([
          Triple(
              dep1Uri, Rdf.type, const IriTerm('https://example.com/TestType')),
        ]);
        final dep2Graph = RdfGraph.fromTriples([
          Triple(
              dep2Uri, Rdf.type, const IriTerm('https://example.com/TestType')),
        ]);

        mockFetcher.setMockData(rootUri, rootGraph);
        mockFetcher.setMockData(sharedDepUri, sharedGraph);
        mockFetcher.setMockData(dep1Uri, dep1Graph);
        mockFetcher.setMockData(dep2Uri, dep2Graph);

        final extractor = TestDependencyExtractor(
          const IriTerm('https://example.com/TestType'),
          {
            rootUri: [dep1Uri, dep2Uri],
            dep1Uri: [sharedDepUri],
            dep2Uri: [sharedDepUri], // Both depend on shared dependency
          },
        );

        final result = await loader.loadRdfDocumentsRecursively(
          [rootUri],
          extractors: [extractor],
        );

        expect(result, hasLength(4));
        expect(result.keys.map((k) => k),
            containsAll([rootUri, dep1Uri, dep2Uri, sharedDepUri]));
        expect(mockFetcher.fetchCount,
            equals(4)); // Each document fetched only once
      });
    });

    group('error handling', () {
      test('throws exception when document not found', () async {
        final nonExistentUri = const IriTerm('https://example.com/nonexistent');

        expect(
          () => loader.loadRdfDocumentsRecursively([nonExistentUri]),
          throwsException,
        );
      });

      test('propagates fetch errors during dependency loading', () async {
        final mainUri = const IriTerm('https://example.com/main');
        final badDepUri = const IriTerm('https://example.com/bad-dependency');

        final mainGraph = RdfGraph.fromTriples([
          Triple(
              mainUri, Rdf.type, const IriTerm('https://example.com/TestType')),
        ]);

        mockFetcher.setMockData(mainUri, mainGraph);
        // badDepUri is not set up, so it will throw

        final extractor = TestDependencyExtractor(
          const IriTerm('https://example.com/TestType'),
          {
            mainUri: [badDepUri]
          },
        );

        expect(
          () => loader.loadRdfDocumentsRecursively(
            [mainUri],
            extractors: [extractor],
          ),
          throwsException,
        );
      });

      test('handles empty input gracefully', () async {
        final result = await loader.loadRdfDocumentsRecursively([]);

        expect(result, isEmpty);
        expect(mockFetcher.fetchCount, equals(0));
      });

      test('handles extractor that returns no dependencies', () async {
        final testUri = const IriTerm('https://example.com/doc1');
        final testGraph = RdfGraph.fromTriples([
          Triple(
              testUri, Rdf.type, const IriTerm('https://example.com/TestType')),
        ]);

        mockFetcher.setMockData(testUri, testGraph);

        final extractor = TestDependencyExtractor(
          const IriTerm('https://example.com/TestType'),
          {}, // No dependencies defined
        );

        final result = await loader.loadRdfDocumentsRecursively(
          [testUri],
          extractors: [extractor],
        );

        expect(result, hasLength(1));
        expect(result.keys.first, equals(testUri));
        expect(mockFetcher.fetchCount, equals(1));
      });
    });

    group('IRI handling', () {
      test('normalizes fragment IRIs to document IRIs in dependencies',
          () async {
        final mainUri = const IriTerm('https://example.com/main');
        final depFragmentUri =
            const IriTerm('https://example.com/dependency#fragment');
        final depDocUri = const IriTerm('https://example.com/dependency');

        final mainGraph = RdfGraph.fromTriples([
          Triple(
              mainUri, Rdf.type, const IriTerm('https://example.com/TestType')),
        ]);
        final depGraph = RdfGraph.fromTriples([
          Triple(depDocUri, Rdf.type,
              const IriTerm('https://example.com/DepType')),
        ]);

        mockFetcher.setMockData(mainUri, mainGraph);
        mockFetcher.setMockData(depDocUri, depGraph);

        final extractor = TestDependencyExtractor(
          const IriTerm('https://example.com/TestType'),
          {
            mainUri: [depFragmentUri]
          }, // Extractor returns fragment IRI
        );

        final result = await loader.loadRdfDocumentsRecursively(
          [mainUri],
          extractors: [extractor],
        );

        expect(result, hasLength(2));
        expect(result.keys.map((k) => k), containsAll([mainUri, depDocUri]));
        expect(mockFetcher.fetchedUris, contains(depDocUri));
        expect(mockFetcher.fetchedUris, isNot(contains(depFragmentUri)));
      });

      test('uses custom IRI factory for document IRI extraction', () async {
        // Create a custom IRI factory that validates URIs
        IriTerm customIriFactory(String iri) {
          if (!iri.startsWith('https://example.com/')) {
            throw ArgumentError('Invalid URI: $iri');
          }
          return IriTerm.validated(iri);
        }

        final customLoader = RecursiveRdfLoader(
          fetcher: mockFetcher,
          iriFactory: customIriFactory,
        );

        final validUri = const IriTerm('https://example.com/doc1');
        final testGraph = RdfGraph.fromTriples([
          Triple(validUri, Rdf.type,
              const IriTerm('https://example.com/TestType')),
        ]);

        mockFetcher.setMockData(validUri, testGraph);

        final result =
            await customLoader.loadRdfDocumentsRecursively([validUri]);

        expect(result, hasLength(1));
        expect(result.keys.first, equals(validUri));
      });
    });
  });
}
