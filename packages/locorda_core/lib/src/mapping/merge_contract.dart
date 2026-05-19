import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_core/src/crdt/crdt_types.dart';
import 'package:locorda_core/src/vocab/generated/rdf.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:logging/logging.dart';
import 'package:locorda_rdf_core/core.dart';

import 'create_merge_contract.dart';

final _log = Logger('merge_contract');

class PredicateRule {
  final RdfPredicate predicateIri;
  final IriTerm? mergeWith;
  final bool? stopTraversal;
  final bool? isIdentifying;
  final bool? disableBlankNodePathIdentification;
  PredicateRule({
    required this.predicateIri,
    required this.mergeWith,
    required this.stopTraversal,
    required this.isIdentifying,
    this.disableBlankNodePathIdentification,
  });

  PredicateRule withOptions({
    IriTerm? mergeWith,
    bool? stopTraversal,
    bool? isIdentifying,
    bool? disableBlankNodePathIdentification,
  }) {
    final newMergeWith = mergeWith ?? this.mergeWith;
    final newStopTraversal = stopTraversal ?? this.stopTraversal;
    final newIsIdentifying = isIdentifying ?? this.isIdentifying;
    final newDisableBlankNodePathIdentification =
        disableBlankNodePathIdentification ??
            this.disableBlankNodePathIdentification;
    if (newStopTraversal == this.stopTraversal &&
        newIsIdentifying == this.isIdentifying &&
        newDisableBlankNodePathIdentification ==
            this.disableBlankNodePathIdentification &&
        newMergeWith == this.mergeWith) {
      return this;
    }
    return PredicateRule(
      predicateIri: predicateIri,
      mergeWith: newMergeWith,
      stopTraversal: newStopTraversal,
      isIdentifying: newIsIdentifying,
      disableBlankNodePathIdentification: newDisableBlankNodePathIdentification,
    );
  }

  PredicateRule withFallback(PredicateRule? fallbackRule) {
    final newStopTraversal = stopTraversal ?? fallbackRule?.stopTraversal;
    final newIsIdentifying = isIdentifying ?? fallbackRule?.isIdentifying;
    final newDisableBlankNodePathIdentification =
        disableBlankNodePathIdentification ??
            fallbackRule?.disableBlankNodePathIdentification;
    final newMergeWith = mergeWith ?? fallbackRule?.mergeWith;

    return withOptions(
        stopTraversal: newStopTraversal,
        isIdentifying: newIsIdentifying,
        disableBlankNodePathIdentification:
            newDisableBlankNodePathIdentification,
        mergeWith: newMergeWith);
  }
}

class DocumentMapping {
  final RdfSubject documentIri;
  final List<DocumentMapping> imports;
  final Map<IriTerm, ClassMapping> classMappings;
  final List<PredicateMapping> predicateMappings;

  DocumentMapping(
      {required this.documentIri,
      required this.imports,
      required this.classMappings,
      required this.predicateMappings});
}

class PredicateMapping {
  final Map<RdfPredicate, PredicateRule> _predicateRules;
  PredicateMapping(this._predicateRules);

  PredicateRule? getPredicateRule(RdfPredicate propertyIri) =>
      _predicateRules[propertyIri];

  /// Provides read-only access to all predicate rules for merging operations
  Map<RdfPredicate, PredicateRule> get predicateRules =>
      Map.unmodifiable(_predicateRules);
}

class ClassMapping {
  final IriTerm classIri;
  final Map<RdfPredicate, PredicateRule> _propertyRules;
  ClassMapping(this.classIri, this._propertyRules);

  PredicateRule? getPropertyRule(RdfPredicate propertyIri) =>
      _propertyRules[propertyIri];

  /// Provides read-only access to all property rules for merging operations
  Map<RdfPredicate, PredicateRule> get propertyRules =>
      Map.unmodifiable(_propertyRules);
}

class PredicateMergeRule {
  final RdfPredicate predicateIri;
  final IriTerm? mergeWith;
  final bool? stopTraversal;
  final bool? isIdentifying;
  final bool isPathIdentifying;

  PredicateMergeRule(
      {required this.predicateIri,
      this.mergeWith,
      this.stopTraversal,
      this.isIdentifying,
      this.isPathIdentifying = true});

