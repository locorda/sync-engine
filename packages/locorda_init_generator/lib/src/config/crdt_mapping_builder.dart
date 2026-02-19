library;

import 'dart:async';

import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:build/build.dart';
import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:locorda_rdf_terms_core/rdf.dart';
import 'package:locorda_rdf_terms_core/xsd.dart';

import '../code_generation/analyzer_utils.dart';

Builder crdtMappingBuilder(BuilderOptions options) => CrdtMappingBuilder();

String mappingFileNameFromIri(String mappingIri) {
  final uri = Uri.parse(mappingIri);
  final base = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
  if (base.isEmpty) {
    throw ArgumentError.value(
      mappingIri,
      'mappingIri',
      'must end with a file name segment like category-v1.ttl or category-v1#',
    );
  }

  if (base.endsWith('.ttl')) {
    return base;
  }

  if (mappingIri.endsWith('#')) {
    return '$base.ttl';
  }

  return base;
}

class CrdtMappingBuilder implements Builder {
  @override
  Map<String, List<String>> get buildExtensions => const {
        'lib/{{}}.dart': ['lib/{{}}.crdt.cache.trig'],
      };

  @override
  Future<void> build(BuildStep buildStep) async {
    if (buildStep.inputId.path.endsWith('.g.dart')) {
      return;
    }
    if (!await buildStep.resolver.isLibrary(buildStep.inputId)) {
      return;
    }

    final library = await buildStep.resolver.libraryFor(buildStep.inputId);
    final roots = _scanRootResourcesInLibrary(library)
        .where((entry) => entry.crdt.generate)
        .toList()
      ..sort((a, b) => a.crdt.mappingIri.compareTo(b.crdt.mappingIri));

    if (roots.isEmpty) {
      return;
    }
    final baseUris = roots
        .map((e) => e.crdt.appBaseUri)
        .whereType<String>()
        .toSet()
      ..removeWhere((uri) => uri.isEmpty);

    final trigContent = await _generateTrigDataset(
        roots, baseUris.length == 1 ? baseUris.first : null);
    await buildStep.writeAsString(buildStep.allowedOutputs.single, trigContent);
  }

  List<_RootResourceEntry> _scanRootResourcesInLibrary(LibraryElement library) {
    final roots = <_RootResourceEntry>[];

    for (final classElement in library.classes) {
      final rootAnnotation = _findAnnotationByType(
          classElement.metadata.annotations, 'RootResource');
      if (rootAnnotation == null) {
        continue;
      }

      final crdtConfig = _extractCrdtConfig(
        rootAnnotation,
        classElement.name ?? 'UnknownResource',
      );
      if (crdtConfig == null) {
        log.warning(
          'Skipping ${classElement.name}: merge contract configuration is missing.',
        );
        continue;
      }

      roots.add(
        _RootResourceEntry(
          classElement: classElement,
          crdt: crdtConfig,
        ),
      );
    }

    return roots;
  }

  Future<String> _generateTrigDataset(
      List<_RootResourceEntry> roots, String? baseUri) async {
    final namedGraphs = <RdfGraphName, RdfGraph>{};
    for (final root in roots) {
      final triples = await _buildTriplesForRoot(root);
      final documentIri = IriTerm(root.crdt.mappingIri);
      namedGraphs[documentIri] = RdfGraph.fromTriples(triples);
    }

    return trig.encode(
      RdfDataset(
        defaultGraph: RdfGraph(),
        namedGraphs: namedGraphs,
      ),
      baseUri: baseUri == null
          ? null
          : baseUri.endsWith('/')
              ? baseUri
              : '$baseUri/',
    );
  }

