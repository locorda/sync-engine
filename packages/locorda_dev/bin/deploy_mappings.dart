import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:locorda_rdf_core/core.dart';

const _rdfTypeIri = 'http://www.w3.org/1999/02/22-rdf-syntax-ns#type';
const _documentMappingIri =
    'https://w3id.org/solid-crdt-sync/vocab/merge-contract#DocumentMapping';
const _defaultBootstrapPath = 'lib/src/generated/mapping_bootstrap.g.dart';
const _defaultTurtleContentType = 'text/turtle';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(
      'Usage: dart run locorda_dev:deploy_mappings <output-dir> [bootstrap-file]',
    );
    exitCode = 64;
    return;
  }

  final outputDir = args[0];
  final bootstrapPath = args.length > 1 ? args[1] : _defaultBootstrapPath;

  final rdfCore = RdfCore.withStandardCodecs();
  final bootstrapFile = File(bootstrapPath);

  if (!await bootstrapFile.exists()) {
    stderr.writeln('Bootstrap file not found: $bootstrapPath');
    exitCode = 1;
    return;
  }

  final source = await bootstrapFile.readAsString();
  final mappings = extractBootstrapMappings(source);
  final deployedCount = await deployMappings(
    rdfCore: rdfCore,
    mappings: mappings,
    outputDirectory: Directory(outputDir),
  );

  stdout.writeln('Deployed $deployedCount mappings to $outputDir');
}

List<String> extractBootstrapMappings(String dartCode) {
  final unit = parseString(content: dartCode).unit;

  for (final declaration in unit.declarations) {
    if (declaration is! TopLevelVariableDeclaration) {
      continue;
    }

    for (final variable in declaration.variables.variables) {
      if (variable.name.lexeme != 'bootstrapMappings') {
        continue;
      }

      final initializer = variable.initializer;
      if (initializer is! ListLiteral) {
        throw const FormatException(
          'bootstrapMappings exists but is not a List literal.',
        );
      }

      return initializer.elements
          .map(_stringLiteralValue)
          .whereType<String>()
          .toList();
    }
  }

  throw const FormatException('bootstrapMappings not found.');
}

Future<int> deployMappings({
  required RdfCore rdfCore,
  required List<String> mappings,
  required Directory outputDirectory,
}) async {
  await outputDirectory.create(recursive: true);
  var deployed = 0;
  final usedNames = <String, int>{};

  for (final mapping in mappings) {
    final dataset = rdfCore.decodeDataset(mapping);

    if (dataset.defaultGraph.isNotEmpty) {
      final documentIri = _extractDocumentIri(dataset.defaultGraph);
      if (documentIri != null) {
        final fileName = deriveMappingFileName(documentIri, usedNames);
        final output = rdfCore.encode(
          dataset.defaultGraph,
          contentType: _defaultTurtleContentType,
        );
        await File('${outputDirectory.path}/$fileName').writeAsString(output);
        stdout.writeln('✓ $fileName → ${documentIri.value}');
        deployed++;
      }
    }

    for (final namedGraph in dataset.namedGraphs) {
      final fallbackIri =
          namedGraph.name is IriTerm ? namedGraph.name as IriTerm : null;
      final documentIri = _extractDocumentIri(namedGraph.graph) ?? fallbackIri;
      if (documentIri == null) {
        continue;
      }

      final fileName = deriveMappingFileName(documentIri, usedNames);
      final output = rdfCore.encode(
        namedGraph.graph,
        contentType: _defaultTurtleContentType,
      );
      await File('${outputDirectory.path}/$fileName').writeAsString(output);
      stdout.writeln('✓ $fileName → ${documentIri.value}');
      deployed++;
    }
  }

  return deployed;
}

String deriveMappingFileName(IriTerm iri, Map<String, int> usedNames) {
  final uri = Uri.parse(iri.value);
  final fragmentless = uri.fragment.isEmpty ? uri : uri.replace(fragment: null);
  final segment =
      fragmentless.pathSegments.isEmpty ? '' : fragmentless.pathSegments.last;

  var baseName = segment.isEmpty ? 'mapping' : segment;
  if (!baseName.endsWith('.ttl')) {
    baseName = '$baseName.ttl';
  }

  final existing = usedNames[baseName];
  if (existing == null) {
    usedNames[baseName] = 1;
    return baseName;
  }

  final dotIndex = baseName.lastIndexOf('.');
  final name = dotIndex == -1 ? baseName : baseName.substring(0, dotIndex);
  final ext = dotIndex == -1 ? '' : baseName.substring(dotIndex);
  final uniqueName = '$name-${existing + 1}$ext';
  usedNames[baseName] = existing + 1;
  return uniqueName;
}

IriTerm? _extractDocumentIri(RdfGraph graph) {
  for (final triple in graph.triples) {
    final predicate = triple.predicate;
    final object = triple.object;
    final subject = triple.subject;

    if (predicate is IriTerm &&
        predicate.value == _rdfTypeIri &&
        object is IriTerm &&
        object.value == _documentMappingIri &&
        subject is IriTerm) {
      return subject;
    }
  }
  return null;
}

String? _stringLiteralValue(CollectionElement element) {
  final expression = switch (element) {
    Expression expression => expression,
    _ => null,
  };
  if (expression == null) {
    return null;
  }

  if (expression is SimpleStringLiteral) {
    return expression.value;
  }

  if (expression is AdjacentStrings) {
    final buffer = StringBuffer();
    for (final string in expression.strings) {
      if (string is! SimpleStringLiteral) {
        return null;
      }
      buffer.write(string.value);
    }
    return buffer.toString();
  }

  return null;
}