  factory PredicateMergeRule.fromRule(PredicateRule rule,
      {required bool isPathIdentifying}) {
    return PredicateMergeRule(
      predicateIri: rule.predicateIri,
      mergeWith: rule.mergeWith,
      stopTraversal: rule.stopTraversal,
      isIdentifying: rule.isIdentifying,
      isPathIdentifying: isPathIdentifying,
    );
  }
}

class ClassMergeRules {
  final IriTerm classIri;
  final Map<RdfPredicate, PredicateMergeRule> _propertyRules;
  ClassMergeRules(this.classIri, this._propertyRules);

  PredicateMergeRule? getPropertyRule(RdfPredicate propertyIri) =>
      _propertyRules[propertyIri];

  /// Provides read-only access to all property rules for merging operations
  Map<RdfPredicate, PredicateMergeRule> get propertyRules =>
      Map.unmodifiable(_propertyRules);

  late final Set<RdfPredicate> identifyingPredicates =
      _computeIdentifyingPredicates();

  Set<RdfPredicate> _computeIdentifyingPredicates() => _propertyRules.values
      .where((r) => r.isIdentifying ?? false)
      .map((r) => r.predicateIri)
      .toSet();

  /// Predicates that are explicitly marked as non-identifying, this is useful to
  /// override global identifying predicates in certain class contexts.
  late final Set<RdfPredicate> nonIdentifyingPredicates =
      _computeNonIdentifyingPredicates();

  Set<RdfPredicate> _computeNonIdentifyingPredicates() => _propertyRules.values
      .where((r) => r.isIdentifying == false)
      .map((r) => r.predicateIri)
      .toSet();

  late final Set<RdfPredicate> stopTraversalPredicates =
      _computeStopTraversalPredicates();

  Set<RdfPredicate> _computeStopTraversalPredicates() => _propertyRules.values
      .where((r) => r.stopTraversal ?? false)
      .map((r) => r.predicateIri)
      .toSet();
}

class MergeContract {
  final Map<IriTerm, ClassMergeRules> _classMappings;
  final Map<RdfPredicate, PredicateMergeRule> _predicateRules;
  late final Map<RdfPredicate, List<ClassMergeRules>>
      _classMappingsByPredicate = _classMappings.entries.fold({}, (r, e) {
    for (final p in e.value.propertyRules.keys) {
      r.putIfAbsent(p, () => []).add(e.value);
    }
    return r;
  });

  MergeContract(this._classMappings, this._predicateRules) {
    final StringBuffer buffer =
        StringBuffer("\n${'-' * 40}\nMerge Contract:\n${'-' * 40}\n");
    for (final classMapping in _classMappings.values) {
      buffer.writeln('Class: ${classMapping.classIri}');
      for (final propertyRule in classMapping.propertyRules.values) {
        buffer.writeln(
            '  Property: ${propertyRule.predicateIri}, mergeWith: ${propertyRule.mergeWith}, stopTraversal: ${propertyRule.stopTraversal}, isIdentifying: ${propertyRule.isIdentifying}, isPathIdentifying: ${propertyRule.isPathIdentifying}');
      }
    }
    for (final predicateRule in _predicateRules.values) {
      buffer.writeln(
          'Global Property: ${predicateRule.predicateIri}, mergeWith: ${predicateRule.mergeWith}, stopTraversal: ${predicateRule.stopTraversal}, isIdentifying: ${predicateRule.isIdentifying}, isPathIdentifying: ${predicateRule.isPathIdentifying}');
    }
    _log.finest('MergeContract:\n$buffer');
  }

  IriTerm? getEffectiveMergeWith(IriTerm? typeIri, RdfPredicate propertyIri) {
    final rule = getEffectivePredicateRule(typeIri, propertyIri);
    final algorithmIri = rule?.mergeWith;
    if (algorithmIri == null) {
      if (rule == null) {
        _log.warning(
            'No predicate rule found for $propertyIri on $typeIri, using ${CrdtTypeRegistry.fallback.iri.value}.');
      } else {
        _log.fine(
            'No merge algorithm found in rule for $propertyIri on $typeIri, using ${CrdtTypeRegistry.fallback.iri.value}.');
      }
    }
    return rule?.mergeWith;
  }

