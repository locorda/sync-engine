import 'package:locorda_core/src/crdt/crdt_types.dart';
import 'package:locorda_core/src/mapping/create_merge_contract.dart';
import 'package:locorda_core/src/mapping/merge_contract.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:test/test.dart';

import 'test_matchers.dart';

void main() {
  group('create_merge_contract functions', () {
    late IriTerm classIriA;
    late IriTerm classIriB;
    late IriTerm predicateIri1;
    late IriTerm predicateIri2;
    late IriTerm predicateIri3;
    late IriTerm mergeAlgoLWW;
    late IriTerm mergeAlgoSet;
    late RdfSubject docIri1;
    late RdfSubject docIri2;
    late RdfSubject docIri3;

    setUp(() {
      // Create test IRIs
      classIriA = IriTerm('http://example.com/ClassA');
      classIriB = IriTerm('http://example.com/ClassB');
      predicateIri1 = IriTerm('http://example.com/predicate1');
      predicateIri2 = IriTerm('http://example.com/predicate2');
      predicateIri3 = IriTerm('http://example.com/predicate3');
      mergeAlgoLWW = IriTerm('http://example.com/algo/LWW');
      mergeAlgoSet = IriTerm('http://example.com/algo/Set');

      docIri1 = IriTerm('http://example.com/doc1');
      docIri2 = IriTerm('http://example.com/doc2');
      docIri3 = IriTerm('http://example.com/doc3');
    });

    group('createMergeContractFrom', () {
      test('should build empty contract from empty documents', () {
        final contract = _createValidMergeContractFrom([]);

        expect(contract.getClassMapping(classIriA), isNull);
        expect(contract.getPredicateMapping(predicateIri1), isNull);
      });

      test(
          'should build contract from single document with class mappings only',
          () {
        final propertyRule = PredicateRule(
          predicateIri: predicateIri1,
          mergeWith: mergeAlgoLWW,
          stopTraversal: false,
          isIdentifying: false,
        );

        final classMapping =
            ClassMapping(classIriA, {predicateIri1: propertyRule});
        final document = DocumentMapping(
          documentIri: docIri1,
          imports: [],
          classMappings: {classIriA: classMapping},
          predicateMappings: [],
        );

        final contract = _createValidMergeContractFrom([document]);

        expect(contract.getClassMapping(classIriA), isNotNull);
        expect(
            contract.getClassMapping(classIriA)!.getPropertyRule(predicateIri1),
            hasRuleProperties(propertyRule));
        expect(contract.getPredicateMapping(predicateIri1), isNull);
      });

      test(
          'should build contract from single document with predicate mappings only',
          () {
        final predicateRule = PredicateRule(
          predicateIri: predicateIri1,
          mergeWith: mergeAlgoSet,
          stopTraversal: true,
          isIdentifying: true,
        );

        final predicateMapping =
            PredicateMapping({predicateIri1: predicateRule});
        final document = DocumentMapping(
          documentIri: docIri1,
          imports: [],
          classMappings: {},
          predicateMappings: [predicateMapping],
        );

        final contract = _createValidMergeContractFrom([document]);

        expect(contract.getClassMapping(classIriA), isNull);
        expect(contract.getPredicateMapping(predicateIri1),
            hasRuleProperties(predicateRule));
      });
    });

    group('collectClassMappings', () {
      test('should process empty documents', () {
        final result = collectClassMappings([]);
        expect(result, isEmpty);
      });

      test('should process single document with class mappings', () {
        final propertyRule = PredicateRule(
          predicateIri: predicateIri1,
          mergeWith: mergeAlgoLWW,
          stopTraversal: false,
          isIdentifying: false,
        );

        final classMapping =
            ClassMapping(classIriA, {predicateIri1: propertyRule});
        final document = DocumentMapping(
          documentIri: docIri1,
          imports: [],
          classMappings: {classIriA: classMapping},
          predicateMappings: [],
        );

        final result = collectClassMappings([document]);

        expect(result, hasLength(1));
        expect(result[classIriA], isNotNull);
        expect(result[classIriA]!.getPropertyRule(predicateIri1),
            matchesRule(propertyRule));
      });

      test('should respect first-wins precedence for local mappings', () {
        final rule1 = PredicateRule(
          predicateIri: predicateIri1,
          mergeWith: mergeAlgoLWW,
          stopTraversal: false,
          isIdentifying: false,
        );

        final rule2 = PredicateRule(
          predicateIri: predicateIri1,
          mergeWith: mergeAlgoSet,
          stopTraversal: true,
          isIdentifying: true,
        );

        final classMapping1 = ClassMapping(classIriA, {predicateIri1: rule1});
        final classMapping2 = ClassMapping(classIriA, {predicateIri1: rule2});

        final doc1 = DocumentMapping(
          documentIri: docIri1,
          imports: [],
          classMappings: {classIriA: classMapping1},
          predicateMappings: [],
        );

        final doc2 = DocumentMapping(
          documentIri: docIri2,
          imports: [],
          classMappings: {classIriA: classMapping2},
          predicateMappings: [],
        );

        final result = collectClassMappings([doc1, doc2]);

        expect(result[classIriA]!.getPropertyRule(predicateIri1),
            matchesRule(rule1));
      });

      test('should process imports with correct precedence', () {
        final localRule = PredicateRule(
          predicateIri: predicateIri1,
          mergeWith: mergeAlgoLWW,
          stopTraversal: false,
          isIdentifying: false,
        );

        final importedRule = PredicateRule(
          predicateIri: predicateIri1,
          mergeWith: mergeAlgoSet,
          stopTraversal: true,
          isIdentifying: true,
        );

        final localMapping =
            ClassMapping(classIriA, {predicateIri1: localRule});
        final importedMapping =
            ClassMapping(classIriA, {predicateIri1: importedRule});

        final importedDoc = DocumentMapping(
          documentIri: docIri2,
          imports: [],
          classMappings: {classIriA: importedMapping},
          predicateMappings: [],
        );

        final mainDoc = DocumentMapping(
          documentIri: docIri1,
          imports: [importedDoc],
          classMappings: {classIriA: localMapping},
          predicateMappings: [],
        );

        final result = collectClassMappings([mainDoc]);

        // Local rule should win over imported rule
        expect(result[classIriA]!.getPropertyRule(predicateIri1),
            matchesRule(localRule));
      });

      test('should merge properties from same class across documents', () {
        final rule1 = PredicateRule(
          predicateIri: predicateIri1,
          mergeWith: mergeAlgoLWW,
          stopTraversal: false,
          isIdentifying: false,
        );

        final rule2 = PredicateRule(
          predicateIri: predicateIri2,
          mergeWith: mergeAlgoSet,
          stopTraversal: true,
          isIdentifying: true,
        );

        final mapping1 = ClassMapping(classIriA, {predicateIri1: rule1});
        final mapping2 = ClassMapping(classIriA, {predicateIri2: rule2});

        final doc1 = DocumentMapping(
          documentIri: docIri1,
          imports: [],
          classMappings: {classIriA: mapping1},
          predicateMappings: [],
        );

        final doc2 = DocumentMapping(
          documentIri: docIri2,
          imports: [],
          classMappings: {classIriA: mapping2},
          predicateMappings: [],
        );

        final result = collectClassMappings([doc1, doc2]);

        expect(result[classIriA]!.getPropertyRule(predicateIri1),
            matchesRule(rule1));
        expect(result[classIriA]!.getPropertyRule(predicateIri2),
            matchesRule(rule2));
      });
    });

    group('mergeClassMappingGroups', () {
      test('should merge empty collections', () {
        final result = mergeClassMappingGroups([]);
        expect(result, isEmpty);
      });

      test('should merge collections with different classes', () {
        final ruleA = PredicateRule(
          predicateIri: predicateIri1,
          mergeWith: mergeAlgoLWW,
          stopTraversal: false,
          isIdentifying: false,
        );

        final ruleB = PredicateRule(
          predicateIri: predicateIri2,
          mergeWith: mergeAlgoSet,
          stopTraversal: true,
          isIdentifying: true,
        );

        final mappingA = ClassMapping(classIriA, {predicateIri1: ruleA});
        final mappingB = ClassMapping(classIriB, {predicateIri2: ruleB});

        final collection1 = {classIriA: mappingA};
        final collection2 = {classIriB: mappingB};

        final result = mergeClassMappingGroups([collection1, collection2]);

        expect(result, hasLength(2));
        expect(result[classIriA]!.getPropertyRule(predicateIri1),
            matchesRule(ruleA));
        expect(result[classIriB]!.getPropertyRule(predicateIri2),
            matchesRule(ruleB));
      });
    });

    group('collectPredicateMappings', () {
      test('should process empty documents', () {
        final result = collectPredicateMappings([]);
        expect(result, isEmpty);
      });

      test('should process single document with predicate mappings', () {
        final rule = PredicateRule(
          predicateIri: predicateIri1,
          mergeWith: mergeAlgoLWW,
          stopTraversal: false,
          isIdentifying: false,
        );

        final predicateMapping = PredicateMapping({predicateIri1: rule});
        final document = DocumentMapping(
          documentIri: docIri1,
          imports: [],
          classMappings: {},
          predicateMappings: [predicateMapping],
        );

        final result = collectPredicateMappings([document]).toList();

        expect(result, hasLength(1));
        expect(result.first.getPredicateRule(predicateIri1), matchesRule(rule));
      });
    });

    group('mergePredicateMappingGroups', () {
      test('should return empty for empty input', () {
        final result = mergePredicateMappingGroups([]);
        expect(result, isEmpty);
      });

      test('should merge multiple predicate mappings', () {
        final rule1 = PredicateRule(
          predicateIri: predicateIri1,
          mergeWith: mergeAlgoLWW,
          stopTraversal: false,
          isIdentifying: false,
        );

        final rule2 = PredicateRule(
          predicateIri: predicateIri2,
          mergeWith: mergeAlgoSet,
          stopTraversal: true,
          isIdentifying: true,
        );

        final mapping1 = PredicateMapping({predicateIri1: rule1});
        final mapping2 = PredicateMapping({predicateIri2: rule2});

        final result =
            mergePredicateMappingGroups([mapping1, mapping2]).toList();

        expect(result, hasLength(1));
        expect(
            result.first.getPredicateRule(predicateIri1), matchesRule(rule1));
        expect(
            result.first.getPredicateRule(predicateIri2), matchesRule(rule2));
      });
    });

    group('mergePredicateRuleGroups', () {
      test('should merge empty collections', () {
        final result = mergePredicateRuleGroups([]);
        expect(result, isEmpty);
      });

      test('should merge collections with different predicates', () {
        final rule1 = PredicateRule(
          predicateIri: predicateIri1,
          mergeWith: mergeAlgoLWW,
          stopTraversal: false,
          isIdentifying: false,
        );

        final rule2 = PredicateRule(
          predicateIri: predicateIri2,
          mergeWith: mergeAlgoSet,
          stopTraversal: true,
          isIdentifying: true,
        );

        final collection1 = {predicateIri1: rule1};
        final collection2 = {predicateIri2: rule2};

        final result = mergePredicateRuleGroups([collection1, collection2]);

        expect(result, hasLength(2));
        expect(result[predicateIri1], matchesRule(rule1));
        expect(result[predicateIri2], matchesRule(rule2));
      });

      test('should use first-wins for overlapping predicates', () {
        final rule1 = PredicateRule(
          predicateIri: predicateIri1,
          mergeWith: mergeAlgoLWW,
          stopTraversal: false,
          isIdentifying: false,
        );

        final rule2 = PredicateRule(
          predicateIri: predicateIri1,
          mergeWith: mergeAlgoSet,
          stopTraversal: true,
          isIdentifying: true,
        );

        final collection1 = {predicateIri1: rule1};
        final collection2 = {predicateIri1: rule2};

        final result = mergePredicateRuleGroups([collection1, collection2]);

        expect(result, hasLength(1));
        expect(result[predicateIri1], matchesRule(rule1));
      });
    });

    group('complex scenarios', () {
      test('should handle deep import hierarchies', () {
        final baseRule = PredicateRule(
          predicateIri: predicateIri1,
          mergeWith: mergeAlgoLWW,
          stopTraversal: false,
          isIdentifying: false,
        );

        final middleRule = PredicateRule(
          predicateIri: predicateIri2,
          mergeWith: mergeAlgoSet,
          stopTraversal: true,
          isIdentifying: true,
        );

        final topRule = PredicateRule(
          predicateIri: predicateIri3,
          mergeWith: mergeAlgoLWW,
          stopTraversal: false,
          isIdentifying: true,
        );

        final baseMapping = ClassMapping(classIriA, {predicateIri1: baseRule});
        final middleMapping =
            ClassMapping(classIriA, {predicateIri2: middleRule});
        final topMapping = ClassMapping(classIriA, {predicateIri3: topRule});

        final baseDoc = DocumentMapping(
          documentIri: docIri3,
          imports: [],
          classMappings: {classIriA: baseMapping},
          predicateMappings: [],
        );

        final middleDoc = DocumentMapping(
          documentIri: docIri2,
          imports: [baseDoc],
          classMappings: {classIriA: middleMapping},
          predicateMappings: [],
        );

        final topDoc = DocumentMapping(
          documentIri: docIri1,
          imports: [middleDoc],
          classMappings: {classIriA: topMapping},
          predicateMappings: [],
        );

        final contract = _createValidMergeContractFrom([topDoc]);

        // All rules should be present in the final merged class
        final finalMapping = contract.getClassMapping(classIriA)!;
        expect(finalMapping.getPropertyRule(predicateIri1),
            hasRuleProperties(baseRule, expectedIsPathIdentifying: false));
        expect(finalMapping.getPropertyRule(predicateIri2),
            hasRuleProperties(middleRule, expectedIsPathIdentifying: false));
        expect(finalMapping.getPropertyRule(predicateIri3),
            hasRuleProperties(topRule, expectedIsPathIdentifying: false));
      });

      test('should handle mixed class and predicate mappings', () {
        final classRule = PredicateRule(
          predicateIri: predicateIri1,
          mergeWith: mergeAlgoLWW,
          stopTraversal: false,
          isIdentifying: false,
        );

        final predicateRule = PredicateRule(
          predicateIri: predicateIri2,
          mergeWith: mergeAlgoSet,
          stopTraversal: true,
          isIdentifying: true,
        );

        final classMapping =
            ClassMapping(classIriA, {predicateIri1: classRule});
        final predicateMapping =
            PredicateMapping({predicateIri2: predicateRule});

        final document = DocumentMapping(
          documentIri: docIri1,
          imports: [],
          classMappings: {classIriA: classMapping},
          predicateMappings: [predicateMapping],
        );

        final contract = _createValidMergeContractFrom([document]);

        expect(
            contract.getClassMapping(classIriA)!.getPropertyRule(predicateIri1),
            hasRuleProperties(classRule, expectedIsPathIdentifying: false));
        expect(contract.getPredicateMapping(predicateIri2),
            hasRuleProperties(predicateRule, expectedIsPathIdentifying: false));
      });
    });
  });
}

final _crdtTypeRegistry = CrdtTypeRegistry.forStandardTypes();

MergeContract _createValidMergeContractFrom(List<DocumentMapping> documents) {
  final (result, validation) =
      createMergeContractFrom(documents, crdtRegistry: _crdtTypeRegistry);
  validation.throwIfInvalid();
  return result;
}
