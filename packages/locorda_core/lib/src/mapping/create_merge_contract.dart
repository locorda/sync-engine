import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_core/src/crdt/crdt_types.dart';
import 'package:locorda_rdf_core/core.dart';
import 'merge_contract.dart';

/// Creates a MergeContract from a list of DocumentMappings
///
/// Follows the precedence order:
/// 1. Local Class Mappings (highest priority)
/// 2. Imported Class Mappings
/// 3. Local Predicate Mappings
/// 4. Imported Predicate Mappings (lowest priority)
///
/// Uses first-wins semantics for conflict resolution
(MergeContract, ValidationResult) createMergeContractFrom(
    List<DocumentMapping> documents,
    {required CrdtTypeRegistry crdtRegistry}) {
  ValidationResult validation = ValidationResult();
  final mergedClassMappings = collectClassMappings(documents);
  final predicateMappings = collectPredicateMappings(documents);

  if (predicateMappings.length > 1) {
    throw StateError('Unexpected multiple merged predicate mappings');
  }

  final predicateRules =
      predicateMappings.firstOrNull?.predicateRules ?? const {};

  // Now, we need to apply the global defaults to the class mappings
  final classMappings = {
    for (final e in mergedClassMappings.entries)
      e.key: _createClassMergeRules(e.value, crdtRegistry, predicateRules)
  };
  final predicateMergeRules = {
    for (final e in predicateRules.entries)
      e.key: _toPredicateMergeRule(e.value, crdtRegistry)
  };

  return (MergeContract(classMappings, predicateMergeRules), validation);
}

ClassMergeRules _createClassMergeRules(
    ClassMapping value,
    CrdtTypeRegistry crdtRegistry,
    Map<RdfPredicate, PredicateRule> predicateRules) {
  // Apply global defaults to the class mapping
  final updatedPropertyRules = {
    for (final entry in value.propertyRules.entries)
      entry.key: _toPredicateMergeRule(
          _applyGlobalDefaultsToRule(entry.value, crdtRegistry, predicateRules),
          crdtRegistry)
  };
  return ClassMergeRules(value.classIri, updatedPropertyRules);
}

PredicateMergeRule _toPredicateMergeRule(
    PredicateRule rule, CrdtTypeRegistry crdtRegistry) {
  final mergeWith = rule.mergeWith;
  final bool isPathIdentifying;
  // FIXME: do we need to validate anything here?
  if (mergeWith != null && crdtRegistry.hasType(mergeWith)) {
    final algo = crdtRegistry.getType(mergeWith);
    isPathIdentifying = algo.isSingleValueSupported &&
        rule.disableBlankNodePathIdentification != true;
  } else {
    isPathIdentifying = false;
  }
  return PredicateMergeRule.fromRule(rule,
      isPathIdentifying: isPathIdentifying);
}

PredicateRule _applyGlobalDefaultsToRule(
    PredicateRule rule,
    CrdtTypeRegistry crdtRegistry,
    Map<RdfPredicate, PredicateRule> predicateRules) {
  final global = predicateRules[rule.predicateIri];
  return global == null ? rule : rule.withFallback(global);
}

/// Recursively collects and merges class mappings from documents and their imports
/// Follows precedence order: local class mappings > imported class mappings
Map<IriTerm, ClassMapping> collectClassMappings(
  Iterable<DocumentMapping> documents,
) {
  if (documents.isEmpty) {
    return {};
  }

  final allImports = documents.expand((d) => d.imports);
  final importedMappings = allImports.isNotEmpty
      ? collectClassMappings(allImports)
      : <IriTerm, ClassMapping>{};

  return mergeClassMappingGroups([
    // First: local class mappings (highest priority)
    ...documents.map((d) => d.classMappings),
    // Second: imported class mappings (lower priority)
    importedMappings
  ]);
}

/// Merges multiple class mapping collections with first-wins semantics
/// When the same class IRI appears in multiple mappings, the first one wins
Map<IriTerm, ClassMapping> mergeClassMappingGroups(
  Iterable<Map<IriTerm, ClassMapping>> classMappingGroups,
) {
  final classMappingsByType = classMappingGroups
      .expand((m) => m.values)
      .fold<Map<IriTerm, List<ClassMapping>>>(
    {},
    (result, mapping) {
      result.putIfAbsent(mapping.classIri, () => []).add(mapping);
      return result;
    },
  );

  final mergedClassMappings = classMappingsByType.entries.map((entry) {
    final mergedPropertyRules = mergePredicateRuleGroups(
      entry.value.map((c) => c.propertyRules),
    );
    return ClassMapping(entry.key, mergedPropertyRules);
  });

  return {for (final mapping in mergedClassMappings) mapping.classIri: mapping};
}

/// Recursively collects and merges predicate mappings from documents and their imports
/// Follows precedence order: local predicate mappings > imported predicate mappings
Iterable<PredicateMapping> collectPredicateMappings(
  Iterable<DocumentMapping> documents,
) {
  if (documents.isEmpty) {
    return [];
  }

  final allImports = documents.expand((d) => d.imports);
  final importedMappings = allImports.isNotEmpty
      ? collectPredicateMappings(allImports)
      : <PredicateMapping>[];

  return mergePredicateMappingGroups([
    // First: local predicate mappings (higher priority)
    ...documents.expand((d) => d.predicateMappings),
    // Second: imported predicate mappings (lower priority)
    ...importedMappings
  ]);
}

/// Merges predicate mappings from multiple PredicateMapping instances
/// Follows first-wins precedence for individual predicate rules
Iterable<PredicateMapping> mergePredicateMappingGroups(
  Iterable<PredicateMapping> predicateMappings,
) {
  if (predicateMappings.isEmpty) {
    return [];
  }

  final mergedRules = mergePredicateRuleGroups(
    predicateMappings.map((mapping) => mapping.predicateRules),
  );

  return [PredicateMapping(mergedRules)];
}

/// Merges multiple collections of predicate rules with first-wins semantics
/// When the same predicate IRI appears in multiple collections, the first rule wins
Map<RdfPredicate, PredicateRule> mergePredicateRuleGroups(
  Iterable<Map<RdfPredicate, PredicateRule>> predicateRuleGroups,
) {
  final mergedRules = <RdfPredicate, PredicateRule>{};

  for (final rules in predicateRuleGroups) {
    for (final entry in rules.entries) {
      // First wins - don't overwrite existing rules
      mergedRules.putIfAbsent(entry.key, () => entry.value);
    }
  }

  return mergedRules;
}
