/// CLI tool for deploying CRDT mapping documents to a server directory.
///
/// This tool extracts CRDT mapping documents from the generated bootstrap file
/// and splits them into individual Turtle (.ttl) files ready for server deployment.
///
/// ## Purpose
///
/// During development, CRDT mappings are embedded in the app as a `List<String>`
/// constant for offline-first bootstrap. For production deployment, these same
/// mappings must be published to their canonical URIs so that:
/// - Other apps can discover and use your CRDT mappings
/// - Cross-app collaboration works with shared merge strategies
/// - Mapping documents are accessible via HTTP for validation and debugging
///
/// ## When to Use
///
/// Run this tool as part of your deployment pipeline:
/// 1. After `dart run build_runner build` completes
/// 2. Before deploying your app to production
/// 3. Whenever CRDT mappings change (detected via git diff on generated files)
///
/// ## Usage
///
/// ```bash
/// # Deploy to local directory
/// dart run locorda_dev:deploy_mappings output/mappings/
///
/// # Specify custom bootstrap file
/// dart run locorda_dev:deploy_mappings output/mappings/ lib/custom_bootstrap.g.dart
///
/// # Common workflow: deploy then upload to CDN
/// dart run locorda_dev:deploy_mappings dist/mappings/
/// aws s3 sync dist/mappings/ s3://myapp.example.com/mappings/ --acl public-read
/// ```
///
/// ## Output
///
/// Creates individual Turtle files named after mapping document IRIs:
/// - `note-v1.ttl` from `https://myapp.example.com/mappings/note-v1#`
/// - `category-v1.ttl` from `https://myapp.example.com/mappings/category-v1#`
/// - `core-v1.ttl` from framework mappings (if included in bootstrap)
///
/// Files are deterministically named from IRI path segments. Each mapping IRI
/// must produce a unique filename - if two IRIs would produce the same filename,
/// deployment fails with an error (enforcing the IRI→URL principle).
///
/// ## Process
///
/// 1. **Extract**: Parse `bootstrapMappings` list from Dart source using AST
/// 2. **Decode**: Auto-detect format (Turtle/TriG/JSON-LD) and decode to RDF
/// 3. **Split**: Extract named graphs from TriG datasets as separate documents
/// 4. **Identify**: Find Document IRI from `mc:DocumentMapping` subject
/// 5. **Write**: Encode as clean Turtle and write to output directory
///
/// ## See Also
///
/// - Concept doc: `proposed-changes/020-crdt-mapping-generation.md`
/// - Bootstrap generator: `locorda_mapping_bootstrap_generator`
/// - CRDT mapping builder: `locorda_init_generator/crdt_mapping_builder.dart`
library;

import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:locorda_rdf_core/core.dart';

const _rdfTypeIri = 'http://www.w3.org/1999/02/22-rdf-syntax-ns#type';
const _documentMappingIri =
    'https://w3id.org/solid-crdt-sync/vocab/merge-contract#DocumentMapping';
const _defaultBootstrapPath = 'lib/src/generated/mapping_bootstrap.g.dart';
const _defaultTurtleContentType = 'text/turtle';

/// Entry point for the CRDT mapping deployment tool.
///
/// Extracts mapping documents from bootstrap file and deploys them as
/// individual Turtle files to the specified output directory.
///
/// **Arguments:**
/// - `args[0]`: Output directory path (required)
/// - `args[1]`: Bootstrap file path (optional, defaults to standard location)
///
/// **Exit codes:**
/// - `0`: Success
/// - `1`: Bootstrap file not found
/// - `64`: Invalid arguments (no output directory specified)
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

