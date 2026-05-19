import 'dart:collection';

import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_core/src/crdt/crdt_types.dart';
import 'package:locorda_core/src/vocab/generated/_index.dart';
import 'package:locorda_core/src/mapping/merge_contract.dart';
import 'package:locorda_core/src/mapping/recursive_rdf_loader.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/util/lru_cache.dart';
import 'package:logging/logging.dart';
import 'package:locorda_rdf_core/core.dart';

final _log = Logger('MergeContractLoader');

class DocumentMappingDependencyExtractor implements DependencyExtractor {
  const DocumentMappingDependencyExtractor();
  @override
  IriTerm? forType() => McDocumentMapping.classIri;

  @override
  Iterable<IriTerm> extractDependencies(RdfSubject subj, RdfGraph graph) {
    final imports =
        graph.getListObjects<IriTerm>(subj, McDocumentMapping.imports);
    final classMappings =
        graph.getListObjects<IriTerm>(subj, McDocumentMapping.classMapping);
    final predicateMappings =
        graph.getListObjects<IriTerm>(subj, McDocumentMapping.predicateMapping);
    return [...imports, ...classMappings, ...predicateMappings];
  }
}

class CachingMergeContractLoader extends MergeContractLoader {
  final MergeContractLoader _inner;
  final MergeContractLoader? _bootstrapInner;
  final Duration refreshInterval;
  final LRUCache<String, Future<MergeContract>> _cache;
  final Map<String, DateTime> _lastRefresh = {};
  final Map<String, Future<void>> _refreshInFlight = {};

  CachingMergeContractLoader(this._inner,
      {MergeContractLoader? bootstrapInner,
      this.refreshInterval = const Duration(minutes: 30),
      int maxCacheSize = 50})
      : _bootstrapInner = bootstrapInner,
        _cache = LRUCache(maxCacheSize: maxCacheSize);

  String _cacheKey(List<IriTerm> iris) => iris.length == 1
      ? iris.first.value
      : iris.map((iri) => iri.value).join('|');

  @override
  Future<MergeContract> load(List<IriTerm> isGovernedBy) {
    final key = _cacheKey(isGovernedBy);

    // Check if already in cache (and move to end for LRU)
    if (_cache.containsKey(key)) {
      _maybeRefresh(key, isGovernedBy);
      return _cache[key]!;
    }

    return _loadCold(key, isGovernedBy);
  }

  Future<MergeContract> _loadCold(String key, List<IriTerm> isGovernedBy) {
    return _loadAndCache(key, () async {
      if (_bootstrapInner != null) {
        try {
          final result = await _bootstrapInner.load(isGovernedBy);
          _maybeRefresh(key, isGovernedBy, force: true);
          return result;
        } catch (e, stackTrace) {
          _log.info(
              'Bootstrap loader failed for $key, falling back to online loader',
              e,
              stackTrace);
          return _inner.load(isGovernedBy);
        }
      }
      return _inner.load(isGovernedBy);
    });
  }

  Future<MergeContract> _loadAndCache(
      String key, Future<MergeContract> Function() loader) {
    final future = loader().catchError((Object error) {
      // Remove from cache on error to allow retry
      _cache.remove(key);
      return Future<MergeContract>.error(error);
    });
    _cache[key] = future;
    return future;
  }

  void _maybeRefresh(String key, List<IriTerm> isGovernedBy,
      {bool force = false}) {
    if (_refreshInFlight.containsKey(key)) return;
    if (!force) {
      final last = _lastRefresh[key];
      if (last != null && DateTime.now().difference(last) < refreshInterval) {
        return;
      }
    }

    final refresh = _inner.load(isGovernedBy).then((result) {
      _cache[key] = Future.value(result);
      _lastRefresh[key] = DateTime.now();
    }).catchError((Object error, StackTrace? stackTrace) {
      _log.fine(
          'Online loader refresh failed for $key, keeping cached value. Will ignore because this is a non-critical refresh and the file is probably unchanged anyways. \nError: $error');
      // Keep cached value on refresh failure.
    }).whenComplete(() {
      _refreshInFlight.remove(key);
    });

    _refreshInFlight[key] = refresh;
  }
}

abstract interface class MergeContractLoader {
  Future<MergeContract> load(List<IriTerm> isGovernedBy);

  List<IriTerm> extractGovernanceIris(RdfGraph document, IriTerm documentIri) {
    return document.getListObjects<IriTerm>(
        documentIri, SyncManagedDocument.isGovernedBy);
  }

