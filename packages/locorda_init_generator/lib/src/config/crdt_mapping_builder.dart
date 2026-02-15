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

    final trigContent = await _generateTrigDataset(roots);
    await buildStep.writeAsString(buildStep.allowedOutputs.single, trigContent);
  }

  List<_RootResourceEntry> _scanRootResourcesInLibrary(LibraryElement library) {
    final roots = <_RootResourceEntry>[];

    for (final classElement in library.classes) {
      final rootAnnotation = _findAnnotationByType(
          classElement.metadata.annotations, 'LcrdRootResource');
      if (rootAnnotation == null) {
        continue;
      }

      final crdtObject = getField(rootAnnotation, 'crdt');
      if (crdtObject == null || crdtObject.isNull) {
        log.warning(
            'Skipping ${classElement.name}: @LcrdRootResource.crdt is missing.');
        continue;
      }

      final mappingIri = getField(crdtObject, 'mappingIri')?.toStringValue();
      if (mappingIri == null || mappingIri.isEmpty) {
        log.warning(
            'Skipping ${classElement.name}: crdt.mappingIri is missing.');
        continue;
      }

      final normalizedMappingIri = _validateAndNormalizeMappingIri(
        mappingIri,
        classElement.name ?? 'UnknownResource',
      );

      roots.add(
        _RootResourceEntry(
          classElement: classElement,
          crdt: _CrdtConfig(
            mappingIri: normalizedMappingIri,
            label: getField(crdtObject, 'label')?.toStringValue(),
            comment: getField(crdtObject, 'comment')?.toStringValue(),
            imports: _extractIriList(getField(crdtObject, 'imports')),
            generate: getField(crdtObject, 'generate')?.toBoolValue() ?? true,
          ),
        ),
      );
    }

    return roots;
  }

  Future<String> _generateTrigDataset(List<_RootResourceEntry> roots) async {
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
        final predicate = _extractPropertyPredicate(field);
        if (predicate == null) {
          continue;
        }

        final ruleNode = BlankNodeTerm();
        triples.add(Triple(classNode, McClassMapping.rule, ruleNode));
        triples.add(Triple(ruleNode, McRule.predicate, predicate));
        triples.add(
            Triple(ruleNode, McRule.algoMergeWith, _resolveAlgorithm(field)));

        if (_hasAnnotationByType(field.metadata.annotations, 'McIdentifying')) {
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
        if (_extractPropertyPredicate(field) == null) {
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

  IriTerm? _extractPropertyPredicate(FieldElement field) {
    for (final annotation in field.metadata.annotations) {
      final value = annotation.computeConstantValue();
      if (value == null) {
        continue;
      }
      if (!_matchesAnnotationInHierarchy(value.type, 'RdfProperty')) {
        continue;
      }
      return _readIri(getField(value, 'predicate'));
    }
    return null;
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
        classElement.metadata.annotations, 'LcrdRootResource');
    if (root != null) {
      return _readIri(getField(root, 'classIri'));
    }

    final sub = _findAnnotationByType(
        classElement.metadata.annotations, 'LcrdSubResource');
    if (sub != null) {
      return _readIri(getField(sub, 'classIri'));
    }

    final local = _findAnnotationByType(
        classElement.metadata.annotations, 'RdfLocalResource');
    if (local != null) {
      return _readIri(getField(local, 'classIri'));
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
      final predicate = _extractPropertyPredicate(field);
      if (predicate == null) {
        continue;
      }

      hasRules = true;
      final ruleNode = BlankNodeTerm();
      triples
          .add(Triple(predicateMappingNode, McPredicateMapping.rule, ruleNode));
      triples.add(Triple(ruleNode, McRule.predicate, predicate));
      triples.add(Triple(ruleNode, Algo.mergeWith, _resolveAlgorithm(field)));

      if (_hasAnnotationByType(field.metadata.annotations, 'McIdentifying')) {
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
              'RdfLocalResource',
            ) !=
            null &&
        _extractClassIri(classElement) == null;
  }

  bool _isTraversableResource(ClassElement classElement) {
    return _findAnnotationByType(
                classElement.metadata.annotations, 'LcrdSubResource') !=
            null ||
        _findAnnotationByType(
                classElement.metadata.annotations, 'RdfLocalResource') !=
            null ||
        _findAnnotationByType(
                classElement.metadata.annotations, 'LcrdRootResource') !=
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
  final String mappingIri;
  final String? label;
  final String? comment;
  final List<IriTerm> imports;
  final bool generate;

  const _CrdtConfig({
    required this.mappingIri,
    required this.label,
    required this.comment,
    required this.imports,
    required this.generate,
  });
}
