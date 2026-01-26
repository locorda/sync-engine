import 'dart:io';

import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_core/src/vocab/generated/_index.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_rdf_canonicalization/canonicalization.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:test/test.dart';

/// Writes an RDF graph to a file in Turtle format.
/// Creates parent directories if they don't exist.
Future<void> writeGraphToFile(
    Directory testAssetsDir, String path, RdfGraph graph) async {
  final file = File('${testAssetsDir.path}/$path');
  await file.parent.create(recursive: true);
  var turtleContent = turtle.encode(graph);
  if (!turtleContent.endsWith('\n')) {
    turtleContent += "\n";
  }
  await file.writeAsString(turtleContent);
}

/// Reads an RDF graph from a Turtle file.
///
/// Throws if the file does not exist.
RdfGraph readGraphFromFile(Directory testAssetsDir, String relativePath) {
  try {
    final file = File('${testAssetsDir.path}/$relativePath');
    if (!file.existsSync()) {
      throw TestFailure(
        'Expected RDF file not found: ${file.path}\n'
        'This test requires the file to exist. If this is a generate test, '
        'ensure the expected output file has been created.',
      );
    }
    final content = file.readAsStringSync();
    return turtle.decode(content);
  } on TestFailure {
    rethrow; // Rethrow test failures as-is
  } catch (e) {
    throw TestFailure(
      'Failed to read RDF file: $relativePath\nError: $e',
    );
  }
}

/// Compares two RDF graphs using RDF canonicalization.
///
/// If the graphs differ, prints both in Turtle format for easier debugging.
void expectEqualGraphs(String name, RdfGraph actual, RdfGraph expected) {
  final actualCanonical = canonicalizeGraph(actual);
  final expectedCanonical = canonicalizeGraph(expected);

  if (actualCanonical != expectedCanonical) {
    // To make "fixing" the test by copying actual to
    // the expected file easier, print the actual graph in Turtle
    final actualTurtle = turtle.encode(actual);
    final expectedTurtle = turtle.encode(expected);
    print('-' * 4 + name + ' - Graphs differ ' + '-' * 4);
    print(actualTurtle);
    print('-' * 40);

    // First try string comparison for better diff output
    expect(actualTurtle, equals(expectedTurtle),
        reason: 'RDF graphs differ (Turtle comparison)');

    // This should have failed by now, but just in case:
    expect(actualCanonical, equals(expectedCanonical),
        reason: 'RDF graphs differ (canonical comparison)');
  }
}

ResourceIdentifier extractTypeIdFromStoredPath(
    Directory testAssetsDir, String path) {
  final graph = readGraphFromFile(testAssetsDir, path);
  final documentIris = graph.subjects
      .whereType<IriTerm>()
      .map((s) => s.getDocumentIri())
      .toSet();
  if (documentIris.length != 1) {
    throw TestFailure(
      'Expected exactly one document IRI in the graph at $path, '
      'but found ${documentIris.length}: \n\t${documentIris.join("\n\t")}.',
    );
  }
  final documentIri = documentIris.single;
  final primaryTopic = graph.expectSingleObject<IriTerm>(
      documentIri, SyncManagedDocument.foafPrimaryTopic)!;
  final typeIris = graph.getMultiValueObjects<IriTerm>(primaryTopic, Rdf.type);
  LocalResourceLocator locator =
      LocalResourceLocator(iriTermFactory: IriTerm.validated);
  return locator.fromIri(documentIri, expectedTypeIri: typeIris.single);
}