  PredicateMergeRule? getEffectivePredicateRule(
      IriTerm? typeIri, RdfPredicate propertyIri) {
    final globalRule = _predicateRules[propertyIri];
    if (typeIri != null) {
      final classMapping = getClassMapping(typeIri);
      final rule = classMapping?.getPropertyRule(propertyIri);
      if (rule != null) {
        return rule;
      }
      return globalRule;
    }
    // ok, we do not have a type iri and no global rule.
    // This means we can infer the type from the property
    final inferredTypes = _classMappingsByPredicate[propertyIri] ?? [];
    if (inferredTypes.length == 1) {
      final classMapping = inferredTypes.single;
      final rule = classMapping.getPropertyRule(propertyIri);
      if (rule != null) {
        _log.fine(
            'Inferred type ${classMapping.classIri.debug} for property $propertyIri to apply class-specific merge rule.');
        return rule;
      }
    } else if (inferredTypes.length > 1) {
      _log.warning(
          'Cannot infer unique type for property $propertyIri, found multiple candidate types: ${inferredTypes.map((t) => t.classIri.debug)}. ${globalRule == null ? 'No merge rule available. ' : 'Using global merge rule of this predicate.'}');
    } else {
      if (typeIri != null) {
        _log.warning(
            'No class-specific merge rule found for property $propertyIri on $typeIri. ${globalRule == null ? 'No merge rule available. ' : 'Using global merge rule of this predicate.'}.');
      }
      if (globalRule == null) {
        _log.warning(
            'No merge rule found for property $propertyIri on unknown type, using ${CrdtTypeRegistry.fallback.iri.value}.');
      }
    }
    return globalRule;
  }

  late final Set<RdfPredicate> _globalIdentifyingPredicates =
      _computeIdentifyingPredicates();

  Set<RdfPredicate> _computeIdentifyingPredicates() => _predicateRules.values
      .where((r) => r.isIdentifying ?? false)
      .map((r) => r.predicateIri)
      .toSet();

  Set<RdfPredicate> getIdentifyingPredicates(
      RdfGraph graph, BlankNodeTerm blankNode) {
    final predicates = graph.matching(subject: blankNode).predicates;
    final type = graph.findSingleObject(blankNode, Rdf.type);
    // global identifying predicates are "opportunistic", they only apply if
    // they are actually present on the blank node (and not disabled by the class - see below)
    final global = _globalIdentifyingPredicates.intersection(predicates);
    if (type == null) {
      return predicates
          .where((predicateIri) =>
              getEffectivePredicateRule(null, predicateIri)?.isIdentifying ??
              false)
          .toSet();
    }

    if (!_classMappings.containsKey(type)) {
      // class was specified, but has no mapping - fall back to global only
      return global;
    }

    final classMapping = _classMappings[type];
    final identifyingPredicates =
        classMapping?.identifyingPredicates ?? const <IriTerm>{};
    final nonIdentifyingPredicates =
        classMapping?.nonIdentifyingPredicates ?? const {};
    final effectiveIdentifyingPredicates = <RdfPredicate>{
      ...global,
      ...identifyingPredicates
    }..removeAll(nonIdentifyingPredicates);

    if (effectiveIdentifyingPredicates.isNotEmpty) {
      final missing = effectiveIdentifyingPredicates.difference(predicates);
      // The identifying predicates of the class are required
      if (missing.isEmpty) {
        // great - all identifying predicates are defined
        return effectiveIdentifyingPredicates;
      }

      _log.warning(
          "Found identifiable Blank node ${blankNode} of type ${type} that cannot be identified because it is missing properties ${missing.join(' | ')}.");
      return const {};
    }
    // A class was specified and it is configured, but it had no identifying properties
    // and no global ones are applicable either
    return const {};
  }

  ClassMergeRules? getClassMapping(IriTerm classIri) =>
      _classMappings[classIri];

  PredicateMergeRule? getPredicateMapping(RdfPredicate predicateIri) =>
      _predicateRules[predicateIri];

  static (MergeContract, ValidationResult) fromDocumentMappings(
      List<DocumentMapping> documents,
      {required CrdtTypeRegistry crdtRegistry}) {
    return createMergeContractFrom(documents, crdtRegistry: crdtRegistry);
  }

  bool isStopTraversalPredicate(IriTerm? type, RdfPredicate predicate) {
    return getEffectivePredicateRule(type, predicate)?.stopTraversal ?? false;
  }
}