  List<IriTerm> getMergedGovernanceIris(
      List<RdfGraph> documents, IriTerm documentIri) {
    final iriLists = documents
        .map(
          (doc) => extractGovernanceIris(doc, documentIri),
        )
        .toList();
    return iriLists.fold((<IriTerm>[], <IriTerm>{}), (acc, v) {
      final (result, seen) = acc;
      for (final iri in v) {
        if (!seen.contains(iri)) {
          result.add(iri);
          seen.add(iri);
        }
      }
      return (result, seen);
    }).$1;
  }
}

class StandardMergeContractLoader extends MergeContractLoader {
  final RecursiveRdfLoader fetcher;
  final CrdtTypeRegistry _crdtRegistry;

  StandardMergeContractLoader(this.fetcher, this._crdtRegistry);

  @override
  Future<MergeContract> load(List<IriTerm> isGovernedBy) async {
    final ValidationResult validation = ValidationResult();
    final loadedContractDocuments = await fetcher.loadRdfDocumentsRecursively(
        isGovernedBy,
        extractors: const [DocumentMappingDependencyExtractor()]);
    final all = loadedContractDocuments.values.mergeGraphs();

    // Parse loaded RDF graphs and extract mappings
    final parsedDocuments =
        isGovernedBy.map((iri) => _parseDocumentMapping(all, iri)).toList();
    final documents = parsedDocuments.map((e) => e.$1).toList();
    for (var v in parsedDocuments.map((e) => e.$2).where((v) => v.hasIssues)) {
      validation.addSubvalidationResult(v, context: "sync:isGovernedBy");
    }
    final (result, resultValidation) = MergeContract.fromDocumentMappings(
        documents,
        crdtRegistry: _crdtRegistry);
    validation.addSubvalidationResult(resultValidation,
        context: "During merge contract creation");
    validation.throwIfInvalid();
    return result;
  }

  (DocumentMapping, ValidationResult) _parseDocumentMapping(
      RdfGraph all, RdfSubject subject,
      [Set<RdfSubject>? visited]) {
    final ValidationResult validation = ValidationResult(
        switch (subject) {
          final IriTerm iri => iri.value,
          final BlankNodeTerm bnode => "Blank Node $bnode"
        },
        {'document': subject});
    final seen = visited ?? <RdfSubject>{};
    seen.add(subject);

    final importRefs =
        all.getListObjects<RdfSubject>(subject, McDocumentMapping.imports);
    final classMappingRefs =
        all.getListObjects<RdfSubject>(subject, McDocumentMapping.classMapping);
    final predicateMappingRefs = all.getListObjects<RdfSubject>(
        subject, McDocumentMapping.predicateMapping);
    final (classMappings, classMappingsValidation) =
        _parseClassMappings(all, classMappingRefs);
    validation.addSubvalidationResult(
      classMappingsValidation,
    );
    final parsedPredicateMappings = predicateMappingRefs
        .map((ref) => _parsePredicateMapping(all, ref))
        .toList();
    final predicateMappings =
        parsedPredicateMappings.map((e) => e.$1).nonNulls.toList();
    for (var v
        in parsedPredicateMappings.map((e) => e.$2).where((v) => v.hasIssues)) {
      validation.addSubvalidationResult(v);
    }
    final parsedImports = importRefs
        .where((ref) {
          if (seen.contains(ref)) {
            _log.warning(
                'Detected cyclic import in merge contract at $ref, skipping.');
            validation.addError('Cyclic import in merge contract at $ref');
            return false;
          } else {
            return true;
          }
        })
        .map((ref) => _parseDocumentMapping(all, ref, seen))
        .toList();
    final imports = parsedImports.map((e) => e.$1).toList();
    for (var v in parsedImports.map((e) => e.$2).where((v) => v.hasIssues)) {
      validation.addSubvalidationResult(v, context: "mc:imports");
    }
    return (
      DocumentMapping(
          documentIri: subject,
          imports: imports,
          classMappings: classMappings,
          predicateMappings: predicateMappings),
      validation
    );
  }