  Future<List<Triple>> _buildTriplesForRoot(_RootResourceEntry root) async {
    final triples = <Triple>[];
    final documentIri = IriTerm(root.crdt.mappingIri);

    triples.add(Triple(documentIri, Rdf.type, McDocumentMapping.classIri));

    if (root.crdt.label case final label?) {
      triples.add(
          Triple(documentIri, McDocumentMapping.rdfsLabel, LiteralTerm(label)));
    }
    if (root.crdt.comment case final comment?) {
      triples.add(Triple(
          documentIri, McDocumentMapping.rdfsComment, LiteralTerm(comment)));
    }

    _addRdfList(
        triples, documentIri, McDocumentMapping.imports, root.crdt.imports);

    final discoveredTypes = await _discoverReachableTypes(root.classElement);
    final classMappingNodes = <RdfObject>[];
    final predicateMappingNodes = <RdfObject>[];

    for (final classElement in discoveredTypes) {
      final classIri = _extractClassIri(classElement);
      if (classIri == null) {
        if (_isTypelessLocalResource(classElement)) {
          final predicateMappingNode =
              _createPredicateMappingForTypelessResource(
            classElement,
            triples,
          );
          if (predicateMappingNode != null) {
            predicateMappingNodes.add(predicateMappingNode);
          }
          continue;
        }

        log.warning(
          'Skipping mapping for ${classElement.name}: missing class IRI and not a typeless local resource.',
        );
        continue;
      }

      final classNode = BlankNodeTerm();
      classMappingNodes.add(classNode);
      triples.add(
          Triple(classNode, McClassMapping.rdfType, McClassMapping.classIri));
      triples.add(Triple(classNode, McClassMapping.appliesToClass, classIri));

      for (final field in classElement.fields) {
        final predicate = _extractPropertyPredicate(field, classElement);
        if (predicate == null) {
          continue;
        }

        final ruleNode = BlankNodeTerm();
        triples.add(Triple(classNode, McClassMapping.rule, ruleNode));
        triples.add(Triple(ruleNode, McRule.predicate, predicate));
        triples.add(
            Triple(ruleNode, McRule.algoMergeWith, _resolveAlgorithm(field)));

        if (_hasAnnotationByType(
            field.metadata.annotations, 'MergeIdentifying')) {
          triples.add(Triple(
            ruleNode,
            McRule.isIdentifying,
            LiteralTerm('true', datatype: Xsd.boolean),
          ));
        }
      }
    }

    _addRdfList(triples, documentIri, McDocumentMapping.classMapping,
        classMappingNodes);
    _addRdfList(
      triples,
      documentIri,
      McDocumentMapping.predicateMapping,
      predicateMappingNodes,
    );

    return triples;
  }

  Future<List<ClassElement>> _discoverReachableTypes(ClassElement root) async {
    final visited = <ClassElement>{};
    final queue = <ClassElement>[root];

    while (queue.isNotEmpty) {
      final current = queue.removeAt(0);
      if (!visited.add(current)) {
        continue;
      }

      for (final field in current.fields) {
        if (_extractPropertyPredicate(field, current) == null) {
          continue;
        }

        final candidate = _unwrapResourceType(field.type);
        if (candidate == null || !_isTraversableResource(candidate)) {
          continue;
        }

        if (!visited.contains(candidate)) {
          queue.add(candidate);
        }
      }
    }

    final sorted = visited.toList()
      ..sort((a, b) => (a.name ?? '').compareTo(b.name ?? ''));
    return sorted;
  }

  void _addRdfList(
    List<Triple> triples,
    RdfSubject subject,
    RdfPredicate predicate,
    List<RdfObject> items,
  ) {
    if (items.isEmpty) {
      triples.add(Triple(subject, predicate, Rdf.nil));
      return;
    }

    final blankNodes = List.generate(items.length, (_) => BlankNodeTerm());
    for (var index = 0; index < items.length; index++) {
      final current = blankNodes[index];
      final next = index < items.length - 1 ? blankNodes[index + 1] : Rdf.nil;
      triples.add(Triple(current, Rdf.first, items[index]));
      triples.add(Triple(current, Rdf.rest, next));
    }

    triples.add(Triple(subject, predicate, blankNodes.first));
  }

  IriTerm _resolveAlgorithm(FieldElement field) {
    if (_hasAnnotationByType(field.metadata.annotations, 'CrdtImmutable')) {
      return Algo.Immutable;
    }
    if (_hasAnnotationByType(field.metadata.annotations, 'CrdtOrSet')) {
      return Algo.OR_Set;
    }
    return Algo.LWW_Register;
  }

  IriTerm? _extractPropertyPredicate(
    FieldElement field,
    ClassElement classElement,
  ) {
    if (field.isSynthetic || field.isStatic) {
      return null;
    }

    for (final annotation in field.metadata.annotations) {
      final value = annotation.computeConstantValue();
      if (value == null) {
        continue;
      }
      if (!_matchesAnnotationInHierarchy(value.type, 'RdfProperty')) {
        continue;
      }

      final explicitPredicate = _readIri(getField(value, 'predicate'));
      if (explicitPredicate != null) {
        return explicitPredicate;
      }

      final fragment = getField(value, 'fragment')?.toStringValue();
      if (fragment != null && fragment.isNotEmpty) {
        final vocabBaseIri = _resolveVocabBaseIri(classElement);
        if (vocabBaseIri != null) {
          return IriTerm('$vocabBaseIri$fragment');
        }
      }

      return null;
    }

    if (_hasAnnotationByType(field.metadata.annotations, 'RdfIgnore') ||
        _hasAnnotationByType(
            field.metadata.annotations, 'RdfUnmappedTriples')) {
      return null;
    }

    final vocabBaseIri = _resolveVocabBaseIri(classElement);
    if (vocabBaseIri == null) {
      return null;
    }

    final fieldName = field.name;
    if (fieldName == null) {
      return null;
    }

    final wellKnownProperty =
        _resolveWellKnownProperty(classElement, fieldName);
    if (wellKnownProperty != null) {
      return wellKnownProperty;
    }

    return IriTerm('$vocabBaseIri$fieldName');
  }

