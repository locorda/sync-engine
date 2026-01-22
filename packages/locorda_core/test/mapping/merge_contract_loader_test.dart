import 'dart:async';

import 'package:locorda_core/src/config/validation.dart';
import 'package:locorda_core/src/crdt/crdt_types.dart';
import 'package:locorda_core/src/generated/_index.dart';
import 'package:locorda_core/src/mapping/merge_contract.dart';
import 'package:locorda_core/src/mapping/merge_contract_loader.dart';
import 'package:locorda_core/src/mapping/recursive_rdf_loader.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/rdf/xsd.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:test/test.dart';

class MockRecursiveRdfLoader extends RecursiveRdfLoader {
  final Map<IriTerm, RdfGraph> _mockData = {};
  final Set<IriTerm> _fetchedUris = {};
  int loadCallCount = 0;

  MockRecursiveRdfLoader()
      : super(fetcher: _MockFetcher(), iriFactory: IriTerm.validated);

  void setMockData(IriTerm uri, RdfGraph graph) {
    _mockData[uri] = graph;
  }

  void clear() {
    _mockData.clear();
    _fetchedUris.clear();
    loadCallCount = 0;
  }

  Set<IriTerm> get fetchedUris => Set.unmodifiable(_fetchedUris);

  @override
  Future<Map<IriTerm, RdfGraph>> loadRdfDocumentsRecursively(
    Iterable<IriTerm> iris, {
    List<DependencyExtractor> extractors = const [],
  }) async {
    loadCallCount++;
    final result = <IriTerm, RdfGraph>{};

    for (final iri in iris) {
      _fetchedUris.add(iri);
      final graph = _mockData[iri];
      if (graph != null) {
        result[iri] = graph;
      }
    }

    // Simulate dependency extraction for DocumentMappingDependencyExtractor
    for (final extractor in extractors) {
      if (extractor is DocumentMappingDependencyExtractor) {
        final additionalUris = <IriTerm>{};

        for (final entry in result.entries) {
          final dependencies =
              extractor.extractDependencies(entry.key, entry.value);
          for (final dep in dependencies) {
            if (!result.containsKey(dep) && _mockData.containsKey(dep)) {
              additionalUris.add(dep);
            }
          }
        }

        // Load dependencies
        for (final dep in additionalUris) {
          _fetchedUris.add(dep);
          final graph = _mockData[dep];
          if (graph != null) {
            result[dep] = graph;
          }
        }
      }
    }

    return result;
  }
}

class _MockFetcher implements RdfGraphFetcher {
  @override
  Future<RdfGraph> fetch(IriTerm iri) async {
    throw UnimplementedError('Should not be called in MockRecursiveRdfLoader');
  }
}

