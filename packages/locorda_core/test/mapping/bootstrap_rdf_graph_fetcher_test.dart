import 'package:locorda_core/src/mapping/recursive_rdf_loader.dart';
import 'package:locorda_core/src/vocab/generated/rdf.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:test/test.dart';

void main() {
  test('uses bootstrap content when online fetch fails', () async {
    final rdfCore = RdfCore.withStandardCodecs();
    final iriFactory = IriTerm.validated;
    final documentIri = IriTerm.validated('https://example.com/mapping');
    final bootstrapContent = '''@base <https://example.com/mapping#> .
@prefix ex: <https://example.com/> .

<> a <https://w3id.org/solid-crdt-sync/vocab/merge-contract#DocumentMapping> .
''';

    final fetcher = BootstrapRdfGraphFetcher(
      rdfCore: rdfCore,
      iriFactory: iriFactory,
      bootstrapSources: [bootstrapContent],
    );

    final graph = await fetcher.fetch(documentIri);
    final triples = graph.findTriples(
      predicate: Rdf.type,
      object: IriTerm.validated(
          'https://w3id.org/solid-crdt-sync/vocab/merge-contract#DocumentMapping'),
    );
    expect(triples, isNotEmpty);
  });
}
