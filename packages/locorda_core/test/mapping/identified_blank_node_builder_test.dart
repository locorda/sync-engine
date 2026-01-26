import 'package:locorda_core/src/config/validation.dart';
import 'package:locorda_core/src/vocab/generated/_index.dart';
import 'package:locorda_core/src/mapping/framework_iri_generator.dart';
import 'package:locorda_core/src/mapping/identified_blank_node_builder.dart';
import 'package:locorda_core/src/mapping/merge_contract.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:test/test.dart';

IdentifiedBlankNodes<IdentifiedBlankNode> computeIdentifiedBlankNodes(
        RdfGraph graph, MergeContract mergeContract) =>
    IdentifiedBlankNodeBuilder(iriGenerator: FrameworkIriGenerator())
        .computeIdentifiedBlankNodes(graph, mergeContract, (ibn) => ibn);

void main() {
  group('BlankNodeParent', () {
    group('constructor and getters', () {
      test('creates parent from IRI', () {
        final iri = const IriTerm('https://example.com/resource');
        final parent = IdentifiedBlankNodeParent.forIri(iri);

        expect(parent.iriTerm, equals(iri));
        expect(parent.blankNode, isNull);
      });

      test('creates parent from IdentifiedBlankNode', () {
        final iri = const IriTerm('https://example.com/resource');
        final identifiedNode = IdentifiedBlankNode(
          IdentifiedBlankNodeParent.forIri(iri),
          {
            const IriTerm('https://example.com/prop'): [LiteralTerm('value')]
          },
        );
        final parent =
            IdentifiedBlankNodeParent.forIdentifiedBlankNode(identifiedNode);

        expect(parent.iriTerm, isNull);
        expect(parent.blankNode, equals(identifiedNode));
      });
    });

    group('equality and hashCode', () {
      test('equal IRI parents are equal', () {
        final iri = const IriTerm('https://example.com/resource');
        final parent1 = IdentifiedBlankNodeParent.forIri(iri);
        final parent2 = IdentifiedBlankNodeParent.forIri(iri);

        expect(parent1, equals(parent2));
        expect(parent1.hashCode, equals(parent2.hashCode));
      });

      test('different IRI parents are not equal', () {
        final parent1 = IdentifiedBlankNodeParent.forIri(
            const IriTerm('https://example.com/resource1'));
        final parent2 = IdentifiedBlankNodeParent.forIri(
            const IriTerm('https://example.com/resource2'));

        expect(parent1, isNot(equals(parent2)));
      });

      test('equal IdentifiedBlankNode parents are equal', () {
        final iri = const IriTerm('https://example.com/resource');
        final identifiedNode = IdentifiedBlankNode(
          IdentifiedBlankNodeParent.forIri(iri),
          {
            const IriTerm('https://example.com/prop'): [LiteralTerm('value')]
          },
        );
        final parent1 =
            IdentifiedBlankNodeParent.forIdentifiedBlankNode(identifiedNode);
        final parent2 =
            IdentifiedBlankNodeParent.forIdentifiedBlankNode(identifiedNode);

        expect(parent1, equals(parent2));
        expect(parent1.hashCode, equals(parent2.hashCode));
      });

      test('IRI and IdentifiedBlankNode parents are not equal', () {
        final iri = const IriTerm('https://example.com/resource');
        final identifiedNode = IdentifiedBlankNode(
          IdentifiedBlankNodeParent.forIri(iri),
          {
            const IriTerm('https://example.com/prop'): [LiteralTerm('value')]
          },
        );
        final parent1 = IdentifiedBlankNodeParent.forIri(iri);
        final parent2 =
            IdentifiedBlankNodeParent.forIdentifiedBlankNode(identifiedNode);

        expect(parent1, isNot(equals(parent2)));
      });

      test('identity check works', () {
        final iri = const IriTerm('https://example.com/resource');
        final parent = IdentifiedBlankNodeParent.forIri(iri);

        expect(parent, equals(parent));
      });
    });
  });

  group('IdentifiedBlankNode', () {
    group('constructor and getters', () {
      test('creates IdentifiedBlankNode with IRI parent', () {
        final iri = const IriTerm('https://example.com/resource');
        final parent = IdentifiedBlankNodeParent.forIri(iri);
        final properties = {
          const IriTerm('https://example.com/prop1'): [LiteralTerm('value1')],
          const IriTerm('https://example.com/prop2'): [
            LiteralTerm('value2'),
            LiteralTerm('value3')
          ],
        };

        final identifiedNode = IdentifiedBlankNode(parent, properties);

        expect(identifiedNode.parent, equals(parent));
        expect(identifiedNode.identifyingProperties, equals(properties));
        expect(identifiedNode.identifyingProperties,
            isA<Map<RdfPredicate, List<RdfObject>>>());
        // Verify it's unmodifiable
        expect(
            () => identifiedNode.identifyingProperties[const IriTerm('test')] =
                [],
            throwsUnsupportedError);
      });

      test('throws assertion error when properties are empty', () {
        final parent = IdentifiedBlankNodeParent.forIri(
            const IriTerm('https://example.com/resource'));

        expect(
          () => IdentifiedBlankNode(parent, <IriTerm, List<RdfObject>>{}),
          throwsA(isA<AssertionError>()),
        );
      });
    });

    group('equality and hashCode', () {
      test('equal IdentifiedBlankNodes are equal', () {
        final parent = IdentifiedBlankNodeParent.forIri(
            const IriTerm('https://example.com/resource'));
        final properties = {
          const IriTerm('https://example.com/prop'): [LiteralTerm('value')],
        };

        final node1 = IdentifiedBlankNode(parent, properties);
        final node2 = IdentifiedBlankNode(parent, properties);

        expect(node1, equals(node2));
        expect(node1.hashCode, equals(node2.hashCode));
      });

      test('IdentifiedBlankNodes with different parents are not equal', () {
        final parent1 = IdentifiedBlankNodeParent.forIri(
            const IriTerm('https://example.com/resource1'));
        final parent2 = IdentifiedBlankNodeParent.forIri(
            const IriTerm('https://example.com/resource2'));
        final properties = {
          const IriTerm('https://example.com/prop'): [LiteralTerm('value')],
        };

        final node1 = IdentifiedBlankNode(parent1, properties);
        final node2 = IdentifiedBlankNode(parent2, properties);

        expect(node1, isNot(equals(node2)));
      });

      test('IdentifiedBlankNodes with different properties are not equal', () {
        final parent = IdentifiedBlankNodeParent.forIri(
            const IriTerm('https://example.com/resource'));
        final properties1 = {
          const IriTerm('https://example.com/prop'): [LiteralTerm('value1')],
        };
        final properties2 = {
          const IriTerm('https://example.com/prop'): [LiteralTerm('value2')],
        };

        final node1 = IdentifiedBlankNode(parent, properties1);
        final node2 = IdentifiedBlankNode(parent, properties2);

        expect(node1, isNot(equals(node2)));
      });

      test(
          'IdentifiedBlankNodes with same properties in different order are equal',
          () {
        final parent = IdentifiedBlankNodeParent.forIri(
            const IriTerm('https://example.com/resource'));
        final properties1 = {
          const IriTerm('https://example.com/prop1'): [LiteralTerm('value1')],
          const IriTerm('https://example.com/prop2'): [LiteralTerm('value2')],
        };
        final properties2 = {
          const IriTerm('https://example.com/prop2'): [LiteralTerm('value2')],
          const IriTerm('https://example.com/prop1'): [LiteralTerm('value1')],
        };

        final node1 = IdentifiedBlankNode(parent, properties1);
        final node2 = IdentifiedBlankNode(parent, properties2);

        expect(node1, equals(node2));
      });

      test(
          'IdentifiedBlankNodes with multi-value properties are handled correctly',
          () {
        final parent = IdentifiedBlankNodeParent.forIri(
            const IriTerm('https://example.com/resource'));
        final properties1 = {
          const IriTerm('https://example.com/prop'): [
            LiteralTerm('value1'),
            LiteralTerm('value2')
          ],
        };
        final properties2 = {
          const IriTerm('https://example.com/prop'): [
            LiteralTerm('value2'),
            LiteralTerm('value1')
          ],
        };

        final node1 = IdentifiedBlankNode(parent, properties1);
        final node2 = IdentifiedBlankNode(parent, properties2);

        expect(node1, equals(node2)); // Order shouldn't matter
      });

      test('identity check works', () {
        final parent = IdentifiedBlankNodeParent.forIri(
            const IriTerm('https://example.com/resource'));
        final properties = {
          const IriTerm('https://example.com/prop'): [LiteralTerm('value')],
        };
        final node = IdentifiedBlankNode(parent, properties);

        expect(node, equals(node));
      });
    });

    group('toString', () {
      test('provides readable string representation', () {
        final parent = IdentifiedBlankNodeParent.forIri(
            const IriTerm('https://example.com/resource'));
        final properties = {
          const IriTerm('https://example.com/prop'): [LiteralTerm('value')],
        };
        final node = IdentifiedBlankNode(parent, properties);

        final str = node.toString();
        expect(str, contains('IdentifiedBlankNode'));
        expect(str, contains('parent:'));
        expect(str, contains('properties:'));
      });
    });
  });

  group('computeIdentifiedBlankNodes', () {
    MergeContract createMergeContract({
      Set<IriTerm> globalIdentifyingPredicates = const {},
      Map<IriTerm, Set<IriTerm>> classIdentifyingPredicates = const {},
      Map<IriTerm, Set<IriTerm>> classNonIdentifyingPredicates = const {},
      Map<IriTerm, Map<IriTerm, IriTerm>> classPredicateAlgorithms = const {},
      Map<IriTerm, Set<IriTerm>>
          classDisableBlankNodePathIdentificationPredicates = const {},
    }) {
      final classMappings = <IriTerm, ClassMergeRules>{};

      // Collect all class IRIs that have any rules
      final allClassIris = {
        ...classIdentifyingPredicates.keys,
        ...classNonIdentifyingPredicates.keys,
        ...classPredicateAlgorithms.keys,
        ...classDisableBlankNodePathIdentificationPredicates.keys,
      };

      for (final classIri in allClassIris) {
        final identifyingPreds =
            classIdentifyingPredicates[classIri] ?? const {};
        final nonIdentifyingPreds =
            classNonIdentifyingPredicates[classIri] ?? const {};
        final predicateAlgos =
            classPredicateAlgorithms[classIri] ?? const <IriTerm, IriTerm>{};
        final disablePathIdPreds =
            classDisableBlankNodePathIdentificationPredicates[classIri] ??
                const {};

        final rules = <IriTerm, PredicateMergeRule>{
          // Add all predicates that have any configuration
          for (final pred in {
            ...identifyingPreds,
            ...nonIdentifyingPreds,
            ...predicateAlgos.keys,
            ...disablePathIdPreds,
          })
            pred: PredicateMergeRule(
              predicateIri: pred,
              mergeWith: predicateAlgos[pred],
              stopTraversal: false,
              isIdentifying: identifyingPreds.contains(pred)
                  ? true
                  : nonIdentifyingPreds.contains(pred)
                      ? false
                      : null,
              isPathIdentifying: !disablePathIdPreds.contains(pred),
            ),
        };

        classMappings[classIri] = ClassMergeRules(classIri, rules);
      }

      final predicateRules = {
        for (final pred in globalIdentifyingPredicates)
          pred: PredicateMergeRule(
            predicateIri: pred,
            mergeWith: null,
            stopTraversal: false,
            isIdentifying: true,
            isPathIdentifying: true,
          )
      };

      return MergeContract(classMappings, predicateRules);
    }

    group('basic functionality', () {
      test('returns empty result for graph without blank nodes', () {
        final graph = RdfGraph.fromTriples([
          Triple(
            const IriTerm('https://example.com/resource'),
            const IriTerm('https://example.com/prop'),
            LiteralTerm('value'),
          ),
        ]);
        final mergeContract = createMergeContract();

        final result = computeIdentifiedBlankNodes(graph, mergeContract);

        expect(result.identifiedMap, isEmpty);
      });

      test(
          'returns empty result for blank nodes without identifying properties',
          () {
        final blankNode = BlankNodeTerm();
        final graph = RdfGraph.fromTriples([
          Triple(
            const IriTerm('https://example.com/resource'),
            const IriTerm('https://example.com/hasBlankNode'),
            blankNode,
          ),
          Triple(
            blankNode,
            const IriTerm('https://example.com/nonIdentifyingProp'),
            LiteralTerm('value'),
          ),
        ]);
        final mergeContract =
            createMergeContract(); // No identifying predicates

        final result = computeIdentifiedBlankNodes(graph, mergeContract);

        expect(result.identifiedMap, isEmpty);
      });
    });

    group('global identifying predicates', () {
      test('identifies blank node with global identifying predicate', () {
        final blankNode = BlankNodeTerm();
        final identifyingProp = const IriTerm('https://example.com/id');
        final parentIri = const IriTerm('https://example.com/resource');

        final graph = RdfGraph.fromTriples([
          Triple(parentIri, const IriTerm('https://example.com/hasBlankNode'),
              blankNode),
          Triple(blankNode, identifyingProp, LiteralTerm('unique-id')),
        ]);

        final mergeContract = createMergeContract(
          globalIdentifyingPredicates: {identifyingProp},
        );

        final result = computeIdentifiedBlankNodes(graph, mergeContract);

        expect(result.identifiedMap, hasLength(1));
        expect(result.identifiedMap[blankNode], hasLength(1));

        final identifiedNode = result.identifiedMap[blankNode]!.first;
        expect(identifiedNode.parent.iriTerm, equals(parentIri));
        expect(identifiedNode.identifyingProperties[identifyingProp],
            equals([LiteralTerm('unique-id')]));
      });

      test('identifies blank node with multiple global identifying predicates',
          () {
        final blankNode = BlankNodeTerm();
        final idProp1 = const IriTerm('https://example.com/id1');
        final idProp2 = const IriTerm('https://example.com/id2');
        final parentIri = const IriTerm('https://example.com/resource');

        final graph = RdfGraph.fromTriples([
          Triple(parentIri, const IriTerm('https://example.com/hasBlankNode'),
              blankNode),
          Triple(blankNode, idProp1, LiteralTerm('id1-value')),
          Triple(blankNode, idProp2, LiteralTerm('id2-value')),
          Triple(blankNode, const IriTerm('https://example.com/nonIdentifying'),
              LiteralTerm('other')),
        ]);

        final mergeContract = createMergeContract(
          globalIdentifyingPredicates: {idProp1, idProp2},
        );

        final result = computeIdentifiedBlankNodes(graph, mergeContract);

        final identifiedNode = result.identifiedMap[blankNode]!.first;
        expect(identifiedNode.identifyingProperties, hasLength(2));
        expect(identifiedNode.identifyingProperties[idProp1],
            equals([LiteralTerm('id1-value')]));
        expect(identifiedNode.identifyingProperties[idProp2],
            equals([LiteralTerm('id2-value')]));
      });

      test('handles multi-value identifying properties', () {
        final blankNode = BlankNodeTerm();
        final identifyingProp = const IriTerm('https://example.com/tags');
        final parentIri = const IriTerm('https://example.com/resource');

        final graph = RdfGraph.fromTriples([
          Triple(parentIri, const IriTerm('https://example.com/hasBlankNode'),
              blankNode),
          Triple(blankNode, identifyingProp, LiteralTerm('tag1')),
          Triple(blankNode, identifyingProp, LiteralTerm('tag2')),
          Triple(blankNode, identifyingProp, LiteralTerm('tag3')),
        ]);

        final mergeContract = createMergeContract(
          globalIdentifyingPredicates: {identifyingProp},
        );

        final result = computeIdentifiedBlankNodes(graph, mergeContract);

        final identifiedNode = result.identifiedMap[blankNode]!.first;
        expect(identifiedNode.identifyingProperties[identifyingProp],
            hasLength(3));
        expect(
            identifiedNode.identifyingProperties[identifyingProp],
            containsAll([
              LiteralTerm('tag1'),
              LiteralTerm('tag2'),
              LiteralTerm('tag3'),
            ]));
      });
    });

    group('class-based identifying predicates', () {
      test('identifies blank node using class-specific identifying predicates',
          () {
        final blankNode = BlankNodeTerm();
        final classIri = const IriTerm('https://example.com/PersonClass');
        final identifyingProp = const IriTerm('https://example.com/name');
        final parentIri = const IriTerm('https://example.com/resource');

        final graph = RdfGraph.fromTriples([
          Triple(parentIri, const IriTerm('https://example.com/hasPerson'),
              blankNode),
          Triple(blankNode, Rdf.type, classIri),
          Triple(blankNode, identifyingProp, LiteralTerm('John Doe')),
          Triple(blankNode, const IriTerm('https://example.com/age'),
              LiteralTerm('30')),
        ]);

        final mergeContract = createMergeContract(
          classIdentifyingPredicates: {
            classIri: {identifyingProp}
          },
        );

        final result = computeIdentifiedBlankNodes(graph, mergeContract);

        expect(result.identifiedMap, hasLength(1));
        final identifiedNode = result.identifiedMap[blankNode]!.first;
        expect(identifiedNode.identifyingProperties[identifyingProp],
            equals([LiteralTerm('John Doe')]));
      });

      test('class predicates take precedence over global predicates', () {
        final blankNode = BlankNodeTerm();
        final classIri = const IriTerm('https://example.com/PersonClass');
        final classProp = const IriTerm('https://example.com/name');
        final globalProp = const IriTerm('https://example.com/globalId');
        final parentIri = const IriTerm('https://example.com/resource');

        final graph = RdfGraph.fromTriples([
          Triple(parentIri, const IriTerm('https://example.com/hasPerson'),
              blankNode),
          Triple(blankNode, Rdf.type, classIri),
          Triple(blankNode, classProp, LiteralTerm('John Doe')),
          Triple(blankNode, globalProp, LiteralTerm('global-123')),
        ]);

        final mergeContract = createMergeContract(
          globalIdentifyingPredicates: {globalProp},
          classIdentifyingPredicates: {
            classIri: {classProp}
          },
        );

        final result = computeIdentifiedBlankNodes(graph, mergeContract);

        final identifiedNode = result.identifiedMap[blankNode]!.first;
        // With additive logic, both class and global predicates should be included
        expect(identifiedNode.identifyingProperties, hasLength(2));
        expect(identifiedNode.identifyingProperties[classProp],
            equals([LiteralTerm('John Doe')]));
        expect(identifiedNode.identifyingProperties[globalProp],
            equals([LiteralTerm('global-123')]));
      });

      test(
          'logs warning and skips node when class identifying properties are missing',
          () {
        final blankNode = BlankNodeTerm();
        final classIri = const IriTerm('https://example.com/PersonClass');
        final requiredProp = const IriTerm('https://example.com/name');
        final parentIri = const IriTerm('https://example.com/resource');

        final graph = RdfGraph.fromTriples([
          Triple(parentIri, const IriTerm('https://example.com/hasPerson'),
              blankNode),
          Triple(blankNode, Rdf.type, classIri),
          Triple(blankNode, const IriTerm('https://example.com/age'),
              LiteralTerm('30')),
          // Missing required name property
        ]);

        final mergeContract = createMergeContract(
          classIdentifyingPredicates: {
            classIri: {requiredProp}
          },
        );

        final result = computeIdentifiedBlankNodes(graph, mergeContract);

        expect(result.identifiedMap, isEmpty);
      });

      test(
          'falls back to global predicates when class has no identifying predicates',
          () {
        final blankNode = BlankNodeTerm();
        final classIri = const IriTerm('https://example.com/PersonClass');
        final globalProp = const IriTerm('https://example.com/globalId');
        final parentIri = const IriTerm('https://example.com/resource');

        final graph = RdfGraph.fromTriples([
          Triple(parentIri, const IriTerm('https://example.com/hasPerson'),
              blankNode),
          Triple(blankNode, Rdf.type, classIri),
          Triple(blankNode, globalProp, LiteralTerm('global-123')),
        ]);

        // Class exists but has no identifying predicates
        final mergeContract = createMergeContract(
          globalIdentifyingPredicates: {globalProp},
          classIdentifyingPredicates: {classIri: <IriTerm>{}},
        );

        final result = computeIdentifiedBlankNodes(graph, mergeContract);

        final identifiedNode = result.identifiedMap[blankNode]!.first;
        expect(identifiedNode.identifyingProperties[globalProp],
            equals([LiteralTerm('global-123')]));
      });

      test('explicit exclusion of global predicates via isIdentifying: false',
          () {
        final blankNode = BlankNodeTerm();
        final classIri = const IriTerm('https://example.com/PersonClass');
        final globalProp = const IriTerm('https://example.com/email');
        final classProp = const IriTerm('https://example.com/name');
        final parentIri = const IriTerm('https://example.com/resource');

        final graph = RdfGraph.fromTriples([
          Triple(parentIri, const IriTerm('https://example.com/hasPerson'),
              blankNode),
          Triple(blankNode, Rdf.type, classIri),
          Triple(blankNode, classProp, LiteralTerm('John Doe')),
          Triple(blankNode, globalProp, LiteralTerm('john@example.com')),
        ]);

        final mergeContract = createMergeContract(
          globalIdentifyingPredicates: {globalProp},
          classIdentifyingPredicates: {
            classIri: {classProp}
          },
          classNonIdentifyingPredicates: {
            classIri: {
              globalProp
            } // Explicitly exclude global email predicate for this class
          },
        );

        final result = computeIdentifiedBlankNodes(graph, mergeContract);

        final identifiedNode = result.identifiedMap[blankNode]!.first;
        // Only class predicate should be used, global predicate explicitly excluded
        expect(identifiedNode.identifyingProperties, hasLength(1));
        expect(identifiedNode.identifyingProperties[classProp],
            equals([LiteralTerm('John Doe')]));
        expect(identifiedNode.identifyingProperties.containsKey(globalProp),
            isFalse);
      });

      test('mixed mandatory class and opportunistic global predicates', () {
        final blankNode = BlankNodeTerm();
        final classIri = const IriTerm('https://example.com/PersonClass');
        final globalProp1 = const IriTerm('https://example.com/email');
        final globalProp2 = const IriTerm('https://example.com/phone');
        final classProp = const IriTerm('https://example.com/name');
        final parentIri = const IriTerm('https://example.com/resource');

        final graph = RdfGraph.fromTriples([
          Triple(parentIri, const IriTerm('https://example.com/hasPerson'),
              blankNode),
          Triple(blankNode, Rdf.type, classIri),
          Triple(blankNode, classProp, LiteralTerm('John Doe')),
          Triple(blankNode, globalProp1,
              LiteralTerm('john@example.com')), // Present
          // globalProp2 (phone) is not present
        ]);

        final mergeContract = createMergeContract(
          globalIdentifyingPredicates: {globalProp1, globalProp2},
          classIdentifyingPredicates: {
            classIri: {classProp}
          },
        );

        final result = computeIdentifiedBlankNodes(graph, mergeContract);

        final identifiedNode = result.identifiedMap[blankNode]!.first;
        // Should include: required class predicate + present global predicate
        expect(identifiedNode.identifyingProperties, hasLength(2));
        expect(identifiedNode.identifyingProperties[classProp],
            equals([LiteralTerm('John Doe')]));
        expect(identifiedNode.identifyingProperties[globalProp1],
            equals([LiteralTerm('john@example.com')]));
        expect(identifiedNode.identifyingProperties.containsKey(globalProp2),
            isFalse);
      });

      test(
          'missing required class predicate prevents identification despite global predicates',
          () {
        final blankNode = BlankNodeTerm();
        final classIri = const IriTerm('https://example.com/PersonClass');
        final globalProp = const IriTerm('https://example.com/email');
        final classProp = const IriTerm('https://example.com/name');
        final parentIri = const IriTerm('https://example.com/resource');

        final graph = RdfGraph.fromTriples([
          Triple(parentIri, const IriTerm('https://example.com/hasPerson'),
              blankNode),
          Triple(blankNode, Rdf.type, classIri),
          Triple(blankNode, globalProp,
              LiteralTerm('john@example.com')), // Global present
          // classProp (name) is missing!
        ]);

        final mergeContract = createMergeContract(
          globalIdentifyingPredicates: {globalProp},
          classIdentifyingPredicates: {
            classIri: {classProp} // Required but missing
          },
        );

        final result = computeIdentifiedBlankNodes(graph, mergeContract);

        // Node should not be identified despite having global predicate
        expect(result.identifiedMap, isEmpty);
      });

      test('complex three-valued logic with multiple predicate rules', () {
        final blankNode = BlankNodeTerm();
        final classIri = const IriTerm('https://example.com/PersonClass');
        final globalProp1 = const IriTerm('https://example.com/email');
        final globalProp2 = const IriTerm('https://example.com/phone');
        final globalProp3 = const IriTerm('https://example.com/ssn');
        final classProp = const IriTerm('https://example.com/name');
        final parentIri = const IriTerm('https://example.com/resource');

        final graph = RdfGraph.fromTriples([
          Triple(parentIri, const IriTerm('https://example.com/hasPerson'),
              blankNode),
          Triple(blankNode, Rdf.type, classIri),
          Triple(blankNode, classProp, LiteralTerm('John Doe')),
          Triple(blankNode, globalProp1, LiteralTerm('john@example.com')),
          Triple(blankNode, globalProp2, LiteralTerm('555-1234')),
          Triple(blankNode, globalProp3, LiteralTerm('123-45-6789')),
        ]);

        final mergeContract = createMergeContract(
          globalIdentifyingPredicates: {globalProp1, globalProp2, globalProp3},
          classIdentifyingPredicates: {
            classIri: {classProp} // isIdentifying: true (required)
          },
          classNonIdentifyingPredicates: {
            classIri: {globalProp3} // isIdentifying: false (excluded)
            // globalProp1, globalProp2 are isIdentifying: null (opportunistic)
          },
        );

        final result = computeIdentifiedBlankNodes(graph, mergeContract);

        final identifiedNode = result.identifiedMap[blankNode]!.first;
        // Should include: name (required) + email + phone (opportunistic) - ssn (excluded)
        expect(identifiedNode.identifyingProperties, hasLength(3));
        expect(identifiedNode.identifyingProperties[classProp],
            equals([LiteralTerm('John Doe')]));
        expect(identifiedNode.identifyingProperties[globalProp1],
            equals([LiteralTerm('john@example.com')]));
        expect(identifiedNode.identifyingProperties[globalProp2],
            equals([LiteralTerm('555-1234')]));
        expect(identifiedNode.identifyingProperties.containsKey(globalProp3),
            isFalse);
      });

      test('all global predicates excluded by class rules', () {
        final blankNode = BlankNodeTerm();
        final classIri = const IriTerm('https://example.com/PersonClass');
        final globalProp1 = const IriTerm('https://example.com/email');
        final globalProp2 = const IriTerm('https://example.com/phone');
        final classProp = const IriTerm('https://example.com/name');
        final parentIri = const IriTerm('https://example.com/resource');

        final graph = RdfGraph.fromTriples([
          Triple(parentIri, const IriTerm('https://example.com/hasPerson'),
              blankNode),
          Triple(blankNode, Rdf.type, classIri),
          Triple(blankNode, classProp, LiteralTerm('John Doe')),
          Triple(blankNode, globalProp1, LiteralTerm('john@example.com')),
          Triple(blankNode, globalProp2, LiteralTerm('555-1234')),
        ]);

        final mergeContract = createMergeContract(
          globalIdentifyingPredicates: {globalProp1, globalProp2},
          classIdentifyingPredicates: {
            classIri: {classProp}
          },
          classNonIdentifyingPredicates: {
            classIri: {
              globalProp1,
              globalProp2
            } // Exclude all global predicates
          },
        );

        final result = computeIdentifiedBlankNodes(graph, mergeContract);

        final identifiedNode = result.identifiedMap[blankNode]!.first;
        // Only class predicate should be used
        expect(identifiedNode.identifyingProperties, hasLength(1));
        expect(identifiedNode.identifyingProperties[classProp],
            equals([LiteralTerm('John Doe')]));
        expect(identifiedNode.identifyingProperties.containsKey(globalProp1),
            isFalse);
        expect(identifiedNode.identifyingProperties.containsKey(globalProp2),
            isFalse);
      });

      test('class with no rules uses only applicable global predicates', () {
        final blankNode = BlankNodeTerm();
        final classIri = const IriTerm('https://example.com/PersonClass');
        final globalProp1 = const IriTerm('https://example.com/email');
        final globalProp2 = const IriTerm('https://example.com/phone');
        final parentIri = const IriTerm('https://example.com/resource');

        final graph = RdfGraph.fromTriples([
          Triple(parentIri, const IriTerm('https://example.com/hasPerson'),
              blankNode),
          Triple(blankNode, Rdf.type, classIri),
          Triple(blankNode, globalProp1, LiteralTerm('john@example.com')),
          // globalProp2 not present
        ]);

        final mergeContract = createMergeContract(
          globalIdentifyingPredicates: {globalProp1, globalProp2},
          classIdentifyingPredicates: {
            classIri: <IriTerm>{} // No class-specific rules
          },
        );

        final result = computeIdentifiedBlankNodes(graph, mergeContract);

        final identifiedNode = result.identifiedMap[blankNode]!.first;
        // Only present global predicates should be used
        expect(identifiedNode.identifyingProperties, hasLength(1));
        expect(identifiedNode.identifyingProperties[globalProp1],
            equals([LiteralTerm('john@example.com')]));
        expect(identifiedNode.identifyingProperties.containsKey(globalProp2),
            isFalse);
      });
    });

    group('nested blank nodes', () {
      test('identifies nested blank nodes with IRI parent chain', () {
        final parentBlankNode = BlankNodeTerm();
        final childBlankNode = BlankNodeTerm();
        final rootIri = const IriTerm('https://example.com/root');
        final identifyingProp = const IriTerm('https://example.com/id');

        final graph = RdfGraph.fromTriples([
          Triple(rootIri, const IriTerm('https://example.com/hasParent'),
              parentBlankNode),
          Triple(parentBlankNode, const IriTerm('https://example.com/hasChild'),
              childBlankNode),
          Triple(parentBlankNode, identifyingProp, LiteralTerm('parent-id')),
          Triple(childBlankNode, identifyingProp, LiteralTerm('child-id')),
        ]);

        final mergeContract = createMergeContract(
          globalIdentifyingPredicates: {identifyingProp},
        );

        final result = computeIdentifiedBlankNodes(graph, mergeContract);

        expect(result.identifiedMap, hasLength(2));

        // Check parent node
        final parentNode = result.identifiedMap[parentBlankNode]!.first;
        expect(parentNode.parent.iriTerm, equals(rootIri));

        // Check child node
        final childNode = result.identifiedMap[childBlankNode]!.first;
        expect(childNode.parent.blankNode, equals(parentNode));
      });

      test('handles circular references in blank nodes', () {
        final blankNode1 = BlankNodeTerm();
        final blankNode2 = BlankNodeTerm();
        final rootIri = const IriTerm('https://example.com/root');
        final identifyingProp = const IriTerm('https://example.com/id');

        final graph = RdfGraph.fromTriples([
          Triple(rootIri, const IriTerm('https://example.com/hasNode'),
              blankNode1),
          Triple(blankNode1, const IriTerm('https://example.com/relatedTo'),
              blankNode2),
          Triple(blankNode2, const IriTerm('https://example.com/relatedTo'),
              blankNode1), // Circular
          Triple(blankNode1, identifyingProp, LiteralTerm('node1-id')),
          Triple(blankNode2, identifyingProp, LiteralTerm('node2-id')),
        ]);

        final mergeContract = createMergeContract(
          globalIdentifyingPredicates: {identifyingProp},
        );

        final result = computeIdentifiedBlankNodes(graph, mergeContract);

        expect(result.identifiedMap, hasLength(0));
      });
    });

    group('circuit breaker tests', () {
      test('simple two-node circular reference - both nodes removed', () {
        final blankNode1 = BlankNodeTerm();
        final blankNode2 = BlankNodeTerm();
        final identifyingProp = const IriTerm('https://example.com/id');

        final graph = RdfGraph.fromTriples([
          // Pure circular reference - no IRI parents
          Triple(blankNode1, const IriTerm('https://example.com/relatedTo'),
              blankNode2),
          Triple(blankNode2, const IriTerm('https://example.com/relatedTo'),
              blankNode1),
          Triple(blankNode1, identifyingProp, LiteralTerm('node1-id')),
          Triple(blankNode2, identifyingProp, LiteralTerm('node2-id')),
        ]);

        final mergeContract = createMergeContract(
          globalIdentifyingPredicates: {identifyingProp},
        );

        final result = computeIdentifiedBlankNodes(graph, mergeContract);

        // Both nodes should be removed due to circular dependency
        expect(result.identifiedMap, isEmpty);
      });

      test('three-node circular reference - all nodes removed', () {
        final blankNode1 = BlankNodeTerm();
        final blankNode2 = BlankNodeTerm();
        final blankNode3 = BlankNodeTerm();
        final identifyingProp = const IriTerm('https://example.com/id');

        final graph = RdfGraph.fromTriples([
          // Three-way circular reference
          Triple(blankNode1, const IriTerm('https://example.com/next'),
              blankNode2),
          Triple(blankNode2, const IriTerm('https://example.com/next'),
              blankNode3),
          Triple(blankNode3, const IriTerm('https://example.com/next'),
              blankNode1),
          Triple(blankNode1, identifyingProp, LiteralTerm('node1-id')),
          Triple(blankNode2, identifyingProp, LiteralTerm('node2-id')),
          Triple(blankNode3, identifyingProp, LiteralTerm('node3-id')),
        ]);

        final mergeContract = createMergeContract(
          globalIdentifyingPredicates: {identifyingProp},
        );

        final result = computeIdentifiedBlankNodes(graph, mergeContract);

        // All nodes should be removed due to circular dependency
        expect(result.identifiedMap, isEmpty);
      });

      test(
          'mixed circular and non-circular references - only non-circular preserved',
          () {
        final blankNode1 = BlankNodeTerm();
        final blankNode2 = BlankNodeTerm();
        final blankNode3 = BlankNodeTerm();
        final rootIri = const IriTerm('https://example.com/root');
        final identifyingProp = const IriTerm('https://example.com/id');

        final graph = RdfGraph.fromTriples([
          // blankNode1 has only IRI parent (non-circular)
          Triple(rootIri, const IriTerm('https://example.com/hasNode'),
              blankNode1),
          // blankNode2 and blankNode3 form circular dependency
          Triple(blankNode2, const IriTerm('https://example.com/relatedTo'),
              blankNode3),
          Triple(blankNode3, const IriTerm('https://example.com/relatedTo'),
              blankNode2),
          // Optional: blankNode1 might reference the circular nodes (but isn't parent-wise dependent)
          Triple(blankNode1, const IriTerm('https://example.com/references'),
              blankNode2),
          Triple(blankNode1, identifyingProp, LiteralTerm('node1-id')),
          Triple(blankNode2, identifyingProp, LiteralTerm('node2-id')),
          Triple(blankNode3, identifyingProp, LiteralTerm('node3-id')),
        ]);

        final mergeContract = createMergeContract(
          globalIdentifyingPredicates: {identifyingProp},
        );

        final result = computeIdentifiedBlankNodes(graph, mergeContract);

        // Only blankNode1 should be identifiable (has non-circular IRI parent)
        expect(result.identifiedMap, hasLength(1));
        expect(result.identifiedMap[blankNode1], hasLength(1));

        final identifiedNode = result.identifiedMap[blankNode1]!.first;
        expect(identifiedNode.parent.isIri, isTrue);
        expect(identifiedNode.parent.iriTerm, equals(rootIri));

        // blankNode2 and blankNode3 should be removed due to circular dependency
        expect(result.identifiedMap.containsKey(blankNode2), isFalse);
        expect(result.identifiedMap.containsKey(blankNode3), isFalse);
      });

      test(
          'complex chain with circular reference at end - partial identification',
          () {
        final root = const IriTerm('https://example.com/root');
        final blankNode1 = BlankNodeTerm();
        final blankNode2 = BlankNodeTerm();
        final blankNode3 = BlankNodeTerm();
        final blankNode4 = BlankNodeTerm();
        final identifyingProp = const IriTerm('https://example.com/id');

        final graph = RdfGraph.fromTriples([
          // Chain: root -> blank1 -> blank2 -> blank3 -> blank4 -> blank3 (circular)
          Triple(
              root, const IriTerm('https://example.com/hasNode'), blankNode1),
          Triple(blankNode1, const IriTerm('https://example.com/hasChild'),
              blankNode2),
          Triple(blankNode2, const IriTerm('https://example.com/hasChild'),
              blankNode3),
          Triple(blankNode3, const IriTerm('https://example.com/hasChild'),
              blankNode4),
          Triple(blankNode4, const IriTerm('https://example.com/backTo'),
              blankNode3), // Circular
          Triple(blankNode1, identifyingProp, LiteralTerm('node1-id')),
          Triple(blankNode2, identifyingProp, LiteralTerm('node2-id')),
          Triple(blankNode3, identifyingProp, LiteralTerm('node3-id')),
          Triple(blankNode4, identifyingProp, LiteralTerm('node4-id')),
        ]);

        final mergeContract = createMergeContract(
          globalIdentifyingPredicates: {identifyingProp},
        );

        final result = computeIdentifiedBlankNodes(graph, mergeContract);

        // Only blankNode1 and blankNode2 should be identifiable
        // blankNode3 and blankNode4 are part of circular dependency
        expect(result.identifiedMap, hasLength(2));
        expect(result.identifiedMap.containsKey(blankNode1), isTrue);
        expect(result.identifiedMap.containsKey(blankNode2), isTrue);
        expect(result.identifiedMap.containsKey(blankNode3), isFalse);
        expect(result.identifiedMap.containsKey(blankNode4), isFalse);
      });

      test('self-referencing node - removed', () {
        final blankNode = BlankNodeTerm();
        final identifyingProp = const IriTerm('https://example.com/id');

        final graph = RdfGraph.fromTriples([
          // Self-reference
          Triple(
              blankNode, const IriTerm('https://example.com/self'), blankNode),
          Triple(blankNode, identifyingProp, LiteralTerm('self-id')),
        ]);

        final mergeContract = createMergeContract(
          globalIdentifyingPredicates: {identifyingProp},
        );

        final result = computeIdentifiedBlankNodes(graph, mergeContract);

        // Self-referencing node should be removed
        expect(result.identifiedMap, isEmpty);
      });

      test('multiple separate circular groups - all removed', () {
        final blankNode1 = BlankNodeTerm();
        final blankNode2 = BlankNodeTerm();
        final blankNode3 = BlankNodeTerm();
        final blankNode4 = BlankNodeTerm();
        final identifyingProp = const IriTerm('https://example.com/id');

        final graph = RdfGraph.fromTriples([
          // First circular group: 1 <-> 2
          Triple(blankNode1, const IriTerm('https://example.com/relatedTo'),
              blankNode2),
          Triple(blankNode2, const IriTerm('https://example.com/relatedTo'),
              blankNode1),
          // Second circular group: 3 <-> 4
          Triple(blankNode3, const IriTerm('https://example.com/relatedTo'),
              blankNode4),
          Triple(blankNode4, const IriTerm('https://example.com/relatedTo'),
              blankNode3),
          // Identifying properties
          Triple(blankNode1, identifyingProp, LiteralTerm('node1-id')),
          Triple(blankNode2, identifyingProp, LiteralTerm('node2-id')),
          Triple(blankNode3, identifyingProp, LiteralTerm('node3-id')),
          Triple(blankNode4, identifyingProp, LiteralTerm('node4-id')),
        ]);

        final mergeContract = createMergeContract(
          globalIdentifyingPredicates: {identifyingProp},
        );

        final result = computeIdentifiedBlankNodes(graph, mergeContract);

        // All nodes should be removed due to their respective circular dependencies
        expect(result.identifiedMap, isEmpty);
      });

      test(
          'node with multiple parents including circular - partial identification',
          () {
        final blankNode1 = BlankNodeTerm();
        final blankNode2 = BlankNodeTerm();
        final root1 = const IriTerm('https://example.com/root1');
        final root2 = const IriTerm('https://example.com/root2');
        final identifyingProp = const IriTerm('https://example.com/id');

        final graph = RdfGraph.fromTriples([
          // blankNode1 has multiple parents: two IRIs and one circular blank node
          Triple(
              root1, const IriTerm('https://example.com/hasNode'), blankNode1),
          Triple(root2, const IriTerm('https://example.com/alsoHasNode'),
              blankNode1),
          Triple(blankNode1, const IriTerm('https://example.com/relatedTo'),
              blankNode2),
          Triple(blankNode2, const IriTerm('https://example.com/relatedTo'),
              blankNode1), // Circular
          Triple(blankNode1, identifyingProp, LiteralTerm('node1-id')),
          Triple(blankNode2, identifyingProp, LiteralTerm('node2-id')),
        ]);

        final mergeContract = createMergeContract(
          globalIdentifyingPredicates: {identifyingProp},
        );

        final result = computeIdentifiedBlankNodes(graph, mergeContract);

        // Both nodes should be completely removed due to circular dependency
        // blankNode1 is directly part of the circular dependency with blankNode2,
        // so even though it has IRI parents, it must be removed entirely
        expect(result.identifiedMap, isEmpty);
      });

      test('blankNodeChain method works correctly', () {
        final root = const IriTerm('https://example.com/root');
        final blankNode1 = BlankNodeTerm();
        final blankNode2 = BlankNodeTerm();
        final blankNode3 = BlankNodeTerm();
        final identifyingProp = const IriTerm('https://example.com/id');

        final graph = RdfGraph.fromTriples([
          // Chain: root -> blank1 -> blank2 -> blank3
          Triple(
              root, const IriTerm('https://example.com/hasNode'), blankNode1),
          Triple(blankNode1, const IriTerm('https://example.com/hasChild'),
              blankNode2),
          Triple(blankNode2, const IriTerm('https://example.com/hasChild'),
              blankNode3),
          Triple(blankNode1, identifyingProp, LiteralTerm('node1-id')),
          Triple(blankNode2, identifyingProp, LiteralTerm('node2-id')),
          Triple(blankNode3, identifyingProp, LiteralTerm('node3-id')),
        ]);

        final mergeContract = createMergeContract(
          globalIdentifyingPredicates: {identifyingProp},
        );

        final result = computeIdentifiedBlankNodes(graph, mergeContract);

        // Get the deeply nested identification
        final blankNode3Identified = result.identifiedMap[blankNode3]!.first;
        final chain = blankNode3Identified.blankNodeChain().toList();

        // Chain should include all blank nodes in the path
        expect(chain, hasLength(3));
        //expect(chain, containsAll([blankNode3, blankNode2, blankNode1]));
      });

      test('circuit breaker logging behavior', () {
        final blankNode1 = BlankNodeTerm();
        final blankNode2 = BlankNodeTerm();
        final identifyingProp = const IriTerm('https://example.com/id');

        final graph = RdfGraph.fromTriples([
          Triple(blankNode1, const IriTerm('https://example.com/relatedTo'),
              blankNode2),
          Triple(blankNode2, const IriTerm('https://example.com/relatedTo'),
              blankNode1),
          Triple(blankNode1, identifyingProp, LiteralTerm('node1-id')),
          Triple(blankNode2, identifyingProp, LiteralTerm('node2-id')),
        ]);

        final mergeContract = createMergeContract(
          globalIdentifyingPredicates: {identifyingProp},
        );

        // This should trigger warning logs about circular references
        final result = computeIdentifiedBlankNodes(graph, mergeContract);

        expect(result.identifiedMap, isEmpty);
        // Note: In a real test, you might want to capture and verify log messages
        // but that would require setting up log capture infrastructure
      });
    });

    group('multiple parents', () {
      test(
          'creates multiple IdentifiedBlankNode instances for blank node with multiple parents',
          () {
        final blankNode = BlankNodeTerm();
        final parent1 = const IriTerm('https://example.com/parent1');
        final parent2 = const IriTerm('https://example.com/parent2');
        final identifyingProp = const IriTerm('https://example.com/id');

        final graph = RdfGraph.fromTriples([
          Triple(
              parent1, const IriTerm('https://example.com/hasNode'), blankNode),
          Triple(parent2, const IriTerm('https://example.com/alsoHasNode'),
              blankNode),
          Triple(blankNode, identifyingProp, LiteralTerm('shared-id')),
        ]);

        final mergeContract = createMergeContract(
          globalIdentifyingPredicates: {identifyingProp},
        );

        final result = computeIdentifiedBlankNodes(graph, mergeContract);

        expect(result.identifiedMap[blankNode], hasLength(2));

        final identifiedNodes = result.identifiedMap[blankNode]!;
        final parents = identifiedNodes.map((n) => n.parent.iriTerm).toSet();
        expect(parents, containsAll([parent1, parent2]));

        // Both should have same identifying properties
        for (final node in identifiedNodes) {
          expect(node.identifyingProperties[identifyingProp],
              equals([LiteralTerm('shared-id')]));
        }
      });
    });

    group('edge cases', () {
      test('handles blank node without parents', () {
        final blankNode = BlankNodeTerm();
        final identifyingProp = const IriTerm('https://example.com/id');

        final graph = RdfGraph.fromTriples([
          // Blank node exists but has no incoming references
          Triple(blankNode, identifyingProp, LiteralTerm('orphan-id')),
        ]);

        final mergeContract = createMergeContract(
          globalIdentifyingPredicates: {identifyingProp},
        );

        final result = computeIdentifiedBlankNodes(graph, mergeContract);

        expect(result.identifiedMap, isEmpty);
      });

      test('handles blank node with identifying properties but no values', () {
        final blankNode = BlankNodeTerm();
        final parentIri = const IriTerm('https://example.com/parent');
        final identifyingProp = const IriTerm('https://example.com/id');

        final graph = RdfGraph.fromTriples([
          Triple(parentIri, const IriTerm('https://example.com/hasNode'),
              blankNode),
          // Blank node has no properties
        ]);

        final mergeContract = createMergeContract(
          globalIdentifyingPredicates: {identifyingProp},
        );

        final result = computeIdentifiedBlankNodes(graph, mergeContract);

        expect(result.identifiedMap, isEmpty);
      });

      test('processes each blank node only once', () {
        final blankNode = BlankNodeTerm();
        final parentIri = const IriTerm('https://example.com/parent');
        final identifyingProp = const IriTerm('https://example.com/id');

        final graph = RdfGraph.fromTriples([
          Triple(parentIri, const IriTerm('https://example.com/hasNode'),
              blankNode),
          Triple(blankNode, identifyingProp, LiteralTerm('test-id')),
        ]);

        final mergeContract = createMergeContract(
          globalIdentifyingPredicates: {identifyingProp},
        );

        // Call twice to ensure idempotency
        final result1 = computeIdentifiedBlankNodes(graph, mergeContract);
        final result2 = computeIdentifiedBlankNodes(graph, mergeContract);

        expect(result1.identifiedMap, equals(result2.identifiedMap));
      });
    });

    group('path-identified blank nodes', () {
      test('identifies blank node with path identification only', () {
        final blankNode = BlankNodeTerm();
        final parentIri = const IriTerm('https://example.com/resource');
        final parentType = const IriTerm('https://example.com/ParentType');
        final pathPredicate =
            const IriTerm('https://example.com/displaySettings');

        final graph = RdfGraph.fromTriples([
          Triple(parentIri, Rdf.type, parentType),
          Triple(parentIri, pathPredicate, blankNode),
          Triple(blankNode, const IriTerm('https://example.com/sortOrder'),
              LiteralTerm('alphabetical')),
        ]);

        final mergeContract = createMergeContract(
          classPredicateAlgorithms: {
            parentType: {pathPredicate: Algo.LWW_Register}
          },
        );

        final result = computeIdentifiedBlankNodes(graph, mergeContract);

        expect(result.identifiedMap, hasLength(1));
        expect(result.identifiedMap[blankNode], hasLength(1));

        final identifiedNode = result.identifiedMap[blankNode]!.first;
        expect(identifiedNode.parent.iriTerm, equals(parentIri));
        expect(identifiedNode.parentPredicate, equals(pathPredicate));
        expect(identifiedNode.identifyingProperties, isEmpty);
      });

      test('identifies blank node with both path and property identification',
          () {
        final blankNode = BlankNodeTerm();
        final parentIri = const IriTerm('https://example.com/resource');
        final parentType = const IriTerm('https://example.com/ParentType');
        final pathPredicate = const IriTerm('https://example.com/item');
        final identifyingProp = const IriTerm('https://example.com/name');

        final graph = RdfGraph.fromTriples([
          Triple(parentIri, Rdf.type, parentType),
          Triple(parentIri, pathPredicate, blankNode),
          Triple(blankNode, identifyingProp, LiteralTerm('Item1')),
        ]);

        final mergeContract = createMergeContract(
          classPredicateAlgorithms: {
            parentType: {pathPredicate: Algo.LWW_Register}
          },
          globalIdentifyingPredicates: {identifyingProp},
        );

        final result = computeIdentifiedBlankNodes(graph, mergeContract);

        expect(result.identifiedMap, hasLength(1));
        final identifiedNode = result.identifiedMap[blankNode]!.first;
        expect(identifiedNode.parent.iriTerm, equals(parentIri));
        expect(identifiedNode.parentPredicate, equals(pathPredicate));
        expect(identifiedNode.identifyingProperties[identifyingProp],
            equals([LiteralTerm('Item1')]));
      });

      test('generates canonical IRI for path-identified blank node', () {
        final blankNode = BlankNodeTerm();
        final documentIri = const IriTerm('https://example.com/doc');
        final parentIri = const IriTerm('https://example.com/doc#it');
        final parentType = const IriTerm('https://example.com/Category');
        final pathPredicate = const IriTerm('https://example.com/settings');

        final graph = RdfGraph.fromTriples([
          Triple(parentIri, Rdf.type, parentType),
          Triple(parentIri, pathPredicate, blankNode),
          Triple(blankNode, const IriTerm('https://example.com/value'),
              LiteralTerm('test')),
        ]);

        final mergeContract = createMergeContract(
          classPredicateAlgorithms: {
            parentType: {pathPredicate: Algo.LWW_Register}
          },
        );

        final result =
            IdentifiedBlankNodeBuilder(iriGenerator: FrameworkIriGenerator())
                .computeCanonicalBlankNodes(documentIri, graph, mergeContract);

        expect(result.identifiedMap, hasLength(1));
        final canonicalIri = result.identifiedMap[blankNode]!.first;

        // Verify exact canonical IRI - deterministic hash of identification graph:
        // _:ibn0 <sync:parent> <https://example.com/doc#it> .
        // _:ibn0 <sync:parentProperty> <https://example.com/settings> .
        expect(
            canonicalIri.value,
            equals(
                'https://example.com/doc#lcrd-ibn-md5-9a90bc3f69ef4cf11f98d79d1a337aa7'));
      });

      test('nested path-identified blank nodes', () {
        final outerBlankNode = BlankNodeTerm();
        final innerBlankNode = BlankNodeTerm();
        final parentIri = const IriTerm('https://example.com/resource');
        final parentType = const IriTerm('https://example.com/Note');
        final outerPredicate = const IriTerm('https://example.com/preferences');
        final innerPredicate = const IriTerm('https://example.com/display');

        final graph = RdfGraph.fromTriples([
          Triple(parentIri, Rdf.type, parentType),
          Triple(parentIri, outerPredicate, outerBlankNode),
          Triple(outerBlankNode, innerPredicate, innerBlankNode),
          Triple(innerBlankNode, const IriTerm('https://example.com/theme'),
              LiteralTerm('dark')),
        ]);

        final mergeContract = createMergeContract(
          classPredicateAlgorithms: {
            parentType: {
              outerPredicate: Algo.LWW_Register,
              innerPredicate: Algo.LWW_Register
            }
          },
        );

        final result = computeIdentifiedBlankNodes(graph, mergeContract);

        expect(result.identifiedMap, hasLength(2));
        expect(result.identifiedMap[outerBlankNode], hasLength(1));
        expect(result.identifiedMap[innerBlankNode], hasLength(1));

        final outerNode = result.identifiedMap[outerBlankNode]!.first;
        expect(outerNode.parent.iriTerm, equals(parentIri));
        expect(outerNode.parentPredicate, equals(outerPredicate));

        final innerNode = result.identifiedMap[innerBlankNode]!.first;
        expect(innerNode.parent.blankNode, equals(outerNode));
        expect(innerNode.parentPredicate, equals(innerPredicate));
      });

      test('multiple paths to same path-identified blank node', () {
        final blankNode = BlankNodeTerm();
        final parentIri = const IriTerm('https://example.com/resource');
        final parentType = const IriTerm('https://example.com/Note');
        final predicate1 = const IriTerm('https://example.com/primarySettings');
        final predicate2 =
            const IriTerm('https://example.com/fallbackSettings');

        final graph = RdfGraph.fromTriples([
          Triple(parentIri, Rdf.type, parentType),
          Triple(parentIri, predicate1, blankNode),
          Triple(parentIri, predicate2, blankNode),
          Triple(blankNode, const IriTerm('https://example.com/value'),
              LiteralTerm('shared')),
        ]);

        final mergeContract = createMergeContract(
          classPredicateAlgorithms: {
            parentType: {
              predicate1: Algo.LWW_Register,
              predicate2: Algo.LWW_Register
            }
          },
        );

        final result = computeIdentifiedBlankNodes(graph, mergeContract);

        expect(result.identifiedMap, hasLength(1));
        // Should have 2 identified nodes with different parent predicates
        expect(result.identifiedMap[blankNode], hasLength(2));

        final predicates = result.identifiedMap[blankNode]!
            .map((ibn) => ibn.parentPredicate)
            .toSet();
        expect(predicates, containsAll([predicate1, predicate2]));
      });
    });

    group('validation - multiple blank nodes at path', () {
      test('throws error when multiple blank nodes at path-identified property',
          () {
        final blankNode1 = BlankNodeTerm();
        final blankNode2 = BlankNodeTerm();
        final parentIri = const IriTerm('https://example.com/resource');
        final parentType = const IriTerm('https://example.com/Category');
        final pathPredicate =
            const IriTerm('https://example.com/displaySettings');

        final graph = RdfGraph.fromTriples([
          Triple(parentIri, Rdf.type, parentType),
          Triple(parentIri, pathPredicate, blankNode1),
          Triple(parentIri, pathPredicate, blankNode2), // Multiple blank nodes!
          Triple(blankNode1, const IriTerm('https://example.com/value'),
              LiteralTerm('value1')),
          Triple(blankNode2, const IriTerm('https://example.com/value'),
              LiteralTerm('value2')),
        ]);

        final mergeContract = createMergeContract(
          classPredicateAlgorithms: {
            parentType: {pathPredicate: Algo.LWW_Register}
          },
        );

        expect(
          () => computeIdentifiedBlankNodes(graph, mergeContract),
          throwsA(isA<SyncConfigValidationException>()
              .having((e) => e.result.errors.length, 'error count', equals(1))
              .having((e) => e.result.errors.first.message, 'error message',
                  contains('blank nodes at the same path'))),
        );
      });

      test(
          'allows multiple blank nodes when mc:disableBlankNodePathIdentification is true',
          () {
        final blankNode1 = BlankNodeTerm();
        final blankNode2 = BlankNodeTerm();
        final parentIri = const IriTerm('https://example.com/resource');
        final parentType = const IriTerm('https://example.com/Category');
        final pathPredicate =
            const IriTerm('https://example.com/displaySettings');

        final graph = RdfGraph.fromTriples([
          Triple(parentIri, Rdf.type, parentType),
          Triple(parentIri, pathPredicate, blankNode1),
          Triple(parentIri, pathPredicate, blankNode2),
          Triple(blankNode1, const IriTerm('https://example.com/value'),
              LiteralTerm('value1')),
          Triple(blankNode2, const IriTerm('https://example.com/value'),
              LiteralTerm('value2')),
        ]);

        final mergeContract = createMergeContract(
          classPredicateAlgorithms: {
            parentType: {pathPredicate: Algo.LWW_Register}
          },
          classDisableBlankNodePathIdentificationPredicates: {
            parentType: {pathPredicate}
          },
        );

        // Should not throw - blank nodes are unidentified (atomic replacement)
        final result = computeIdentifiedBlankNodes(graph, mergeContract);
        expect(result.identifiedMap, isEmpty);
      });

      test(
          'allows multiple blank nodes when they have property-based identification',
          () {
        final blankNode1 = BlankNodeTerm();
        final blankNode2 = BlankNodeTerm();
        final parentIri = const IriTerm('https://example.com/resource');
        final parentType = const IriTerm('https://example.com/Recipe');
        final pathPredicate =
            const IriTerm('https://example.com/recipeIngredient');
        final identifyingProp = const IriTerm('https://example.com/name');

        final graph = RdfGraph.fromTriples([
          Triple(parentIri, Rdf.type, parentType),
          Triple(parentIri, pathPredicate, blankNode1),
          Triple(parentIri, pathPredicate, blankNode2),
          Triple(blankNode1, identifyingProp, LiteralTerm('Tomato')),
          Triple(blankNode2, identifyingProp, LiteralTerm('Basil')),
        ]);

        final mergeContract = createMergeContract(
          classPredicateAlgorithms: {
            parentType: {pathPredicate: Algo.OR_Set}
          },
          classIdentifyingPredicates: {
            parentType: {identifyingProp}
          },
        );

        // Should not throw - blank nodes use property-based identification
        final result = computeIdentifiedBlankNodes(graph, mergeContract);
        expect(result.identifiedMap, hasLength(2));
        expect(result.identifiedMap[blankNode1], isNotEmpty);
        expect(result.identifiedMap[blankNode2], isNotEmpty);
      });
    });
  });
}