  (PredicateRule?, ValidationResult) _parseRule(
      RdfGraph graph, RdfSubject ref) {
    final ValidationResult validation = ValidationResult();
    final predicateIri = graph.findSingleObject<IriTerm>(ref, McRule.predicate);
    if (predicateIri == null) {
      _log.warning('Predicate mapping missing mc:predicate: $ref');
      validation.addError('Predicate mapping missing mc:predicate');
      return (null, validation);
    }
    final mergeWithIri =
        graph.findSingleObject<IriTerm>(ref, McRule.algoMergeWith);
    if (mergeWithIri != null) {
      if (!_crdtRegistry.hasType(mergeWithIri)) {
        validation.addError(
            'Unknown CRDT type ${mergeWithIri.value} in predicate rule '
            'for predicate ${predicateIri}');
      }
    }
    final stopTraversal = graph
        .findSingleObject<LiteralTerm>(ref, McRule.stopTraversal)
        ?.booleanValue;
    final isIdentifying = graph
        .findSingleObject<LiteralTerm>(ref, McRule.isIdentifying)
        ?.booleanValue;
    final disableBlankNodePathIdentification = graph
        .findSingleObject<LiteralTerm>(
            ref, McRule.disableBlankNodePathIdentification)
        ?.booleanValue;

    final result = PredicateRule(
      predicateIri: predicateIri,
      mergeWith: mergeWithIri,
      stopTraversal: stopTraversal,
      isIdentifying: isIdentifying,
      disableBlankNodePathIdentification: disableBlankNodePathIdentification,
    );
    return (result, validation);
  }

  (Map<IriTerm, ClassMapping>, ValidationResult) _parseClassMappings(
      RdfGraph graph, List<RdfSubject> classMappingRefs) {
    final ValidationResult validation = ValidationResult();
    final classMappings = <IriTerm, ClassMapping>{};
    final validations = <RdfSubject, ValidationResult>{};
    for (final ref in classMappingRefs) {
      final ValidationResult validation = ValidationResult();
      validations[ref] = validation;
      if (!graph.hasTriples(
          subject: ref, predicate: Rdf.type, object: McClassMapping.classIri)) {
        _log.warning('Skipping invalid class mapping reference: $ref');
        validation.addError('Cannot resolve class mapping reference',
            details: {'ref': ref});
        continue;
      }
      final classIri =
          graph.findSingleObject<IriTerm>(ref, McClassMapping.appliesToClass);
      if (classIri == null) {
        _log.warning('Class mapping missing appliesToClass: $ref');
        validation.addError('Class mapping missing appliesToClass',
            details: {'ref': ref});
        continue;
      }
      final predicateRuleRefs =
          graph.getMultiValueObjectList<RdfSubject>(ref, McClassMapping.rule);
      final parsedRules = predicateRuleRefs.map((r) => _parseRule(graph, r));
      final predicateMappings = {
        for (var rule in parsedRules.map((r) => r.$1).nonNulls)
          rule.predicateIri: rule
      };
      for (var v in parsedRules.map((r) => r.$2).where((v) => v.hasIssues)) {
        validation.addSubvalidationResult(v,
            context: switch (ref) {
              final IriTerm iri => '#${iri.fragment}',
              final BlankNodeTerm bnode => "Blank Node $bnode"
            },
            details: {'ref': ref});
      }
      if (classMappings.containsKey(classIri)) {
        _log.warning('Duplicate class mapping for $classIri, overwriting.');
        validation.addWarning('Duplicate class mapping for $classIri',
            details: {'ref': ref, 'classIri': classIri});
      }
      classMappings[classIri] = ClassMapping(classIri, predicateMappings);
    }
    for (var e in validations.entries.where((e) => e.value.hasIssues)) {
      validation.addSubvalidationResult(e.value,
          context: 'mc:classMapping', details: {'ref': e.key});
    }
    return (classMappings, validation);
  }

  (PredicateMapping?, ValidationResult) _parsePredicateMapping(
      RdfGraph graph, RdfSubject ref) {
    final ValidationResult validation = ValidationResult();
    final type = graph.findSingleObject(ref, Rdf.type);
    if (type != null && type != McPredicateMapping.classIri) {
      validation.addWarning(
          'Predicate mapping subject ${switch (ref) {
            final IriTerm iri => iri.value,
            final BlankNodeTerm bnode => "Blank Node $bnode"
          }} is not of type mc:PredicateMapping, but of type $type',
          details: {'ref': ref});
    }
    final predicateRuleRefs =
        graph.getMultiValueObjectList<RdfSubject>(ref, McPredicateMapping.rule);
    final parsedRules =
        predicateRuleRefs.map((r) => _parseRule(graph, r)).toList();
    final rules = {
      for (var rule in parsedRules.map((r) => r.$1).nonNulls)
        rule.predicateIri: rule
    };
    for (var v in parsedRules.map((r) => r.$2).where((v) => v.hasIssues)) {
      validation.addSubvalidationResult(v,
          context: 'In predicate mapping $ref', details: {'ref': ref});
    }
    return (PredicateMapping(rules), validation);
  }
}