  String _validateAndNormalizeMappingIri(
    String mappingIri,
    String className,
  ) {
    final uri = Uri.parse(mappingIri);

    // Ensure base URI (without fragment) is absolute
    final baseUri = uri.hasFragment ? uri.removeFragment() : uri;
    if (!baseUri.isAbsolute) {
      throw ArgumentError.value(
        mappingIri,
        'mappingIri',
        'CRDT mapping IRI for $className must be absolute.',
      );
    }

    try {
      IriTerm.validated(mappingIri);
    } catch (e) {
      throw ArgumentError.value(
        mappingIri,
        'mappingIri',
        'CRDT mapping IRI for $className is invalid: $e',
      );
    }

    // Return IRI as-is without modifications. Consistency throughout the system
    // depends on using the exact IRI provided in the annotation.
    return mappingIri;
  }

  IriTerm? _extractClassIri(ClassElement classElement) {
    final root = _findAnnotationByType(
        classElement.metadata.annotations, 'RootResource');
    if (root != null) {
      return _resolveClassIri(root, classElement);
    }

    final sub =
        _findAnnotationByType(classElement.metadata.annotations, 'SubResource');
    if (sub != null) {
      return _resolveClassIri(sub, classElement);
    }

    final local = _findAnnotationByType(
        classElement.metadata.annotations, 'LocalResource');
    if (local != null) {
      return _resolveClassIri(local, classElement);
    }

    return null;
  }

  BlankNodeTerm? _createPredicateMappingForTypelessResource(
    ClassElement classElement,
    List<Triple> triples,
  ) {
    final predicateMappingNode = BlankNodeTerm();
    var hasRules = false;

    for (final field in classElement.fields) {
      final predicate = _extractPropertyPredicate(field, classElement);
      if (predicate == null) {
        continue;
      }

      hasRules = true;
      final ruleNode = BlankNodeTerm();
      triples
          .add(Triple(predicateMappingNode, McPredicateMapping.rule, ruleNode));
      triples.add(Triple(ruleNode, McRule.predicate, predicate));
      triples.add(Triple(ruleNode, Algo.mergeWith, _resolveAlgorithm(field)));

      if (_hasAnnotationByType(
          field.metadata.annotations, 'MergeIdentifying')) {
        triples.add(Triple(
          ruleNode,
          McRule.isIdentifying,
          LiteralTerm('true', datatype: Xsd.boolean),
        ));
      }
    }

    if (!hasRules) {
      return null;
    }

    triples.add(
      Triple(predicateMappingNode, Rdf.type, McPredicateMapping.classIri),
    );
    return predicateMappingNode;
  }

  bool _isTypelessLocalResource(ClassElement classElement) {
    return _findAnnotationByType(
              classElement.metadata.annotations,
              'LocalResource',
            ) !=
            null &&
        _extractClassIri(classElement) == null;
  }

  bool _isTraversableResource(ClassElement classElement) {
    return _findAnnotationByType(
                classElement.metadata.annotations, 'SubResource') !=
            null ||
        _findAnnotationByType(
                classElement.metadata.annotations, 'LocalResource') !=
            null ||
        _findAnnotationByType(
                classElement.metadata.annotations, 'RootResource') !=
            null;
  }

  ClassElement? _unwrapResourceType(DartType type) {
    var current = type;
    if (current is InterfaceType && current.typeArguments.isNotEmpty) {
      final containerName = current.element.name;
      if (containerName == 'List' ||
          containerName == 'Set' ||
          containerName == 'Iterable') {
        current = current.typeArguments.first;
      }
    }

    if (current is! InterfaceType) {
      return null;
    }

    return current.element as ClassElement?;
  }

