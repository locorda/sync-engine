import 'package:test/test.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:locorda_core/src/mapping/merge_contract.dart';
import 'package:locorda_core/src/generated/algo.dart';

/// Tests for the new getEffectivePredicateRule() logic including:
/// - Class-specific rules with global fallback
/// - Type inference from predicates
/// - Ambiguity handling when multiple types match
void main() {
  late IriTerm classA;
  late IriTerm classB;
  late IriTerm prop1;
  late IriTerm prop2;
  late IriTerm prop3;
  late PredicateMergeRule globalRule1;
  late PredicateMergeRule classRuleA1;

  setUp(() {
    classA = IriTerm('http://example.com/ClassA');
    classB = IriTerm('http://example.com/ClassB');
    prop1 = IriTerm('http://example.com/prop1');
    prop2 = IriTerm('http://example.com/prop2');
    prop3 = IriTerm('http://example.com/prop3');

    globalRule1 = PredicateMergeRule(
      predicateIri: prop1,
      mergeWith: Algo.LWW_Register,
      stopTraversal: false,
      isIdentifying: false,
    );

    classRuleA1 = PredicateMergeRule(
      predicateIri: prop1,
      mergeWith: Algo.OR_Set, // Different from global
      stopTraversal: true, // Different from global
      isIdentifying: null, // Will fall back to global
    );
  });

  group('getEffectivePredicateRule - with type specified', () {
    test('returns class-specific rule when type and rule exist', () {
      final classMapping = ClassMergeRules(classA, {prop1: classRuleA1});
      final contract = MergeContract({classA: classMapping}, {});

      final rule = contract.getEffectivePredicateRule(classA, prop1);

      expect(rule, isNotNull);
      expect(rule!.mergeWith, equals(Algo.OR_Set));
    });

    test('returns global rule when type has no class-specific rule', () {
      final classMapping = ClassMergeRules(classA, {});
      final contract = MergeContract(
        {classA: classMapping},
        {prop2: globalRule1},
      );

      final rule = contract.getEffectivePredicateRule(classA, prop2);

      expect(rule, equals(globalRule1));
    });

    test('returns null when neither class nor global rule exists', () {
      final classMapping = ClassMergeRules(classA, {});
      final contract = MergeContract({classA: classMapping}, {});

      final rule = contract.getEffectivePredicateRule(classA, prop1);

      expect(rule, isNull);
    });
  });

  group('getEffectivePredicateRule - type inference', () {
    test('Class Mapping is inferred from property when no type given', () {
      // This test documents the current buggy behavior
      // _classMappingsByPredicate is indexed by classIri instead of predicateIri
      final classMapping = ClassMergeRules(classA, {prop1: classRuleA1});
      final contract = MergeContract({classA: classMapping}, {});

      // Type inference doesn't work due to bug in line 123
      final rule = contract.getEffectivePredicateRule(null, prop1);

      expect(rule, equals(classRuleA1));
    });

    test('uses global rule when property belongs to multiple classes', () {
      final classMappingA = ClassMergeRules(classA, {prop1: classRuleA1});
      final classMappingB = ClassMergeRules(
        classB,
        {
          prop1: PredicateMergeRule(
            predicateIri: prop1,
            mergeWith: Algo.Immutable,
            stopTraversal: false,
            isIdentifying: false,
          )
        },
      );
      final contract = MergeContract(
        {classA: classMappingA, classB: classMappingB},
        {prop1: globalRule1},
      );

      // prop1 exists in both classA and classB - ambiguous
      final rule = contract.getEffectivePredicateRule(null, prop1);

      // Should fall back to global rule due to ambiguity
      expect(rule, equals(globalRule1));
    });

    test('returns global rule when property exists in no classes', () {
      final classMapping = ClassMergeRules(classA, {prop1: classRuleA1});
      final contract = MergeContract(
        {classA: classMapping},
        {prop3: globalRule1},
      );

      final rule = contract.getEffectivePredicateRule(null, prop3);

      expect(rule, equals(globalRule1));
    });

    test('returns null when no type, no class match, and no global rule', () {
      final classMapping = ClassMergeRules(classA, {prop1: classRuleA1});
      final contract = MergeContract({classA: classMapping}, {});

      final rule = contract.getEffectivePredicateRule(null, prop3);

      expect(rule, isNull);
    });
  });

  group('isStopTraversalPredicate', () {
    test('returns true when class rule has stopTraversal=true', () {
      final classMapping = ClassMergeRules(classA, {prop1: classRuleA1});
      final contract = MergeContract({classA: classMapping}, {});

      expect(contract.isStopTraversalPredicate(classA, prop1), isTrue);
    });

    test('returns false when rule has stopTraversal=false', () {
      final classMapping = ClassMergeRules(classA, {
        prop2: PredicateMergeRule(
          predicateIri: prop2,
          mergeWith: null,
          stopTraversal: false,
          isIdentifying: null,
        )
      });
      final contract = MergeContract({classA: classMapping}, {});

      expect(contract.isStopTraversalPredicate(classA, prop2), isFalse);
    });

    test('returns false when no rule exists', () {
      final contract = MergeContract({}, {});

      expect(contract.isStopTraversalPredicate(classA, prop1), isFalse);
    });

    test('stopTraversal check without type infers class mapping', () {
      final classMapping = ClassMergeRules(classA, {prop1: classRuleA1});
      final contract = MergeContract({classA: classMapping}, {});

      expect(contract.isStopTraversalPredicate(null, prop1), isTrue);
    });
  });

  group('PredicateRule.withFallback', () {
    test('uses own values when present', () {
      final rule = PredicateRule(
        predicateIri: prop1,
        mergeWith: Algo.OR_Set,
        stopTraversal: true,
        isIdentifying: false,
      );
      final fallback = PredicateRule(
        predicateIri: prop1,
        mergeWith: Algo.LWW_Register,
        stopTraversal: false,
        isIdentifying: true,
      );

      final result = rule.withFallback(fallback);

      expect(result.mergeWith, equals(Algo.OR_Set));
      expect(result.stopTraversal, isTrue);
      expect(result.isIdentifying, isFalse);
    });

    test('uses fallback values when own values are null', () {
      final rule = PredicateRule(
        predicateIri: prop1,
        mergeWith: null,
        stopTraversal: null,
        isIdentifying: null,
      );
      final fallback = PredicateRule(
        predicateIri: prop1,
        mergeWith: Algo.LWW_Register,
        stopTraversal: false,
        isIdentifying: true,
      );

      final result = rule.withFallback(fallback);

      expect(result.mergeWith, equals(Algo.LWW_Register));
      expect(result.stopTraversal, isFalse);
      expect(result.isIdentifying, isTrue);
    });

    test('handles null fallback', () {
      final rule = PredicateRule(
        predicateIri: prop1,
        mergeWith: Algo.OR_Set,
        stopTraversal: null,
        isIdentifying: null,
      );

      final result = rule.withFallback(null);

      expect(result.mergeWith, equals(Algo.OR_Set));
      expect(result.stopTraversal, isNull);
      expect(result.isIdentifying, isNull);
    });
  });

  group('PredicateRule.withOptions', () {
    test('creates new rule with updated values', () {
      final original = PredicateRule(
        predicateIri: prop1,
        mergeWith: Algo.LWW_Register,
        stopTraversal: false,
        isIdentifying: false,
      );

      final updated = original.withOptions(
        mergeWith: Algo.OR_Set,
        stopTraversal: true,
      );

      expect(updated.mergeWith, equals(Algo.OR_Set));
      expect(updated.stopTraversal, isTrue);
      expect(updated.isIdentifying, isFalse); // Unchanged
    });

    test('returns same instance when no changes', () {
      final original = PredicateRule(
        predicateIri: prop1,
        mergeWith: Algo.LWW_Register,
        stopTraversal: false,
        isIdentifying: false,
      );

      final unchanged = original.withOptions();

      expect(identical(unchanged, original), isTrue);
    });

    test('returns new instance when values change', () {
      final original = PredicateRule(
        predicateIri: prop1,
        mergeWith: Algo.LWW_Register,
        stopTraversal: false,
        isIdentifying: false,
      );

      final changed = original.withOptions(stopTraversal: true);

      expect(identical(changed, original), isFalse);
      expect(changed.stopTraversal, isTrue);
    });
  });
}
