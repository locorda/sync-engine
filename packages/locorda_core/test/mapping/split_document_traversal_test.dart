import 'package:locorda_core/src/crdt/crdt_types.dart';
import 'package:locorda_core/src/generated/mapping_bootstrap.g.dart';
import 'package:locorda_core/src/mapping/merge_contract.dart';
import 'package:locorda_core/src/mapping/merge_contract_loader.dart';
import 'package:locorda_core/src/mapping/recursive_rdf_loader.dart';
import 'package:locorda_core/src/split_document.dart';
import 'package:locorda_core/src/vocab/generated/_index.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:test/test.dart';

/// Tests for [splitDocument] traversal boundary enforcement.
///
/// Verifies that [splitDocument] correctly separates framework metadata from
/// app-resource data: triples whose subjects belong to the app resource must
/// never bleed into the framework graph, regardless of the traversal paths
/// (`rdf:subject`, `foaf:primaryTopic`, etc.) that link framework nodes to
/// the app resource IRI.
void main() {
  group(
      'splitDocument – stopTraversal boundaries (core-v1 loaded via bootstrapMappings)',
      () {
    late MergeContract coreV1Contract;

    setUpAll(() async {
      final rdfCore = RdfCore.withStandardCodecs();

      // Use the generated bootstrapMappings directly — these are the TTL sources
      // compiled into the binary. Testing against this layer ensures that
      // mapping_bootstrap.g.dart stays in sync with spec/mappings/core-v1.ttl.
      final fetcher = BootstrapRdfGraphFetcher(
        rdfCore: rdfCore,
        iriFactory: IriTerm.validated,
        bootstrapSources: bootstrapMappings,
      );
      final loader =
          RecursiveRdfLoader(fetcher: fetcher, iriFactory: IriTerm.validated);
      final contractLoader = StandardMergeContractLoader(
        loader,
        CrdtTypeRegistry.forStandardTypes(),
      );
      coreV1Contract = await contractLoader.load([
        IriTerm.validated('https://w3id.org/solid-crdt-sync/mappings/core-v1'),
      ]);
    });

    // --- helpers ---

    /// Builds a minimal managed document that mirrors the real-world bug scenario:
    ///
    /// * No `rdf:type rdf:Statement` triple on the statement node (as in production).
    /// * [appIri] appears as the value of [Rdf.subject] inside the statement, and
    ///   as the value of [Foaf.primaryTopic] on the document root.
    /// * Three "app data" triples hang off [appIri].
    RdfGraph _buildTestDocument(
        IriTerm documentIri, IriTerm stmtIri, IriTerm appIri) {
      final appClass = IriTerm('https://example.com/App#Thing');
      final appProp = IriTerm('https://example.com/App#name');

      return RdfGraph(triples: [
        // Framework: document root
        Triple(documentIri, Rdf.type, Sync.ManagedDocument),
        Triple(documentIri, Foaf.primaryTopic, appIri),
        Triple(documentIri, Sync.hasStatement, stmtIri),
        // Framework: reified statement — no rdf:type so type must be inferred
        Triple(stmtIri, Rdf.subject, appIri),
        Triple(stmtIri, Rdf.predicate, appProp),
        Triple(stmtIri, Rdf.object, LiteralTerm.string('deleted-value')),
        Triple(
          stmtIri,
          Crdt.deletedAt,
          LiteralTerm('2024-01-01T00:00:00Z',
              datatype: IriTerm('http://www.w3.org/2001/XMLSchema#dateTime')),
        ),
        // App data — must NOT bleed into the framework graph
        Triple(appIri, Rdf.type, appClass),
        Triple(appIri, appProp, LiteralTerm.string('My Note')),
        Triple(appIri, appProp, LiteralTerm.string('duplicate-value')),
      ]);
    }

    test(
        'rdf:subject on inferred rdf:Statement stops traversal into app resource',
        () {
      final documentIri = IriTerm.validated('https://example.com/doc');
      final stmtIri = IriTerm.validated('https://example.com/doc#stmt-1');
      final appIri = IriTerm.validated('https://example.com/doc#note');

      final document = _buildTestDocument(documentIri, stmtIri, appIri);
      final (:frameworkGraph, :appGraph) =
          splitDocument(document, documentIri, coreV1Contract);

      // App-resource triples must not appear in the framework graph …
      expect(
        frameworkGraph.subjects,
        isNot(contains(appIri)),
        reason:
            'App resource $appIri must not appear as a subject in frameworkGraph; '
            'core-v1 stopTraversal rule for rdf:subject must be loaded and applied',
      );
      // … and must be fully preserved in the app graph.
      expect(
        appGraph.subjects,
        contains(appIri),
        reason: 'App resource $appIri must appear in appGraph',
      );
    });

    test(
        'foaf:primaryTopic on sync:ManagedDocument stops traversal into app resource',
        () {
      // Second traversal path: documentIri → foaf:primaryTopic → appIri.
      // core-v1 declares stopTraversal: true for foaf:primaryTopic globally;
      // this test ensures that declaration is actually loaded and honoured.
      final documentIri = IriTerm.validated('https://example.com/doc2');
      final stmtIri = IriTerm.validated('https://example.com/doc2#stmt-1');
      final appIri = IriTerm.validated('https://example.com/doc2#note');

      final document = _buildTestDocument(documentIri, stmtIri, appIri);
      final (:frameworkGraph, :appGraph) =
          splitDocument(document, documentIri, coreV1Contract);

      // foaf:primaryTopic edge must be in the framework graph …
      expect(
        frameworkGraph.findTriples(
          subject: documentIri,
          predicate: Foaf.primaryTopic,
        ),
        isNotEmpty,
        reason: 'foaf:primaryTopic edge must be preserved in frameworkGraph',
      );
      // … but the app resource itself must not leak in.
      expect(
        frameworkGraph.subjects,
        isNot(contains(appIri)),
        reason:
            'App resource $appIri must not appear in frameworkGraph via foaf:primaryTopic; '
            'core-v1 stopTraversal rule for foaf:primaryTopic must be loaded and applied',
      );
    });

    test('framework graph contains expected framework triples', () {
      final documentIri = IriTerm.validated('https://example.com/doc3');
      final stmtIri = IriTerm.validated('https://example.com/doc3#stmt-1');
      final appIri = IriTerm.validated('https://example.com/doc3#note');

      final document = _buildTestDocument(documentIri, stmtIri, appIri);
      final (:frameworkGraph, :appGraph) =
          splitDocument(document, documentIri, coreV1Contract);

      // Document root and statement metadata belong to the framework side.
      expect(frameworkGraph.subjects, contains(documentIri));
      expect(frameworkGraph.subjects, contains(stmtIri));

      // The app graph must contain the app data.
      expect(appGraph.subjects, contains(appIri));
      expect(appGraph.findTriples(subject: appIri), isNotEmpty);

      // No framework subjects must appear in the app graph.
      expect(appGraph.subjects, isNot(contains(documentIri)));
      expect(appGraph.subjects, isNot(contains(stmtIri)));
    });
  });
}