  List<IriTerm> _extractIriList(DartObject? value) {
    final objects = value?.toListValue();
    if (objects == null || objects.isEmpty) {
      return const [];
    }

    final entries = <IriTerm>[];
    for (final object in objects) {
      final iri = _readIri(object);
      if (iri != null) {
        entries.add(iri);
      }
    }
    return entries;
  }

  IriTerm? _readIri(DartObject? value) {
    if (value == null || value.isNull) {
      return null;
    }

    final iriTermObject = getField(value, 'iriTerm');
    if (iriTermObject != null && !iriTermObject.isNull) {
      final nested = _readIri(iriTermObject);
      if (nested != null) {
        return nested;
      }
    }

    final directString = value.toStringValue();
    if (directString != null) {
      return IriTerm(directString);
    }

    final valueString = getField(value, 'value')?.toStringValue();
    if (valueString != null) {
      return IriTerm(valueString);
    }

    final iriValueAlt = getField(value, '_value')?.toStringValue();
    if (iriValueAlt != null) {
      return IriTerm(iriValueAlt);
    }

    final iriValue = getField(value, 'iri')?.toStringValue();
    if (iriValue != null) {
      return IriTerm(iriValue);
    }

    return null;
  }

  _CrdtConfig? _extractCrdtConfig(DartObject rootAnnotation, String className) {
    final explicitContract =
        getField(rootAnnotation, 'explicitContractIri')?.toStringValue();
    if (explicitContract != null && explicitContract.isNotEmpty) {
      final contractField = getField(rootAnnotation, 'contract');
      return _CrdtConfig(
        mappingIri:
            _validateAndNormalizeMappingIri(explicitContract, className),
        label: contractField?.getField('label')?.toStringValue(),
        comment: contractField?.getField('comment')?.toStringValue(),
        imports: _extractIriList(contractField?.getField('imports')),
        generate: getField(rootAnnotation, 'generateContract')?.toBoolValue() ??
            false,
      );
    }

    final appBaseUri =
        (getField(rootAnnotation, 'contractAppBaseUri'))?.toStringValue() ??
            (getField(rootAnnotation, 'generatorVocab'))
                ?.getField('appBaseUri')
                ?.toStringValue();
    if (appBaseUri != null && appBaseUri.isNotEmpty) {
      final contractField = getField(rootAnnotation, 'contract');
      final mappingIri = _resolveGeneratedContractIri(
        appBaseUri,
        className,
        contractField?.getField('path')?.toStringValue(),
        contractField?.getField('version')?.toStringValue() ?? 'v1',
      );
      return _CrdtConfig(
        appBaseUri: appBaseUri,
        mappingIri: _validateAndNormalizeMappingIri(mappingIri, className),
        label: contractField?.getField('label')?.toStringValue(),
        comment: contractField?.getField('comment')?.toStringValue(),
        imports: _extractIriList(contractField?.getField('imports')),
        generate:
            getField(rootAnnotation, 'generateContract')?.toBoolValue() ?? true,
      );
    }

    final contractObject = getField(rootAnnotation, 'contract');
    if (contractObject == null || contractObject.isNull) {
      return null;
    }

    final mappingIri = getField(contractObject, 'mappingIri')?.toStringValue();
    if (mappingIri == null || mappingIri.isEmpty) {
      return null;
    }

    return _CrdtConfig(
      mappingIri: _validateAndNormalizeMappingIri(mappingIri, className),
      label: getField(contractObject, 'label')?.toStringValue(),
      comment: getField(contractObject, 'comment')?.toStringValue(),
      imports: _extractIriList(getField(contractObject, 'imports')),
      generate: getField(contractObject, 'generate')?.toBoolValue() ?? true,
    );
  }

  String _resolveGeneratedContractIri(
    String contractAppBaseUri,
    String className,
    String? contractPath,
    String contractVersion,
  ) {
    final normalizedClassName = className.toLowerCase();
    final path =
        contractPath ?? '/mappings/$normalizedClassName-$contractVersion';
    return '${_joinBaseAndPath(contractAppBaseUri, path)}#';
  }

  IriTerm? _resolveClassIri(
    DartObject annotation,
    ClassElement classElement,
  ) {
    final explicitClassIri = _readIri(
      getField(annotation, 'explicitClassIri'),
    );
    if (explicitClassIri != null) {
      return explicitClassIri;
    }

    final classIri = _readIri(getField(annotation, 'classIri'));
    if (classIri != null) {
      return classIri;
    }

    final vocabBaseIri = _resolveVocabBaseIri(classElement);
    if (vocabBaseIri != null) {
      return IriTerm('$vocabBaseIri${classElement.name}');
    }

    return null;
  }