void main() {
  late CrdtTypeRegistry crdtTypeRegistry;

  late MockRecursiveRdfLoader mockLoader;
  late MergeContractLoader contractLoader;

  setUp(() {
    crdtTypeRegistry = CrdtTypeRegistry.forStandardTypes();
    mockLoader = MockRecursiveRdfLoader();
    contractLoader = StandardMergeContractLoader(mockLoader, crdtTypeRegistry);
  });

  tearDown(() {
    mockLoader.clear();
  });

  group('DocumentMappingDependencyExtractor', () {
    test('extracts no dependencies from document without mapping properties',
        () {
      final extractor = DocumentMappingDependencyExtractor();
      final docUri = const IriTerm('https://example.com/mapping');

      final graph = RdfGraph.fromTriples([
        Triple(docUri, Rdf.type, McDocumentMapping.classIri),
      ]);

      final dependencies = extractor.extractDependencies(docUri, graph);
      expect(dependencies, isEmpty);
    });

    test('extracts imports dependencies', () {
      final extractor = DocumentMappingDependencyExtractor();
      final docUri = const IriTerm('https://example.com/mapping');
      final import1 = const IriTerm('https://example.com/import1');
      final import2 = const IriTerm('https://example.com/import2');

      final triples = <Triple>[];
      triples.add(Triple(docUri, Rdf.type, McDocumentMapping.classIri));
      triples.addRdfList(docUri, McDocumentMapping.imports, [import1, import2]);

      final graph = RdfGraph.fromTriples(triples);

      final dependencies = extractor.extractDependencies(docUri, graph);
      expect(dependencies, containsAll([import1, import2]));
    });

    test('extracts class mapping dependencies', () {
      final extractor = DocumentMappingDependencyExtractor();
      final docUri = const IriTerm('https://example.com/mapping');
      final classMapping1 = const IriTerm('https://example.com/class1');
      final classMapping2 = const IriTerm('https://example.com/class2');

      final triples = <Triple>[];
      triples.add(Triple(docUri, Rdf.type, McDocumentMapping.classIri));
      triples.addRdfList(docUri, McDocumentMapping.classMapping,
          [classMapping1, classMapping2]);

      final graph = RdfGraph.fromTriples(triples);

      final dependencies = extractor.extractDependencies(docUri, graph);
      expect(dependencies, containsAll([classMapping1, classMapping2]));
    });

    test('extracts predicate mapping dependencies', () {
      final extractor = DocumentMappingDependencyExtractor();
      final docUri = const IriTerm('https://example.com/mapping');
      final predicateMapping1 = const IriTerm('https://example.com/predicate1');

      final triples = <Triple>[];
      triples.add(Triple(docUri, Rdf.type, McDocumentMapping.classIri));
      triples.addRdfList(
          docUri, McDocumentMapping.predicateMapping, [predicateMapping1]);

      final graph = RdfGraph.fromTriples(triples);

      final dependencies = extractor.extractDependencies(docUri, graph);
      expect(dependencies, contains(predicateMapping1));
    });

    test('extracts all dependency types combined', () {
      final extractor = DocumentMappingDependencyExtractor();
      final docUri = const IriTerm('https://example.com/mapping');
      final import1 = const IriTerm('https://example.com/import1');
      final classMapping1 = const IriTerm('https://example.com/class1');
      final predicateMapping1 = const IriTerm('https://example.com/predicate1');

      final triples = <Triple>[];
      triples.add(Triple(docUri, Rdf.type, McDocumentMapping.classIri));
      triples.addRdfList(docUri, McDocumentMapping.imports, [import1]);
      triples
          .addRdfList(docUri, McDocumentMapping.classMapping, [classMapping1]);
      triples.addRdfList(
          docUri, McDocumentMapping.predicateMapping, [predicateMapping1]);

      final graph = RdfGraph.fromTriples(triples);

      final dependencies = extractor.extractDependencies(docUri, graph);
      expect(dependencies,
          containsAll([import1, classMapping1, predicateMapping1]));
    });

    test('returns correct type filter', () {
      final extractor = DocumentMappingDependencyExtractor();
      expect(extractor.forType(), equals(McDocumentMapping.classIri));
    });
  });

  group('MergeContractLoader', () {
    group('basic loading', () {
      test('loads simple document mapping without dependencies', () async {
        final mappingUri = const IriTerm('https://example.com/mapping');
        final propertyUri = const IriTerm('https://example.com/property');
        final ruleNode = BlankNodeTerm();

        final mappingGraph = RdfGraph.fromTriples([
          Triple(mappingUri, Rdf.type, McDocumentMapping.classIri),
          Triple(ruleNode, McRule.predicate, propertyUri),
          Triple(ruleNode, McRule.algoMergeWith, Algo.LWW_Register),
        ]);

        // Add predicate mapping
        final triples = mappingGraph.triples.toList();
        triples.addRdfList(
            mappingUri, McDocumentMapping.predicateMapping, [ruleNode]);

        mockLoader.setMockData(mappingUri, RdfGraph.fromTriples(triples));

        final result = await contractLoader.load([mappingUri]);

        expect(result, isA<MergeContract>());
        expect(mockLoader.loadCallCount, equals(1));
        expect(mockLoader.fetchedUris, contains(mappingUri));
      });

      test('handles empty document list', () async {
        final result = await contractLoader.load([]);

        expect(result, isA<MergeContract>());
        expect(mockLoader.loadCallCount, equals(1));
        expect(mockLoader.fetchedUris, isEmpty);
      });
    });

    group('class mapping parsing', () {
      test('parses class mapping with rules', () async {
        final mappingUri = const IriTerm('https://example.com/mapping');
        final classMappingNode = BlankNodeTerm();
        final ruleNode = BlankNodeTerm();
        final classUri = const IriTerm('https://example.com/TestClass');
        final propertyUri = const IriTerm('https://example.com/property');

        final triples = <Triple>[
          Triple(mappingUri, Rdf.type, McDocumentMapping.classIri),
          Triple(classMappingNode, Rdf.type, McClassMapping.classIri),
          Triple(classMappingNode, McClassMapping.appliesToClass, classUri),
          Triple(classMappingNode, McClassMapping.rule, ruleNode),
          Triple(ruleNode, McRule.predicate, propertyUri),
          Triple(ruleNode, McRule.algoMergeWith, Algo.OR_Set),
          Triple(ruleNode, McRule.isIdentifying,
              LiteralTerm('true', datatype: Xsd.boolean)),
        ];
        triples.addRdfList(
            mappingUri, McDocumentMapping.classMapping, [classMappingNode]);

        mockLoader.setMockData(mappingUri, RdfGraph.fromTriples(triples));

        final result = await contractLoader.load([mappingUri]);

        final classMapping = result.getClassMapping(classUri);
        expect(classMapping, isNotNull);
        expect(classMapping!.classIri, equals(classUri));

        final rule = classMapping.getPropertyRule(propertyUri);
        expect(rule, isNotNull);
        expect(rule!.predicateIri, equals(propertyUri));
        expect(rule.mergeWith, equals(Algo.OR_Set));
        expect(rule.isIdentifying, isTrue);
      });

      test('rejects class mapping without appliesToClass', () async {
        final mappingUri = const IriTerm('https://example.com/mapping');
        final classMappingNode = BlankNodeTerm();

        final triples = <Triple>[
          Triple(mappingUri, Rdf.type, McDocumentMapping.classIri),
          Triple(classMappingNode, Rdf.type, McClassMapping.classIri),
          // Missing appliesToClass
        ];
        triples.addRdfList(
            mappingUri, McDocumentMapping.classMapping, [classMappingNode]);

        mockLoader.setMockData(mappingUri, RdfGraph.fromTriples(triples));

        // Should throw validation exception with helpful error message
        expect(
          () => contractLoader.load([mappingUri]),
          throwsA(isA<SyncConfigValidationException>().having(
            (e) => e.result.errors,
            'validation errors',
            contains(isA<ValidationError>().having(
              (err) => err.message,
              'error message',
              contains('missing appliesToClass'),
            )),
          )),
        );
      });

      test('rejects invalid class mapping reference', () async {
        final mappingUri = const IriTerm('https://example.com/mapping');
        final invalidNode = BlankNodeTerm();

        final triples = <Triple>[
          Triple(mappingUri, Rdf.type, McDocumentMapping.classIri),
          // invalidNode doesn't have proper type
        ];
        triples.addRdfList(
            mappingUri, McDocumentMapping.classMapping, [invalidNode]);

        mockLoader.setMockData(mappingUri, RdfGraph.fromTriples(triples));

        // Should throw validation exception
        expect(
          () => contractLoader.load([mappingUri]),
          throwsA(isA<SyncConfigValidationException>().having(
            (e) => e.result.errors,
            'validation errors',
            contains(isA<ValidationError>().having(
              (err) => err.message,
              'error message',
              contains('resolve class mapping reference'),
            )),
          )),
        );
      });

      test('handles duplicate class mappings', () async {
        final mappingUri = const IriTerm('https://example.com/mapping');
        final classMapping1 = BlankNodeTerm();
        final classMapping2 = BlankNodeTerm();
        final classUri = const IriTerm('https://example.com/TestClass');

        final triples = <Triple>[
          Triple(mappingUri, Rdf.type, McDocumentMapping.classIri),
          Triple(classMapping1, Rdf.type, McClassMapping.classIri),
          Triple(classMapping1, McClassMapping.appliesToClass, classUri),
          Triple(classMapping2, Rdf.type, McClassMapping.classIri),
          Triple(classMapping2, McClassMapping.appliesToClass,
              classUri), // Duplicate
        ];
        triples.addRdfList(mappingUri, McDocumentMapping.classMapping,
            [classMapping1, classMapping2]);

        mockLoader.setMockData(mappingUri, RdfGraph.fromTriples(triples));

        final result = await contractLoader.load([mappingUri]);

        // Should load but log warning about duplicate
        final classMapping = result.getClassMapping(classUri);
        expect(classMapping, isNotNull);
      });
    });

    group('predicate mapping parsing', () {
      test('parses predicate mapping with rules', () async {
        final mappingUri = const IriTerm('https://example.com/mapping');
        final predicateMappingNode = BlankNodeTerm();
        final ruleNode = BlankNodeTerm();
        final propertyUri = const IriTerm('https://example.com/property');

        final triples = <Triple>[
          Triple(mappingUri, Rdf.type, McDocumentMapping.classIri),
          Triple(predicateMappingNode, Rdf.type, McPredicateMapping.classIri),
          Triple(predicateMappingNode, McPredicateMapping.rule, ruleNode),
          Triple(ruleNode, McRule.predicate, propertyUri),
          Triple(ruleNode, McRule.algoMergeWith, Algo.LWW_Register),
          Triple(ruleNode, McRule.stopTraversal,
              LiteralTerm('true', datatype: Xsd.boolean)),
        ];
        triples.addRdfList(mappingUri, McDocumentMapping.predicateMapping,
            [predicateMappingNode]);

        mockLoader.setMockData(mappingUri, RdfGraph.fromTriples(triples));

        final result = await contractLoader.load([mappingUri]);

        final rule = result.getPredicateMapping(propertyUri);
        expect(rule, isNotNull);
        expect(rule!.predicateIri, equals(propertyUri));
        expect(rule.mergeWith, equals(Algo.LWW_Register));
        expect(rule.stopTraversal, isTrue);
        expect(rule.isIdentifying, isNull); // Not explicitly set
      });

      test('handles invalid predicate mapping reference', () async {
        final mappingUri = const IriTerm('https://example.com/mapping');
        final invalidNode = BlankNodeTerm();

        final triples = <Triple>[
          Triple(mappingUri, Rdf.type, McDocumentMapping.classIri),
          // invalidNode doesn't have proper type
        ];
        triples.addRdfList(
            mappingUri, McDocumentMapping.predicateMapping, [invalidNode]);

        mockLoader.setMockData(mappingUri, RdfGraph.fromTriples(triples));

        final result = await contractLoader.load([mappingUri]);

        // Should load successfully but skip the invalid reference
        expect(result, isA<MergeContract>());
      });
    });

    group('rule parsing', () {
      test('parses rule with all properties', () async {
        final mappingUri = const IriTerm('https://example.com/mapping');
        final predicateMappingNode = BlankNodeTerm();
        final ruleNode = BlankNodeTerm();
        final propertyUri = const IriTerm('https://example.com/property');

        final triples = <Triple>[
          Triple(mappingUri, Rdf.type, McDocumentMapping.classIri),
          Triple(predicateMappingNode, Rdf.type, McPredicateMapping.classIri),
          Triple(predicateMappingNode, McPredicateMapping.rule, ruleNode),
          Triple(ruleNode, McRule.predicate, propertyUri),
          Triple(ruleNode, McRule.algoMergeWith, Algo.G_Register),
          Triple(ruleNode, McRule.stopTraversal,
              LiteralTerm('true', datatype: Xsd.boolean)),
          Triple(ruleNode, McRule.isIdentifying,
              LiteralTerm('true', datatype: Xsd.boolean)),
        ];
        triples.addRdfList(mappingUri, McDocumentMapping.predicateMapping,
            [predicateMappingNode]);

        mockLoader.setMockData(mappingUri, RdfGraph.fromTriples(triples));

        final result = await contractLoader.load([mappingUri]);

        final rule = result.getPredicateMapping(propertyUri);
        expect(rule, isNotNull);
        expect(rule!.predicateIri, equals(propertyUri));
        expect(rule.mergeWith, equals(Algo.G_Register));
        expect(rule.stopTraversal, isTrue);
        expect(rule.isIdentifying, isTrue);
      });

      test('parses rule with minimal properties', () async {
        final mappingUri = const IriTerm('https://example.com/mapping');
        final predicateMappingNode = BlankNodeTerm();
        final ruleNode = BlankNodeTerm();
        final propertyUri = const IriTerm('https://example.com/property');

        final triples = <Triple>[
          Triple(mappingUri, Rdf.type, McDocumentMapping.classIri),
          Triple(predicateMappingNode, Rdf.type, McPredicateMapping.classIri),
          Triple(predicateMappingNode, McPredicateMapping.rule, ruleNode),
          Triple(ruleNode, McRule.predicate, propertyUri),
          // Missing optional properties
        ];
        triples.addRdfList(mappingUri, McDocumentMapping.predicateMapping,
            [predicateMappingNode]);

        mockLoader.setMockData(mappingUri, RdfGraph.fromTriples(triples));

        final result = await contractLoader.load([mappingUri]);

        final rule = result.getPredicateMapping(propertyUri);
        expect(rule, isNotNull);
        expect(rule!.predicateIri, equals(propertyUri));
        expect(rule.mergeWith, isNull);
        expect(rule.stopTraversal, isNull); // Not explicitly set
        expect(rule.isIdentifying, isNull); // Not explicitly set
      });

      test('rejects rule without predicate', () async {
        final mappingUri = const IriTerm('https://example.com/mapping');
        final predicateMappingNode = BlankNodeTerm();
        final ruleNode = BlankNodeTerm();

        final triples = <Triple>[
          Triple(mappingUri, Rdf.type, McDocumentMapping.classIri),
          Triple(predicateMappingNode, Rdf.type, McPredicateMapping.classIri),
          Triple(predicateMappingNode, McPredicateMapping.rule, ruleNode),
          // Missing required predicate
          Triple(ruleNode, McRule.algoMergeWith, Algo.LWW_Register),
        ];
        triples.addRdfList(mappingUri, McDocumentMapping.predicateMapping,
            [predicateMappingNode]);

        mockLoader.setMockData(mappingUri, RdfGraph.fromTriples(triples));

        // Should throw validation exception
        expect(
          () => contractLoader.load([mappingUri]),
          throwsA(isA<SyncConfigValidationException>().having(
            (e) => e.result.errors,
            'validation errors',
            contains(isA<ValidationError>().having(
              (err) => err.message,
              'error message',
              contains('missing mc:predicate'),
            )),
          )),
        );
      });
    });

    group('imports and dependencies', () {
      test('loads document with imports', () async {
        final mainUri = const IriTerm('https://example.com/main');
        final importUri = const IriTerm('https://example.com/import');
        final propertyUri = const IriTerm('https://example.com/property');

        // Main document
        final mainTriples = <Triple>[
          Triple(mainUri, Rdf.type, McDocumentMapping.classIri),
        ];
        mainTriples.addRdfList(mainUri, McDocumentMapping.imports, [importUri]);

        // Import document
        final ruleNode = BlankNodeTerm();
        final predicateMappingNode = BlankNodeTerm();
        final importTriples = <Triple>[
          Triple(importUri, Rdf.type, McDocumentMapping.classIri),
          Triple(predicateMappingNode, Rdf.type, McPredicateMapping.classIri),
          Triple(predicateMappingNode, McPredicateMapping.rule, ruleNode),
          Triple(ruleNode, McRule.predicate, propertyUri),
          Triple(ruleNode, McRule.algoMergeWith, Algo.OR_Set),
        ];
        importTriples.addRdfList(importUri, McDocumentMapping.predicateMapping,
            [predicateMappingNode]);

        mockLoader.setMockData(mainUri, RdfGraph.fromTriples(mainTriples));
        mockLoader.setMockData(importUri, RdfGraph.fromTriples(importTriples));

        final result = await contractLoader.load([mainUri]);

        expect(result, isA<MergeContract>());
        expect(mockLoader.fetchedUris, containsAll([mainUri, importUri]));

        // Should be able to access rules from imported document
        final rule = result.getPredicateMapping(propertyUri);
        expect(rule, isNotNull);
        expect(rule!.mergeWith, equals(Algo.OR_Set));
      });

      test('rejects circular imports', () async {
        final doc1Uri = const IriTerm('https://example.com/doc1');
        final doc2Uri = const IriTerm('https://example.com/doc2');

        // Document 1 imports Document 2
        final doc1Triples = <Triple>[
          Triple(doc1Uri, Rdf.type, McDocumentMapping.classIri),
        ];
        doc1Triples.addRdfList(doc1Uri, McDocumentMapping.imports, [doc2Uri]);

        // Document 2 imports Document 1 (circular)
        final doc2Triples = <Triple>[
          Triple(doc2Uri, Rdf.type, McDocumentMapping.classIri),
        ];
        doc2Triples.addRdfList(doc2Uri, McDocumentMapping.imports, [doc1Uri]);

        mockLoader.setMockData(doc1Uri, RdfGraph.fromTriples(doc1Triples));
        mockLoader.setMockData(doc2Uri, RdfGraph.fromTriples(doc2Triples));

        // Should throw validation exception for circular import
        expect(
          () => contractLoader.load([doc1Uri]),
          throwsA(isA<SyncConfigValidationException>().having(
            (e) => e.result.errors,
            'validation errors',
            contains(isA<ValidationError>().having(
              (err) => err.message,
              'error message',
              contains('Cyclic import'),
            )),
          )),
        );
      });
    });

    group('complex scenarios', () {
      test('loads document with mixed mapping types and imports', () async {
        final mainUri = const IriTerm('https://example.com/main');
        final importUri = const IriTerm('https://example.com/import');
        final classUri = const IriTerm('https://example.com/TestClass');
        final property1Uri = const IriTerm('https://example.com/property1');
        final property2Uri = const IriTerm('https://example.com/property2');

        // Main document with class mapping and predicate mapping
        final classMappingNode = BlankNodeTerm();
        final classRuleNode = BlankNodeTerm();
        final predicateMappingNode = BlankNodeTerm();
        final predicateRuleNode = BlankNodeTerm();

        final mainTriples = <Triple>[
          Triple(mainUri, Rdf.type, McDocumentMapping.classIri),
          // Class mapping
          Triple(classMappingNode, Rdf.type, McClassMapping.classIri),
          Triple(classMappingNode, McClassMapping.appliesToClass, classUri),
          Triple(classMappingNode, McClassMapping.rule, classRuleNode),
          Triple(classRuleNode, McRule.predicate, property1Uri),
          Triple(classRuleNode, McRule.algoMergeWith, Algo.LWW_Register),
          // Predicate mapping
          Triple(predicateMappingNode, Rdf.type, McPredicateMapping.classIri),
          Triple(
              predicateMappingNode, McPredicateMapping.rule, predicateRuleNode),
          Triple(predicateRuleNode, McRule.predicate, property2Uri),
          Triple(predicateRuleNode, McRule.algoMergeWith, Algo.OR_Set),
        ];
        mainTriples.addRdfList(mainUri, McDocumentMapping.imports, [importUri]);
        mainTriples.addRdfList(
            mainUri, McDocumentMapping.classMapping, [classMappingNode]);
        mainTriples.addRdfList(mainUri, McDocumentMapping.predicateMapping,
            [predicateMappingNode]);

        // Import document - just basic structure
        final importTriples = <Triple>[
          Triple(importUri, Rdf.type, McDocumentMapping.classIri),
        ];

        mockLoader.setMockData(mainUri, RdfGraph.fromTriples(mainTriples));
        mockLoader.setMockData(importUri, RdfGraph.fromTriples(importTriples));

        final result = await contractLoader.load([mainUri]);

        expect(result, isA<MergeContract>());

        // Check class mapping
        final classMapping = result.getClassMapping(classUri);
        expect(classMapping, isNotNull);
        final classRule = classMapping!.getPropertyRule(property1Uri);
        expect(classRule, isNotNull);
        expect(classRule!.mergeWith, equals(Algo.LWW_Register));

        // Check predicate mapping
        final predicateRule = result.getPredicateMapping(property2Uri);
        expect(predicateRule, isNotNull);
        expect(predicateRule!.mergeWith, equals(Algo.OR_Set));
      });

      test('handles multiple documents in isGovernedBy list', () async {
        final doc1Uri = const IriTerm('https://example.com/doc1');
        final doc2Uri = const IriTerm('https://example.com/doc2');
        final property1Uri = const IriTerm('https://example.com/property1');
        final property2Uri = const IriTerm('https://example.com/property2');

        // Document 1
        final predicateMapping1 = BlankNodeTerm();
        final rule1 = BlankNodeTerm();
        final doc1Triples = <Triple>[
          Triple(doc1Uri, Rdf.type, McDocumentMapping.classIri),
          Triple(predicateMapping1, Rdf.type, McPredicateMapping.classIri),
          Triple(predicateMapping1, McPredicateMapping.rule, rule1),
          Triple(rule1, McRule.predicate, property1Uri),
          Triple(rule1, McRule.algoMergeWith, Algo.LWW_Register),
        ];
        doc1Triples.addRdfList(
            doc1Uri, McDocumentMapping.predicateMapping, [predicateMapping1]);

        // Document 2
        final predicateMapping2 = BlankNodeTerm();
        final rule2 = BlankNodeTerm();
        final doc2Triples = <Triple>[
          Triple(doc2Uri, Rdf.type, McDocumentMapping.classIri),
          Triple(predicateMapping2, Rdf.type, McPredicateMapping.classIri),
          Triple(predicateMapping2, McPredicateMapping.rule, rule2),
          Triple(rule2, McRule.predicate, property2Uri),
          Triple(rule2, McRule.algoMergeWith, Algo.OR_Set),
        ];
        doc2Triples.addRdfList(
            doc2Uri, McDocumentMapping.predicateMapping, [predicateMapping2]);

        mockLoader.setMockData(doc1Uri, RdfGraph.fromTriples(doc1Triples));
        mockLoader.setMockData(doc2Uri, RdfGraph.fromTriples(doc2Triples));

        final result = await contractLoader.load([doc1Uri, doc2Uri]);

        expect(result, isA<MergeContract>());
        expect(mockLoader.fetchedUris, containsAll([doc1Uri, doc2Uri]));

        // Should have rules from both documents
        final rule1Result = result.getPredicateMapping(property1Uri);
        expect(rule1Result, isNotNull);
        expect(rule1Result!.mergeWith, equals(Algo.LWW_Register));

        final rule2Result = result.getPredicateMapping(property2Uri);
        expect(rule2Result, isNotNull);
        expect(rule2Result!.mergeWith, equals(Algo.OR_Set));
      });
    });

    group('error scenarios', () {
      test('handles missing document', () async {
        final mappingUri = const IriTerm('https://example.com/missing');

        // Don't set mock data - document will be missing

        final result = await contractLoader.load([mappingUri]);

        expect(result, isA<MergeContract>());
        expect(mockLoader.fetchedUris, contains(mappingUri));
      });

      test('integrates with recursive loader extractors', () async {
        final mappingUri = const IriTerm('https://example.com/mapping');

        final mappingGraph = RdfGraph.fromTriples([
          Triple(mappingUri, Rdf.type, McDocumentMapping.classIri),
        ]);

        mockLoader.setMockData(mappingUri, mappingGraph);

        await contractLoader.load([mappingUri]);

        // Verify that DocumentMappingDependencyExtractor was used
        expect(mockLoader.loadCallCount, equals(1));
      });
    });
  });
}
