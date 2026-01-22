import 'package:locorda_core/src/crdt/crdt_types.dart';
import 'package:locorda_core/src/mapping/merge_contract.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:test/test.dart';

void main() {
  final crdtTypeRegistry = CrdtTypeRegistry.forStandardTypes();

  group('MergeContract', () {
    late IriTerm classIriA;
    late IriTerm classIriB;
    late IriTerm predicateIri1;
    late IriTerm predicateIri2;
    late IriTerm mergeAlgoLWW;
    late PredicateRule predicateRule1;
    late PredicateRule predicateRule2;
    late ClassMapping classMapping;
    late PredicateMergeRule predicateMergeRule1;
    late PredicateMergeRule predicateMergeRule2;
    late ClassMergeRules classMergeRules;

    setUp(() {
      classIriA = IriTerm('http://example.com/ClassA');
      classIriB = IriTerm('http://example.com/ClassB');
      predicateIri1 = IriTerm('http://example.com/predicate1');
      predicateIri2 = IriTerm('http://example.com/predicate2');
      mergeAlgoLWW = IriTerm('http://example.com/algo/LWW');

      predicateRule1 = PredicateRule(
        predicateIri: predicateIri1,
        mergeWith: mergeAlgoLWW,
        stopTraversal: false,
        isIdentifying: false,
      );
      predicateMergeRule1 =
          PredicateMergeRule.fromRule(predicateRule1, isPathIdentifying: true);
      predicateRule2 = PredicateRule(
        predicateIri: predicateIri2,
        mergeWith: mergeAlgoLWW,
        stopTraversal: true,
        isIdentifying: true,
      );
      predicateMergeRule2 =
          PredicateMergeRule.fromRule(predicateRule2, isPathIdentifying: true);

      classMergeRules =
          ClassMergeRules(classIriA, {predicateIri1: predicateMergeRule1});
      classMapping = ClassMapping(classIriA, {predicateIri1: predicateRule1});
    });

    test('should create MergeContract with empty mappings', () {
      final contract = MergeContract({}, {});

      expect(contract.getClassMapping(classIriA), isNull);
      expect(contract.getPredicateMapping(predicateIri1), isNull);
    });

    test('should create MergeContract with class mappings', () {
      final classMappings = {classIriA: classMergeRules};
      final contract = MergeContract(classMappings, {});

      expect(contract.getClassMapping(classIriA), equals(classMergeRules));
      expect(contract.getClassMapping(classIriB), isNull);
      expect(contract.getPredicateMapping(predicateIri1), isNull);
    });

    test('should create MergeContract with predicate mappings', () {
      final predicateRules = {predicateIri1: predicateMergeRule1};
      final contract = MergeContract({}, predicateRules);

      expect(contract.getClassMapping(classIriA), isNull);
      expect(contract.getPredicateMapping(predicateIri1),
          equals(predicateMergeRule1));
      expect(contract.getPredicateMapping(predicateIri2), isNull);
    });

    test('should create MergeContract with both class and predicate mappings',
        () {
      final classMappings = {classIriA: classMergeRules};
      final predicateRules = {predicateIri2: predicateMergeRule2};
      final contract = MergeContract(classMappings, predicateRules);

      expect(contract.getClassMapping(classIriA), equals(classMergeRules));
      expect(contract.getPredicateMapping(predicateIri2),
          equals(predicateMergeRule2));
    });

    group('fromDocumentMappings', () {
      test('should delegate to MergeContractBuilder', () {
        final document = DocumentMapping(
          documentIri: IriTerm('http://example.com/doc1'),
          imports: [],
          classMappings: {classIriA: classMapping},
          predicateMappings: [],
        );

        final (contract, validation) = MergeContract.fromDocumentMappings(
            [document],
            crdtRegistry: crdtTypeRegistry);
        validation.throwIfInvalid();
        expect(contract.getClassMapping(classIriA), isNotNull);
        expect(
            contract.getClassMapping(classIriA)!.classIri, equals(classIriA));
      });
    });
  });

  group('PredicateRule', () {
    test('should create PredicateRule with all properties', () {
      final predicateIri = IriTerm('http://example.com/predicate');
      final mergeWith = IriTerm('http://example.com/algo/LWW');

      final rule = PredicateRule(
        predicateIri: predicateIri,
        mergeWith: mergeWith,
        stopTraversal: true,
        isIdentifying: false,
      );

      expect(rule.predicateIri, equals(predicateIri));
      expect(rule.mergeWith, equals(mergeWith));
      expect(rule.stopTraversal, isTrue);
      expect(rule.isIdentifying, isFalse);
    });

    test('should create PredicateRule with null mergeWith', () {
      final predicateIri = IriTerm('http://example.com/predicate');

      final rule = PredicateRule(
        predicateIri: predicateIri,
        mergeWith: null,
        stopTraversal: false,
        isIdentifying: true,
      );

      expect(rule.predicateIri, equals(predicateIri));
      expect(rule.mergeWith, isNull);
      expect(rule.stopTraversal, isFalse);
      expect(rule.isIdentifying, isTrue);
    });
  });

  group('DocumentMapping', () {
    test('should create DocumentMapping with all properties', () {
      final docIri = IriTerm('http://example.com/doc');
      final importDoc = DocumentMapping(
        documentIri: IriTerm('http://example.com/import'),
        imports: [],
        classMappings: {},
        predicateMappings: [],
      );
      final classMapping =
          ClassMapping(IriTerm('http://example.com/Class'), {});
      final predicateMapping = PredicateMapping({});

      final document = DocumentMapping(
        documentIri: docIri,
        imports: [importDoc],
        classMappings: {classMapping.classIri: classMapping},
        predicateMappings: [predicateMapping],
      );

      expect(document.documentIri, equals(docIri));
      expect(document.imports, hasLength(1));
      expect(document.imports.first, equals(importDoc));
      expect(document.classMappings, hasLength(1));
      expect(document.classMappings.values.first, equals(classMapping));
      expect(document.predicateMappings, hasLength(1));
      expect(document.predicateMappings.first, equals(predicateMapping));
    });
  });

  group('PredicateMapping', () {
    late IriTerm predicateIri1;
    late IriTerm predicateIri2;
    late PredicateRule rule1;
    late PredicateRule rule2;

    setUp(() {
      predicateIri1 = IriTerm('http://example.com/predicate1');
      predicateIri2 = IriTerm('http://example.com/predicate2');

      rule1 = PredicateRule(
        predicateIri: predicateIri1,
        mergeWith: IriTerm('http://example.com/algo/LWW'),
        stopTraversal: false,
        isIdentifying: false,
      );

      rule2 = PredicateRule(
        predicateIri: predicateIri2,
        mergeWith: IriTerm('http://example.com/algo/Set'),
        stopTraversal: true,
        isIdentifying: true,
      );
    });

    test('should create PredicateMapping with rules', () {
      final rules = {predicateIri1: rule1, predicateIri2: rule2};
      final mapping = PredicateMapping(rules);

      expect(mapping.getPredicateRule(predicateIri1), equals(rule1));
      expect(mapping.getPredicateRule(predicateIri2), equals(rule2));
      expect(mapping.getPredicateRule(IriTerm('http://example.com/unknown')),
          isNull);
    });

    test('should provide read-only access to predicate rules', () {
      final rules = {predicateIri1: rule1};
      final mapping = PredicateMapping(rules);

      final readOnlyRules = mapping.predicateRules;
      expect(readOnlyRules, hasLength(1));
      expect(readOnlyRules[predicateIri1], equals(rule1));

      // Should be unmodifiable
      expect(
          () => readOnlyRules[predicateIri2] = rule2, throwsUnsupportedError);
    });

    test('should create empty PredicateMapping', () {
      final mapping = PredicateMapping({});

      expect(mapping.getPredicateRule(predicateIri1), isNull);
      expect(mapping.predicateRules, isEmpty);
    });
  });

  group('ClassMapping', () {
    late IriTerm classIri;
    late IriTerm predicateIri1;
    late IriTerm predicateIri2;
    late PredicateRule rule1;
    late PredicateRule rule2;

    setUp(() {
      classIri = IriTerm('http://example.com/Class');
      predicateIri1 = IriTerm('http://example.com/predicate1');
      predicateIri2 = IriTerm('http://example.com/predicate2');

      rule1 = PredicateRule(
        predicateIri: predicateIri1,
        mergeWith: IriTerm('http://example.com/algo/LWW'),
        stopTraversal: false,
        isIdentifying: false,
      );

      rule2 = PredicateRule(
        predicateIri: predicateIri2,
        mergeWith: IriTerm('http://example.com/algo/Set'),
        stopTraversal: true,
        isIdentifying: true,
      );
    });

    test('should create ClassMapping with property rules', () {
      final propertyRules = {predicateIri1: rule1, predicateIri2: rule2};
      final mapping = ClassMapping(classIri, propertyRules);

      expect(mapping.classIri, equals(classIri));
      expect(mapping.getPropertyRule(predicateIri1), equals(rule1));
      expect(mapping.getPropertyRule(predicateIri2), equals(rule2));
      expect(mapping.getPropertyRule(IriTerm('http://example.com/unknown')),
          isNull);
    });

    test('should provide read-only access to property rules', () {
      final propertyRules = {predicateIri1: rule1};
      final mapping = ClassMapping(classIri, propertyRules);

      final readOnlyRules = mapping.propertyRules;
      expect(readOnlyRules, hasLength(1));
      expect(readOnlyRules[predicateIri1], equals(rule1));

      // Should be unmodifiable
      expect(
          () => readOnlyRules[predicateIri2] = rule2, throwsUnsupportedError);
    });

    test('should create ClassMapping with empty property rules', () {
      final mapping = ClassMapping(classIri, {});

      expect(mapping.classIri, equals(classIri));
      expect(mapping.getPropertyRule(predicateIri1), isNull);
      expect(mapping.propertyRules, isEmpty);
    });
  });
}
