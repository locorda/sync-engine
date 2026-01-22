import 'package:locorda_core/src/crdt/crdt_types.dart';
import 'package:locorda_core/src/mapping/create_merge_contract.dart';
import 'package:locorda_core/src/mapping/merge_contract.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:test/test.dart';

import 'test_matchers.dart';

/// Integration tests verifying the complete precedence hierarchy
/// as specified in the CRDT specification section 5.2.2.3
void main() {
  group('MergeContract Integration Tests', () {
    late IriTerm classIri;
    late IriTerm predicateIri;
    late IriTerm conflictingPredicateIri;
    late IriTerm frameworkAlgo;
    late IriTerm appAlgo;
    late IriTerm localAlgo;
    late RdfSubject coreDoc;
    late RdfSubject appDoc;
    late RdfSubject mainDoc;

    setUp(() {
      classIri = IriTerm('http://app.com/ShoppingListEntry');
      predicateIri = IriTerm('http://app.com/item');
      conflictingPredicateIri = IriTerm('http://crdt.com/installationId');

      frameworkAlgo = IriTerm('http://algo.com/Framework_LWW');
      appAlgo = IriTerm('http://algo.com/App_LWW');
      localAlgo = IriTerm('http://algo.com/Local_LWW');

      coreDoc = IriTerm('http://mappings.com/core-v1');
      appDoc = IriTerm('http://mappings.com/app-v1');
      mainDoc = IriTerm('http://mappings.com/main');
    });

    test('should implement complete precedence hierarchy from specification',
        () {
      // Framework/Core mapping (imported by app, which is imported by main)
      // Provides global predicate mapping for CRDT infrastructure
      final frameworkPredicateRule = PredicateRule(
        predicateIri: conflictingPredicateIri,
        mergeWith: frameworkAlgo,
        stopTraversal: false,
        isIdentifying: true,
      );

      final coreMapping =
          PredicateMapping({conflictingPredicateIri: frameworkPredicateRule});

      final coreDocument = DocumentMapping(
        documentIri: coreDoc,
        imports: [],
        classMappings: {},
        predicateMappings: [coreMapping],
      );

      // Application-level mapping (imports core, imported by main)
      // Provides domain-specific class mapping + conflicting predicate rule
      final appClassRule = PredicateRule(
        predicateIri: predicateIri,
        mergeWith: appAlgo,
        stopTraversal: false,
        isIdentifying: false,
      );

      final appConflictRule = PredicateRule(
        predicateIri: conflictingPredicateIri,
        mergeWith: appAlgo, // Should lose to local class mapping
        stopTraversal: true,
        isIdentifying: false,
      );

      final appClassMapping = ClassMapping(classIri, {
        predicateIri: appClassRule,
        conflictingPredicateIri: appConflictRule,
      });

      final appDocument = DocumentMapping(
        documentIri: appDoc,
        imports: [coreDocument],
        classMappings: {classIri: appClassMapping},
        predicateMappings: [],
      );

      // Main document (top-level, imports app)
      // Provides local class mapping that should win over everything
      final localClassRule = PredicateRule(
        predicateIri: conflictingPredicateIri,
        mergeWith: localAlgo,
        stopTraversal: false,
        isIdentifying: true,
      );

      final localClassMapping = ClassMapping(classIri, {
        conflictingPredicateIri: localClassRule,
      });

      final mainDocument = DocumentMapping(
        documentIri: mainDoc,
        imports: [appDocument],
        classMappings: {classIri: localClassMapping},
        predicateMappings: [],
      );

      // Build the contract and verify precedence
      final contract = _createValidMergeContractFrom([mainDocument]);

      // Verify class mapping exists and has merged properties correctly
      final finalClassMapping = contract.getClassMapping(classIri);
      expect(finalClassMapping, isNotNull);

      // 1. Local class mapping should win (conflictingPredicateIri)
      // This tests: Local Class Mappings > Imported Class Mappings
      expect(
        finalClassMapping!.getPropertyRule(conflictingPredicateIri),
        hasRuleProperties(localClassRule),
        reason: 'Local class mapping should win over imported class mapping',
      );

      // 2. Imported class mapping should be preserved (predicateIri)
      // This tests: merging of non-conflicting properties
      expect(
        finalClassMapping.getPropertyRule(predicateIri),
        hasRuleProperties(appClassRule),
        reason: 'Non-conflicting imported class mapping should be preserved',
      );

      // 3. Global predicate mapping should be used as fallback
      // This tests: Class Mappings > Predicate Mappings precedence
      expect(
        contract.getPredicateMapping(conflictingPredicateIri),
        hasRuleProperties(frameworkPredicateRule),
        reason: 'Framework predicate mapping should be available as fallback',
      );
    });

    test('should handle multiple import levels with correct precedence', () {
      // Level 1: Base framework
      final baseRule = PredicateRule(
        predicateIri: conflictingPredicateIri,
        mergeWith: frameworkAlgo,
        stopTraversal: false,
        isIdentifying: true,
      );

      final baseMapping = PredicateMapping({conflictingPredicateIri: baseRule});
      final baseDoc = DocumentMapping(
        documentIri: IriTerm('http://base.com/core'),
        imports: [],
        classMappings: {},
        predicateMappings: [baseMapping],
      );

      // Level 2: Middle framework (imports base)
      final middleRule = PredicateRule(
        predicateIri: conflictingPredicateIri,
        mergeWith: appAlgo,
        stopTraversal: true,
        isIdentifying: false,
      );

      final middleMapping =
          PredicateMapping({conflictingPredicateIri: middleRule});
      final middleDoc = DocumentMapping(
        documentIri: IriTerm('http://middle.com/framework'),
        imports: [baseDoc],
        classMappings: {},
        predicateMappings: [middleMapping],
      );

      // Level 3: Top application (imports middle)
      final topRule = PredicateRule(
        predicateIri: conflictingPredicateIri,
        mergeWith: localAlgo,
        stopTraversal: false,
        isIdentifying: true,
      );

      final topMapping = PredicateMapping({conflictingPredicateIri: topRule});
      final topDoc = DocumentMapping(
        documentIri: IriTerm('http://top.com/app'),
        imports: [middleDoc],
        classMappings: {},
        predicateMappings: [topMapping],
      );

      final contract = _createValidMergeContractFrom([topDoc]);

      // Top-level should win due to first-wins precedence
      expect(
        contract.getPredicateMapping(conflictingPredicateIri),
        hasRuleProperties(topRule),
        reason: 'Top-level predicate mapping should win in import hierarchy',
      );
    });

    test('should handle complex class and predicate mapping interactions', () {
      final classA = IriTerm('http://app.com/ClassA');
      final classB = IriTerm('http://app.com/ClassB');
      final prop1 = IriTerm('http://app.com/prop1');
      final prop2 = IriTerm('http://app.com/prop2');
      final prop3 = IriTerm('http://app.com/prop3');

      // Create rules for different contexts
      final classARule1 = PredicateRule(
        predicateIri: prop1,
        mergeWith: localAlgo,
        stopTraversal: false,
        isIdentifying: false,
      );

      final classBRule2 = PredicateRule(
        predicateIri: prop2,
        mergeWith: appAlgo,
        stopTraversal: true,
        isIdentifying: true,
      );

      final globalRule3 = PredicateRule(
        predicateIri: prop3,
        mergeWith: frameworkAlgo,
        stopTraversal: false,
        isIdentifying: true,
      );

      // Set up documents with mixed mappings
      final classAMapping = ClassMapping(classA, {prop1: classARule1});
      final classBMapping = ClassMapping(classB, {prop2: classBRule2});
      final globalMapping = PredicateMapping({prop3: globalRule3});

      final document = DocumentMapping(
        documentIri: mainDoc,
        imports: [],
        classMappings: {
          classA: classAMapping,
          classB: classBMapping,
        },
        predicateMappings: [globalMapping],
      );

      final contract = _createValidMergeContractFrom([document]);

      // Verify all mappings are preserved correctly
      expect(contract.getClassMapping(classA)!.getPropertyRule(prop1),
          hasRuleProperties(classARule1));
      expect(contract.getClassMapping(classB)!.getPropertyRule(prop2),
          hasRuleProperties(classBRule2));
      expect(
          contract.getPredicateMapping(prop3), hasRuleProperties(globalRule3));

      // Verify class mappings don't interfere with each other
      expect(contract.getClassMapping(classA)!.getPropertyRule(prop2), isNull);
      expect(contract.getClassMapping(classB)!.getPropertyRule(prop1), isNull);
    });

    test('should correctly merge properties within same class across documents',
        () {
      final prop1 = IriTerm('http://app.com/prop1');
      final prop2 = IriTerm('http://app.com/prop2');
      final prop3 = IriTerm('http://app.com/prop3');

      final rule1 = PredicateRule(
        predicateIri: prop1,
        mergeWith: localAlgo,
        stopTraversal: false,
        isIdentifying: false,
      );

      final rule2 = PredicateRule(
        predicateIri: prop2,
        mergeWith: appAlgo,
        stopTraversal: true,
        isIdentifying: true,
      );

      final rule3Conflict = PredicateRule(
        predicateIri: prop3,
        mergeWith: frameworkAlgo,
        stopTraversal: false,
        isIdentifying: true,
      );

      final rule3Winner = PredicateRule(
        predicateIri: prop3,
        mergeWith: localAlgo, // Should win over rule3Conflict
        stopTraversal: true,
        isIdentifying: false,
      );

      // First document: contributes prop1 and prop3
      final mapping1 = ClassMapping(classIri, {
        prop1: rule1,
        prop3: rule3Winner, // This should win
      });

      final doc1 = DocumentMapping(
        documentIri: IriTerm('http://doc1.com'),
        imports: [],
        classMappings: {classIri: mapping1},
        predicateMappings: [],
      );

      // Second document: contributes prop2 and conflicts on prop3
      final mapping2 = ClassMapping(classIri, {
        prop2: rule2,
        prop3: rule3Conflict, // This should lose
      });

      final doc2 = DocumentMapping(
        documentIri: IriTerm('http://doc2.com'),
        imports: [],
        classMappings: {classIri: mapping2},
        predicateMappings: [],
      );

      final contract = _createValidMergeContractFrom([doc1, doc2]);
      final finalMapping = contract.getClassMapping(classIri)!;

      // All properties should be present
      expect(finalMapping.getPropertyRule(prop1), hasRuleProperties(rule1));
      expect(finalMapping.getPropertyRule(prop2), hasRuleProperties(rule2));

      // First-wins should resolve the conflict
      expect(
          finalMapping.getPropertyRule(prop3), hasRuleProperties(rule3Winner));
    });
  });
}

MergeContract _createValidMergeContractFrom(List<DocumentMapping> documents) {
  final (result, validation) = createMergeContractFrom(documents,
      crdtRegistry: CrdtTypeRegistry.forStandardTypes());
  validation.throwIfInvalid();
  return result;
}