/// Extracts the `bootstrapMappings` list from generated Dart source code.
///
/// Uses the Dart analyzer to parse the source as an AST and extract string
/// literals from the `const List<String> bootstrapMappings` declaration.
/// Supports both simple string literals and adjacent string concatenation.
///
/// **Parameters:**
/// - [dartCode]: Complete Dart source code containing bootstrapMappings declaration
///
/// **Returns:** List of RDF document strings (Turtle, TriG, or JSON-LD format)
///
/// **Throws:**
/// - [FormatException] if bootstrapMappings is not found or not a List literal
///
/// **Example:**
/// ```dart
/// final source = await File('lib/src/generated/mapping_bootstrap.g.dart').readAsString();
/// final mappings = extractBootstrapMappings(source);
/// print('Found ${mappings.length} mapping documents');
/// ```
List<String> extractBootstrapMappings(String dartCode) {
  final unit = parseString(content: dartCode).unit;

  for (final declaration in unit.declarations) {
    if (declaration is! TopLevelVariableDeclaration) {
      continue;
    }

    for (final variable in declaration.variables.variables) {
      if (variable.name.lexeme != 'bootstrapMappings') {
        /// Deploys CRDT mapping documents to individual Turtle files.
        ///
        /// Processes each mapping document string:
        /// 1. Decodes RDF using auto-detected format (Turtle/TriG/JSON-LD)
        /// 2. Extracts default graph and named graphs from datasets
        /// 3. Identifies Document IRI from `mc:DocumentMapping` subject
        /// 4. Derives filename from IRI (e.g., `note-v1.ttl`)
        /// 5. Encodes as clean Turtle and writes to output directory
        ///
        /// Fails with clear error if filename collision detected, as this indicates
        /// an IRI design problem that must be fixed by the user.
        ///
        /// **Parameters:**
        /// - [rdfCore]: Configured RDF codec instance for encoding/decoding
        /// - [mappings]: List of RDF document strings from bootstrapMappings
        /// - [outputDirectory]: Target directory for deployed .ttl files
        ///
        /// **Returns:** Number of successfully deployed mapping files
        ///
        /// **Side effects:**
        /// - Creates output directory if it doesn't exist
        /// - Writes .ttl files to output directory
        /// - Prints progress to stdout for each deployed file
        ///
        /// **Example output:**
        /// ```
        /// ✓ note-v1.ttl → https://myapp.example.com/mappings/note-v1#
        /// ✓ category-v1.ttl → https://myapp.example.com/mappings/category-v1#
        /// ✓ core-v1.ttl → https://w3id.org/solid-crdt-sync/mappings/core-v1
        /// ```
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
  final usedNames = <String, String>{};

  for (final mapping in mappings) {
    final dataset = rdfCore.decodeDataset(mapping);

    if (dataset.defaultGraph.isNotEmpty) {
      final documentIri = _extractDocumentIri(dataset.defaultGraph);
      if (documentIri != null) {
        final fileName = _requireUniqueMappingFileName(documentIri, usedNames);
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

      final fileName = _requireUniqueMappingFileName(documentIri, usedNames);
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

/// Derives a filename from a mapping document IRI and enforces uniqueness.
///
/// Extracts the last path segment from the IRI and ensures it ends with `.ttl`.
/// Throws [StateError] if a filename collision is detected, as this indicates
/// an IRI design problem where multiple mappings would produce the same filename.
///
/// Each mapping IRI must produce a unique filename. If you encounter this error,
/// fix the mapping IRIs to ensure uniqueness (e.g., different path segments or
/// fragments).
///
/// **Parameters:**
/// - [iri]: Document IRI (typically ends with `#` or `.ttl`)
/// - [usedNames]: Mutable map tracking filename→IRI assignments for collision detection
///
/// **Returns:** Unique filename suitable for filesystem use
///
/// **Throws:** [StateError] if filename already used by different IRI
///
/// **Examples:**
/// ```dart
/// final used = <String, String>{};
/// _requireUniqueMappingFileName(IriTerm('https://example.com/mappings/note-v1#'), used);
/// // Returns: 'note-v1.ttl'
///
/// _requireUniqueMappingFileName(IriTerm('https://example.com/mappings/note-v1.ttl'), used);
/// // Returns: 'note-v1.ttl' (already has .ttl)
///
/// _requireUniqueMappingFileName(IriTerm('https://example.com/mappings/note-v1#other'), used);
/// // Throws: StateError (collision detected)
/// ```
String _requireUniqueMappingFileName(
    IriTerm iri, Map<String, String> usedNames) {
  final uri = Uri.parse(iri.value);
  final fragmentless = uri.fragment.isEmpty ? uri : uri.replace(fragment: null);
  final segment =
      fragmentless.pathSegments.isEmpty ? '' : fragmentless.pathSegments.last;

  var fileName = segment.isEmpty ? 'mapping' : segment;
  if (!fileName.endsWith('.ttl')) {
    fileName = '$fileName.ttl';
  }

  final existingIri = usedNames[fileName];
  if (existingIri != null && existingIri != iri.value) {
    throw StateError(
        'Filename collision detected: "$fileName" is already used by:\n'
        '  $existingIri\n'
        'Cannot deploy:\n'
        '  ${iri.value}\n\n'
        'Each mapping IRI must produce a unique filename. Fix the IRIs to ensure uniqueness.');
  }

  usedNames[fileName] = iri.value;
  return fileName;
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
