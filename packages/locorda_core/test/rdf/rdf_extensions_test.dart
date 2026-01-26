import 'package:locorda_core/src/vocab/generated/rdf.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/util/structure_validation_logger.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:test/test.dart';

void main() {
  group('RdfGraphExtensions', () {
    group('getIdentifier', () {
      test('returns subject IRI for single typed resource', () {
        final resourceIri = IriTerm('https://example.com/resource#it');
        final typeIri = IriTerm('https://example.com/TestType');

        final graph = RdfGraph.fromTriples([
          Triple(resourceIri, Rdf.type, typeIri),
        ]);

        final result = graph.getIdentifier(typeIri);
        expect(result, equals(resourceIri));
      });

      test('throws when no resource has the specified type', () {
        final graph = RdfGraph.fromTriples([
          Triple(
            IriTerm('https://example.com/resource#it'),
            IriTerm('https://example.com/someProp'),
            LiteralTerm('value'),
          ),
        ]);

        expect(
          () => graph
              .getIdentifier(IriTerm('https://example.com/NonExistentType')),
          throwsStateError,
        );
      });

      test('throws when multiple resources have the same type', () {
        final typeIri = IriTerm('https://example.com/TestType');
        final graph = RdfGraph.fromTriples([
          Triple(
              IriTerm('https://example.com/resource1#it'), Rdf.type, typeIri),
          Triple(
              IriTerm('https://example.com/resource2#it'), Rdf.type, typeIri),
        ]);

        expect(
          () => graph.getIdentifier(typeIri),
          throwsStateError,
        );
      });
    });

    group('findSingleObject', () {
      test('returns typed object when found', () {
        final subject = IriTerm('https://example.com/subject');
        final predicate = IriTerm('https://example.com/predicate');
        final object = IriTerm('https://example.com/object');

        final graph = RdfGraph.fromTriples([
          Triple(subject, predicate, object),
        ]);

        final result = graph.findSingleObject<IriTerm>(subject, predicate);
        expect(result, equals(object));
      });

      test('returns null when no triple exists', () {
        final graph = RdfGraph.fromTriples([]);

        final result = graph.findSingleObject<IriTerm>(
          IriTerm('https://example.com/subject'),
          IriTerm('https://example.com/predicate'),
        );

        expect(result, isNull);
      });

      test('returns null when object is wrong type', () {
        RdfExpectations.runWith(RdfExpectations.lenient(), () {
          final subject = IriTerm('https://example.com/subject');
          final predicate = IriTerm('https://example.com/predicate');
          final literal = LiteralTerm('value');

          final graph = RdfGraph.fromTriples([
            Triple(subject, predicate, literal),
          ]);

          final result = graph.findSingleObject<IriTerm>(subject, predicate);
          expect(result, isNull);
        });
      });

      test('throws when multiple triples exist for same subject-predicate', () {
        final subject = IriTerm('https://example.com/subject');
        final predicate = IriTerm('https://example.com/predicate');

        final graph = RdfGraph.fromTriples([
          Triple(subject, predicate, IriTerm('https://example.com/object1')),
          Triple(subject, predicate, IriTerm('https://example.com/object2')),
        ]);

        expect(
          () => graph.findSingleObject<IriTerm>(subject, predicate),
          throwsStateError,
        );
      });
    });

    group('getListObjects', () {
      test('returns empty list when property not found', () {
        final graph = RdfGraph.fromTriples([]);

        final result = graph.getListObjects<IriTerm>(
          IriTerm('https://example.com/subject'),
          IriTerm('https://example.com/predicate'),
        );

        expect(result, isEmpty);
      });

      test('returns empty list when property value is not RdfSubject', () {
        final subject = IriTerm('https://example.com/subject');
        final predicate = IriTerm('https://example.com/predicate');

        final graph = RdfGraph.fromTriples([
          Triple(subject, predicate, LiteralTerm('not a list')),
        ]);

        final result = graph.getListObjects<IriTerm>(subject, predicate);
        expect(result, isEmpty);
      });

      test('returns items from RDF list structure', () {
        final subject = IriTerm('https://example.com/subject');
        final predicate = IriTerm('https://example.com/listProp');
        final item1 = IriTerm('https://example.com/item1');
        final item2 = IriTerm('https://example.com/item2');
        final item3 = IriTerm('https://example.com/item3');

        final listNode1 = BlankNodeTerm();
        final listNode2 = BlankNodeTerm();
        final listNode3 = BlankNodeTerm();

        final graph = RdfGraph.fromTriples([
          Triple(subject, predicate, listNode1),
          Triple(listNode1, Rdf.first, item1),
          Triple(listNode1, Rdf.rest, listNode2),
          Triple(listNode2, Rdf.first, item2),
          Triple(listNode2, Rdf.rest, listNode3),
          Triple(listNode3, Rdf.first, item3),
          Triple(listNode3, Rdf.rest, Rdf.nil),
        ]);

        final result = graph.getListObjects<IriTerm>(subject, predicate);
        expect(result, equals([item1, item2, item3]));
      });

      test('filters by type parameter', () {
        final subject = IriTerm('https://example.com/subject');
        final predicate = IriTerm('https://example.com/listProp');
        final iriItem = IriTerm('https://example.com/item1');
        final literalItem = LiteralTerm('item2');

        final listNode1 = BlankNodeTerm();
        final listNode2 = BlankNodeTerm();

        final graph = RdfGraph.fromTriples([
          Triple(subject, predicate, listNode1),
          Triple(listNode1, Rdf.first, iriItem),
          Triple(listNode1, Rdf.rest, listNode2),
          Triple(listNode2, Rdf.first, literalItem),
          Triple(listNode2, Rdf.rest, Rdf.nil),
        ]);

        final iriResult = graph.getListObjects<IriTerm>(subject, predicate);
        expect(iriResult, equals([iriItem]));

        final literalResult =
            graph.getListObjects<LiteralTerm>(subject, predicate);
        expect(literalResult, equals([literalItem]));
      });
    });

    group('getMultiValueObjects', () {
      test('returns empty list when no triples found', () {
        final graph = RdfGraph.fromTriples([]);

        final result = graph.getMultiValueObjectList<IriTerm>(
          IriTerm('https://example.com/subject'),
          IriTerm('https://example.com/predicate'),
        );

        expect(result, isEmpty);
      });

      test('returns multiple values for same predicate', () {
        final subject = IriTerm('https://example.com/subject');
        final predicate = IriTerm('https://example.com/predicate');
        final value1 = IriTerm('https://example.com/value1');
        final value2 = IriTerm('https://example.com/value2');
        final value3 = IriTerm('https://example.com/value3');

        final graph = RdfGraph.fromTriples([
          Triple(subject, predicate, value1),
          Triple(subject, predicate, value2),
          Triple(subject, predicate, value3),
        ]);

        final result =
            graph.getMultiValueObjectList<IriTerm>(subject, predicate);
        expect(result, containsAll([value1, value2, value3]));
        expect(result, hasLength(3));
      });

      test('filters by type parameter', () {
        final subject = IriTerm('https://example.com/subject');
        final predicate = IriTerm('https://example.com/predicate');
        final iriValue = IriTerm('https://example.com/iri');
        final literalValue = LiteralTerm('literal');

        final graph = RdfGraph.fromTriples([
          Triple(subject, predicate, iriValue),
          Triple(subject, predicate, literalValue),
        ]);

        final iriResult =
            graph.getMultiValueObjectList<IriTerm>(subject, predicate);
        expect(iriResult, equals([iriValue]));

        final literalResult =
            graph.getMultiValueObjectList<LiteralTerm>(subject, predicate);
        expect(literalResult, equals([literalValue]));
      });
    });

    group('traverseListObjects', () {
      test('returns empty list for rdf:nil', () {
        final graph = RdfGraph.fromTriples([]);

        final result = graph.traverseListObjects<IriTerm>(Rdf.nil);
        expect(result, isEmpty);
      });

      test('traverses single-item list', () {
        final item = IriTerm('https://example.com/item');
        final listNode = BlankNodeTerm();

        final graph = RdfGraph.fromTriples([
          Triple(listNode, Rdf.first, item),
          Triple(listNode, Rdf.rest, Rdf.nil),
        ]);

        final result = graph.traverseListObjects<IriTerm>(listNode);
        expect(result, equals([item]));
      });

      test('traverses multi-item list', () {
        final item1 = IriTerm('https://example.com/item1');
        final item2 = IriTerm('https://example.com/item2');
        final item3 = IriTerm('https://example.com/item3');

        final listNode1 = BlankNodeTerm();
        final listNode2 = BlankNodeTerm();
        final listNode3 = BlankNodeTerm();

        final graph = RdfGraph.fromTriples([
          Triple(listNode1, Rdf.first, item1),
          Triple(listNode1, Rdf.rest, listNode2),
          Triple(listNode2, Rdf.first, item2),
          Triple(listNode2, Rdf.rest, listNode3),
          Triple(listNode3, Rdf.first, item3),
          Triple(listNode3, Rdf.rest, Rdf.nil),
        ]);

        final result = graph.traverseListObjects<IriTerm>(listNode1);
        expect(result, equals([item1, item2, item3]));
      });
    });
  });

  group('IriTermExtensions', () {
    group('localName', () {
      test('extracts name after hash', () {
        final iri = IriTerm('https://example.com/vocab#TestClass');
        expect(iri.localName, equals('TestClass'));
      });

      test('extracts name after last slash when no hash', () {
        final iri = IriTerm('https://example.com/vocab/TestClass');
        expect(iri.localName, equals('TestClass'));
      });

      test('prefers hash over slash', () {
        final iri = IriTerm('https://example.com/vocab/path#TestClass');
        expect(iri.localName, equals('TestClass'));
      });

      test('returns full IRI when no separators', () {
        final iri = IriTerm('TestClass');
        expect(iri.localName, equals('TestClass'));
      });

      test('returns empty string when hash/slash is at end', () {
        final hashIri = IriTerm('https://example.com/vocab#');
        expect(hashIri.localName, equals(''));

        final slashIri = IriTerm('https://example.com/vocab/');
        expect(slashIri.localName, equals(''));
      });

      test('handles multiple separators correctly', () {
        final iri = IriTerm('https://example.com/vocab/sub/path#TestClass');
        expect(iri.localName, equals('TestClass'));
      });
    });

    group('getDocumentIri', () {
      test('removes fragment identifier', () {
        final iri = IriTerm('https://example.com/doc.ttl#fragment');
        final result = iri.getDocumentIri();
        expect(result.value, equals('https://example.com/doc.ttl'));
      });

      test('returns self when no fragment', () {
        final iri = IriTerm('https://example.com/doc.ttl');
        final result = iri.getDocumentIri();
        expect(result, equals(iri));
      });

      test('handles multiple hash symbols correctly', () {
        final iri = IriTerm('https://example.com/path#hash#fragment');
        final result = iri.getDocumentIri();
        expect(result.value, equals('https://example.com/path#hash'));
      });

      test('uses custom IRI factory', () {
        IriTerm customFactory(String value) {
          return IriTerm('custom:$value');
        }

        final iri = IriTerm('https://example.com/doc#fragment');
        final result = iri.getDocumentIri(customFactory);
        expect(result.value, equals('custom:https://example.com/doc'));
      });

      test('returns self when hash is at end', () {
        final iri = IriTerm('https://example.com/doc#');
        final result = iri.getDocumentIri();
        expect(result.value, equals('https://example.com/doc'));
      });
    });
  });

  group('LiteralTermExtensions', () {
    group('boolean operations', () {
      test('detects boolean literals correctly', () {
        final trueLiteral = LiteralTerm('true',
            datatype: IriTerm('http://www.w3.org/2001/XMLSchema#boolean'));
        final falseLiteral = LiteralTerm('false',
            datatype: IriTerm('http://www.w3.org/2001/XMLSchema#boolean'));
        final stringLiteral = LiteralTerm('true',
            datatype: IriTerm('http://www.w3.org/2001/XMLSchema#string'));

        expect(trueLiteral.isBoolean, isTrue);
        expect(falseLiteral.isBoolean, isTrue);
        expect(stringLiteral.isBoolean, isFalse);
      });

      test('parses boolean values correctly', () {
        final trueLiteral = LiteralTerm('true',
            datatype: IriTerm('http://www.w3.org/2001/XMLSchema#boolean'));
        final falseLiteral = LiteralTerm('false',
            datatype: IriTerm('http://www.w3.org/2001/XMLSchema#boolean'));
        final oneLiteral = LiteralTerm('1',
            datatype: IriTerm('http://www.w3.org/2001/XMLSchema#boolean'));
        final zeroLiteral = LiteralTerm('0',
            datatype: IriTerm('http://www.w3.org/2001/XMLSchema#boolean'));

        expect(trueLiteral.booleanValue, isTrue);
        expect(falseLiteral.booleanValue, isFalse);
        expect(oneLiteral.booleanValue, isTrue);
        expect(zeroLiteral.booleanValue, isFalse);
      });

      test('throws when accessing boolean value of non-boolean', () {
        final stringLiteral = LiteralTerm('true',
            datatype: IriTerm('http://www.w3.org/2001/XMLSchema#string'));

        expect(() => stringLiteral.booleanValue, throwsStateError);
      });
    });

    group('integer operations', () {
      test('detects integer literals correctly', () {
        final integerLiteral = LiteralTerm('42',
            datatype: IriTerm('http://www.w3.org/2001/XMLSchema#integer'));
        final intLiteral = LiteralTerm('42',
            datatype: IriTerm('http://www.w3.org/2001/XMLSchema#int'));
        final stringLiteral = LiteralTerm('42',
            datatype: IriTerm('http://www.w3.org/2001/XMLSchema#string'));

        expect(integerLiteral.isInteger, isTrue);
        expect(intLiteral.isInteger, isTrue);
        expect(stringLiteral.isInteger, isFalse);
      });

      test('parses integer values correctly', () {
        final positiveLiteral = LiteralTerm('42',
            datatype: IriTerm('http://www.w3.org/2001/XMLSchema#integer'));
        final negativeLiteral = LiteralTerm('-123',
            datatype: IriTerm('http://www.w3.org/2001/XMLSchema#integer'));
        final zeroLiteral = LiteralTerm('0',
            datatype: IriTerm('http://www.w3.org/2001/XMLSchema#integer'));

        expect(positiveLiteral.integerValue, equals(42));
        expect(negativeLiteral.integerValue, equals(-123));
        expect(zeroLiteral.integerValue, equals(0));
      });

      test('throws when accessing integer value of non-integer', () {
        final stringLiteral = LiteralTerm('42',
            datatype: IriTerm('http://www.w3.org/2001/XMLSchema#string'));

        expect(() => stringLiteral.integerValue, throwsStateError);
      });
    });

    group('string operations', () {
      test('detects string literals correctly', () {
        final stringLiteral = LiteralTerm('hello',
            datatype: IriTerm('http://www.w3.org/2001/XMLSchema#string'));
        final langStringLiteral = LiteralTerm('hello', language: 'en');
        final integerLiteral = LiteralTerm('42',
            datatype: IriTerm('http://www.w3.org/2001/XMLSchema#integer'));

        expect(stringLiteral.isString, isTrue);
        expect(langStringLiteral.isString, isTrue);
        expect(integerLiteral.isString, isFalse);
      });

      test('returns string values correctly', () {
        final stringLiteral = LiteralTerm('hello world',
            datatype: IriTerm('http://www.w3.org/2001/XMLSchema#string'));

        expect(stringLiteral.stringValue, equals('hello world'));
      });

      test('throws when accessing string value of non-string', () {
        final integerLiteral = LiteralTerm('42',
            datatype: IriTerm('http://www.w3.org/2001/XMLSchema#integer'));

        expect(() => integerLiteral.stringValue, throwsStateError);
      });
    });

    group('double operations', () {
      test('detects double literals correctly', () {
        final doubleLiteral = LiteralTerm('3.14',
            datatype: IriTerm('http://www.w3.org/2001/XMLSchema#double'));
        final floatLiteral = LiteralTerm('2.71',
            datatype: IriTerm('http://www.w3.org/2001/XMLSchema#float'));
        final integerLiteral = LiteralTerm('42',
            datatype: IriTerm('http://www.w3.org/2001/XMLSchema#integer'));

        expect(doubleLiteral.isDouble, isTrue);
        expect(floatLiteral.isDouble, isTrue);
        expect(integerLiteral.isDouble, isFalse);
      });

      test('parses double values correctly', () {
        final doubleLiteral = LiteralTerm('3.14159',
            datatype: IriTerm('http://www.w3.org/2001/XMLSchema#double'));
        final negativeLiteral = LiteralTerm('-2.718',
            datatype: IriTerm('http://www.w3.org/2001/XMLSchema#double'));

        expect(doubleLiteral.doubleValue, closeTo(3.14159, 0.00001));
        expect(negativeLiteral.doubleValue, closeTo(-2.718, 0.001));
      });

      test('throws when accessing double value of non-double', () {
        final stringLiteral = LiteralTerm('3.14',
            datatype: IriTerm('http://www.w3.org/2001/XMLSchema#string'));

        expect(() => stringLiteral.doubleValue, throwsStateError);
      });
    });

    group('dateTime operations', () {
      test('detects dateTime literals correctly', () {
        final dateTimeLiteral = LiteralTerm('2023-05-15T14:30:00Z',
            datatype: IriTerm('http://www.w3.org/2001/XMLSchema#dateTime'));
        final stringLiteral = LiteralTerm('2023-05-15T14:30:00Z',
            datatype: IriTerm('http://www.w3.org/2001/XMLSchema#string'));

        expect(dateTimeLiteral.isDateTime, isTrue);
        expect(stringLiteral.isDateTime, isFalse);
      });

      test('parses dateTime values correctly', () {
        final dateTimeLiteral = LiteralTerm('2023-05-15T14:30:00Z',
            datatype: IriTerm('http://www.w3.org/2001/XMLSchema#dateTime'));

        final result = dateTimeLiteral.dateTimeValue;
        expect(result.year, equals(2023));
        expect(result.month, equals(5));
        expect(result.day, equals(15));
        expect(result.hour, equals(14));
        expect(result.minute, equals(30));
        expect(result.second, equals(0));
      });

      test('throws when accessing dateTime value of non-dateTime', () {
        final stringLiteral = LiteralTerm('2023-05-15T14:30:00Z',
            datatype: IriTerm('http://www.w3.org/2001/XMLSchema#string'));

        expect(() => stringLiteral.dateTimeValue, throwsStateError);
      });
    });

    group('date operations', () {
      test('detects date literals correctly', () {
        final dateLiteral = LiteralTerm('2023-05-15',
            datatype: IriTerm('http://www.w3.org/2001/XMLSchema#date'));
        final stringLiteral = LiteralTerm('2023-05-15',
            datatype: IriTerm('http://www.w3.org/2001/XMLSchema#string'));

        expect(dateLiteral.isDate, isTrue);
        expect(stringLiteral.isDate, isFalse);
      });

      test('parses date values correctly', () {
        final dateLiteral = LiteralTerm('2023-05-15',
            datatype: IriTerm('http://www.w3.org/2001/XMLSchema#date'));

        final result = dateLiteral.dateValue;
        expect(result.year, equals(2023));
        expect(result.month, equals(5));
        expect(result.day, equals(15));
      });

      test('throws when accessing date value of non-date', () {
        final stringLiteral = LiteralTerm('2023-05-15',
            datatype: IriTerm('http://www.w3.org/2001/XMLSchema#string'));

        expect(() => stringLiteral.dateValue, throwsStateError);
      });
    });
  });

  group('TripleListExtensions', () {
    group('addRdfList', () {
      test('creates rdf:nil for empty list', () {
        final triples = <Triple>[];
        final subject = IriTerm('https://example.com/subject');
        final predicate = IriTerm('https://example.com/listProp');

        triples.addRdfList(subject, predicate, []);

        expect(triples, hasLength(1));
        expect(triples.first.subject, equals(subject));
        expect(triples.first.predicate, equals(predicate));
        expect(triples.first.object, equals(Rdf.nil));
      });

      test('creates proper RDF list for single item', () {
        final triples = <Triple>[];
        final subject = IriTerm('https://example.com/subject');
        final predicate = IriTerm('https://example.com/listProp');
        final item = IriTerm('https://example.com/item');

        triples.addRdfList(subject, predicate, [item]);

        expect(triples, hasLength(3));

        // Find the head node
        final headTriple = triples.firstWhere(
            (t) => t.subject == subject && t.predicate == predicate);
        final headNode = headTriple.object as BlankNodeTerm;

        // Verify structure
        final firstTriple = triples.firstWhere(
            (t) => t.subject == headNode && t.predicate == Rdf.first);
        expect(firstTriple.object, equals(item));

        final restTriple = triples.firstWhere(
            (t) => t.subject == headNode && t.predicate == Rdf.rest);
        expect(restTriple.object, equals(Rdf.nil));
      });

      test('creates proper RDF list for multiple items', () {
        final triples = <Triple>[];
        final subject = IriTerm('https://example.com/subject');
        final predicate = IriTerm('https://example.com/listProp');
        final item1 = IriTerm('https://example.com/item1');
        final item2 = IriTerm('https://example.com/item2');
        final item3 = IriTerm('https://example.com/item3');

        triples.addRdfList(subject, predicate, [item1, item2, item3]);

        expect(triples,
            hasLength(7)); // 1 + 3 * 2 (head + 3 items * 2 triples each)

        // Verify we can traverse the list
        final graph = RdfGraph.fromTriples(triples);
        final result = graph.getListObjects<IriTerm>(subject, predicate);
        expect(result, equals([item1, item2, item3]));
      });

      test('handles mixed object types', () {
        final triples = <Triple>[];
        final subject = IriTerm('https://example.com/subject');
        final predicate = IriTerm('https://example.com/listProp');
        final iriItem = IriTerm('https://example.com/item');
        final literalItem = LiteralTerm('literal value');

        triples.addRdfList(subject, predicate, [iriItem, literalItem]);

        final graph = RdfGraph.fromTriples(triples);
        final allItems = graph.getListObjects<RdfObject>(subject, predicate);
        expect(allItems, equals([iriItem, literalItem]));
      });
    });

    group('addNodes', () {
      test('adds nodes with their triples', () {
        final triples = <Triple>[];
        final subject = IriTerm('https://example.com/subject');
        final predicate = IriTerm('https://example.com/predicate');

        final node1 = IriTerm('https://example.com/node1');
        final node1Graph = RdfGraph.fromTriples([
          Triple(node1, IriTerm('https://example.com/prop1'),
              LiteralTerm('value1')),
        ]);

        final node2 = BlankNodeTerm();
        final node2Graph = RdfGraph.fromTriples([
          Triple(node2, IriTerm('https://example.com/prop2'),
              LiteralTerm('value2')),
          Triple(node2, IriTerm('https://example.com/prop3'),
              LiteralTerm('value3')),
        ]);

        final nodes = [(node1, node1Graph), (node2, node2Graph)];
        triples.addNodes(subject, predicate, nodes);

        expect(triples,
            hasLength(5)); // 2 subject-predicate-object + 1 + 2 node triples

        // Check subject-predicate-object triples
        expect(
            triples
                .where((t) => t.subject == subject && t.predicate == predicate),
            hasLength(2));
        expect(triples.map((t) => t.object), containsAll([node1, node2]));

        // Check node triples are included
        expect(triples.where((t) => t.subject == node1), hasLength(1));
        expect(triples.where((t) => t.subject == node2), hasLength(2));
      });

      test('handles empty node list', () {
        final triples = <Triple>[];
        final subject = IriTerm('https://example.com/subject');
        final predicate = IriTerm('https://example.com/predicate');

        triples.addNodes(subject, predicate, []);

        expect(triples, isEmpty);
      });
    });

    group('toRdfGraph', () {
      test('converts triple list to RdfGraph', () {
        final triples = [
          Triple(
            IriTerm('https://example.com/subject'),
            IriTerm('https://example.com/predicate'),
            LiteralTerm('value'),
          ),
          Triple(
            IriTerm('https://example.com/subject2'),
            IriTerm('https://example.com/predicate2'),
            IriTerm('https://example.com/object2'),
          ),
        ];

        final graph = triples.toRdfGraph();

        expect(graph.triples, containsAll(triples));
        expect(graph.triples, hasLength(2));
      });

      test('handles empty triple list', () {
        final triples = <Triple>[];
        final graph = triples.toRdfGraph();

        expect(graph.triples, isEmpty);
      });
    });
  });

  group('RdfExpectations', () {
    test('strict mode (default) throws on violations', () {
      final graph = RdfGraph.fromTriples([]);
      final subject = IriTerm('https://example.com/subject');
      final predicate = IriTerm('https://example.com/predicate');

      expect(
        () => graph.expectSingleObject<IriTerm>(subject, predicate),
        throwsStateError,
      );
    });

    test('lenient mode logs but does not throw', () {
      RdfExpectations.runWith(
        const RdfExpectations.lenient(),
        () {
          final graph = RdfGraph.fromTriples([]);
          final subject = IriTerm('https://example.com/subject');
          final predicate = IriTerm('https://example.com/predicate');

          // Should not throw, just return null
          final result = graph.expectSingleObject<IriTerm>(subject, predicate);
          expect(result, isNull);
        },
      );
    });

    test('criticalOnly mode throws only on critical violations', () {
      RdfExpectations.runWith(
        const RdfExpectations.criticalOnly(),
        () {
          final graph = RdfGraph.fromTriples([]);
          final subject = IriTerm('https://example.com/subject');
          final predicate = IriTerm('https://example.com/predicate');

          // Major severity: should not throw in criticalOnly mode
          final result = graph.expectSingleObject<IriTerm>(subject, predicate);
          expect(result, isNull);

          // Critical severity: should throw even in criticalOnly mode
          expect(
            () => graph.expectSingleObject<IriTerm>(
              subject,
              predicate,
              severity: ExpectationSeverity.critical,
            ),
            throwsStateError,
          );
        },
      );
    });

    test('runWith restores previous instance after execution', () {
      final originalDefault = RdfExpectations.defaultInstance;

      RdfExpectations.runWith(
        const RdfExpectations.lenient(),
        () {
          expect(RdfExpectations.defaultInstance.strictnessLevel, isNull);
        },
      );

      expect(RdfExpectations.defaultInstance, same(originalDefault));
    });

    test('runWith restores previous instance even on exception', () {
      final originalDefault = RdfExpectations.defaultInstance;

      expect(
        () => RdfExpectations.runWith(
          const RdfExpectations.lenient(),
          () => throw Exception('test'),
        ),
        throwsException,
      );

      expect(RdfExpectations.defaultInstance, same(originalDefault));
    });
  });
}