  IriTerm? _resolveWellKnownProperty(
    ClassElement classElement,
    String fieldName,
  ) {
    final vocabObject = _resolveVocabObject(classElement);
    if (vocabObject == null) {
      return null;
    }

    final wellKnownProperties = getField(vocabObject, 'wellKnownProperties');
    final entries = wellKnownProperties?.toMapValue();
    if (entries == null || entries.isEmpty) {
      return null;
    }

    for (final entry in entries.entries) {
      final key = entry.key?.toStringValue();
      if (key == fieldName) {
        return _readIri(entry.value);
      }
    }

    return null;
  }

  String? _resolveVocabBaseIri(ClassElement classElement) {
    final vocabObject = _resolveVocabObject(classElement);
    if (vocabObject == null) {
      return null;
    }

    final appBaseUri = getField(vocabObject, 'appBaseUri')?.toStringValue();
    if (appBaseUri == null || appBaseUri.isEmpty) {
      return null;
    }

    final vocabPath =
        getField(vocabObject, 'vocabPath')?.toStringValue() ?? '/vocab';
    return '${_joinBaseAndPath(appBaseUri, vocabPath)}#';
  }

  String _joinBaseAndPath(String baseUri, String path) {
    final normalizedBase = _normalizeBaseUri(baseUri);
    final normalizedPath = _normalizePath(path);
    return '$normalizedBase$normalizedPath';
  }

  String _normalizeBaseUri(String baseUri) {
    if (baseUri.length > 1 && baseUri.endsWith('/')) {
      return baseUri.substring(0, baseUri.length - 1);
    }
    return baseUri;
  }

  String _normalizePath(String path) {
    if (path.isEmpty) {
      return '';
    }
    return path.startsWith('/') ? path : '/$path';
  }

  DartObject? _resolveVocabObject(ClassElement classElement) {
    final resourceAnnotation = _findResourceAnnotation(classElement);
    if (resourceAnnotation == null) {
      return null;
    }

    final localVocab = getField(resourceAnnotation, 'generatorVocab') ??
        getField(resourceAnnotation, '_vocab');
    if (localVocab != null && !localVocab.isNull) {
      return localVocab;
    }

    final inheritedVocab = getField(resourceAnnotation, 'vocab');
    if (inheritedVocab != null && !inheritedVocab.isNull) {
      return inheritedVocab;
    }

    return null;
  }

  DartObject? _findResourceAnnotation(ClassElement classElement) {
    final root = _findAnnotationByType(
        classElement.metadata.annotations, 'RootResource');
    if (root != null) {
      return root;
    }

    final sub =
        _findAnnotationByType(classElement.metadata.annotations, 'SubResource');
    if (sub != null) {
      return sub;
    }

    return _findAnnotationByType(
        classElement.metadata.annotations, 'LocalResource');
  }

  DartObject? _findAnnotationByType(
      Iterable<ElementAnnotation> annotations, String typeName) {
    for (final annotation in annotations) {
      final value = annotation.computeConstantValue();
      if (value == null) {
        continue;
      }
      if (value.type?.element?.name == typeName) {
        return value;
      }
    }
    return null;
  }

  bool _hasAnnotationByType(
      Iterable<ElementAnnotation> annotations, String typeName) {
    return _findAnnotationByType(annotations, typeName) != null;
  }

  bool _matchesAnnotationInHierarchy(DartType? type, String targetTypeName) {
    if (type == null) {
      return false;
    }
    final visited = <String>{};
    return _checkTypeHierarchy(type, targetTypeName, visited);
  }

  bool _checkTypeHierarchy(
      DartType type, String targetTypeName, Set<String> visited) {
    final currentName = type.element?.name;
    if (currentName == null || !visited.add(currentName)) {
      return false;
    }
    if (currentName == targetTypeName) {
      return true;
    }
    if (type is InterfaceType) {
      for (final superType in type.allSupertypes) {
        if (_checkTypeHierarchy(superType, targetTypeName, visited)) {
          return true;
        }
      }
    }
    return false;
  }
}

class _RootResourceEntry {
  final ClassElement classElement;
  final _CrdtConfig crdt;

  const _RootResourceEntry({
    required this.classElement,
    required this.crdt,
  });
}

class _CrdtConfig {
  final String? appBaseUri;
  final String mappingIri;
  final String? label;
  final String? comment;
  final List<IriTerm> imports;
  final bool generate;

  const _CrdtConfig({
    this.appBaseUri,
    required this.mappingIri,
    required this.label,
    required this.comment,
    required this.imports,
    required this.generate,
  });
}
