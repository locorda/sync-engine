import 'package:locorda_core/src/crdt/crdt_types.dart';
import 'package:locorda_core/src/mapping/merge_contract_loader.dart';
import 'package:locorda_core/src/mapping/recursive_rdf_loader.dart';
import 'package:locorda_core/src/split_document.dart';
import 'package:locorda_core/src/vocab/generated/_index.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:test/test.dart';

/// Regression tests for the import-chain IRI resolution bug in
/// [RecursiveRdfLoader] / [StandardMergeContractLoader].
///
/// ## Bug description
///
/// When a document mapping uses an *explicit* fragment IRI as its subject —
/// e.g. `<mappings/note-v1#> a mc:DocumentMapping` rather than `<>` — the
/// subject IRI contains a trailing `#` fragment (e.g. `…/note-v1#`).
///
/// `RecursiveRdfLoader._loadRecursivelySingle` computes the document IRI by
/// stripping the fragment:
/// ```
///   final iri = inputIri.getDocumentIri(iriFactory); // "note-v1" (no #)
/// ```
/// It then looks up the `rdf:type` with the *stripped* IRI:
/// ```
///   final type = graph.findSingleObject<IriTerm>(iri, Rdf.type);
/// ```
/// But the graph's subjects carry the *fragment* form (`note-v1#`), so
/// `findSingleObject` returns `null`, the [DocumentMappingDependencyExtractor]
/// is never called, and imported documents (like `core-v1`) are never fetched.
///
/// Without core-v1, `predicateRules` is empty, `withFallback` receives no
/// global rule for `rdf:subject`, `stopTraversal` stays `null`, and
/// [splitDocument] descends from statement tombstones into app-resource
/// subjects — causing the `_preAppDataResourceTriples.isEmpty` assertion crash.
///
/// ## How to reproduce
///
/// The pattern that triggers the bug:
/// - Document mapping TTL uses `<foo#> a mc:DocumentMapping` (explicit IRI,
///   not `<>`), so the subject has a trailing `#`.
/// - That mapping imports `core-v1` via `mc:imports (mappings:core-v1)`.
/// - The governance IRI passed to [StandardMergeContractLoader.load] is the
///   fragment form (`foo#`).
///
/// `core-v1` itself does NOT trigger this because it uses `<>` as the
/// mc:DocumentMapping subject.  Resolving `<>` (empty-string reference)
/// against `@base <…/core-v1#>` under RFC 3986 §5.2.2 strips the fragment
/// component, yielding `…/core-v1` (no `#`).  The stripped document IRI
/// matches the subject, so the type lookup succeeds and imports are resolved.
void main() {
  group('import-chain IRI resolution via explicit-fragment subject', () {
    // A minimal DocumentMapping that uses <note-v1#> as an *explicit* subject
    // and imports core-v1 via the non-fragment IRI (mappings:core-v1).
    // This mirrors the exact pattern used by the personal-notes-app bootstrap
    // (mapping_bootstrap.g.dart in the example app).
    const noteV1Ttl = r"""
@base <https://test.example.org/mappings/> .
@prefix mc: <https://w3id.org/solid-crdt-sync/vocab/merge-contract#> .
@prefix mappings: <https://w3id.org/solid-crdt-sync/mappings/> .

<note-v1#> a mc:DocumentMapping;
    mc:classMapping ();
    mc:imports (mappings:core-v1);
    mc:predicateMapping () .
""";

    // Governance IRI as stored in the document: uses fragment form.
    final noteV1GovernanceIri =
        IriTerm.validated('https://test.example.org/mappings/note-v1#');

    late RdfCore rdfCore;

    setUp(() {
      rdfCore = RdfCore.withStandardCodecs();
    });

    /// Builds the merge contract for [noteV1GovernanceIri] through the full
    /// bootstrap / loader stack.
    Future<dynamic> buildContract() async {
      final fetcher = BootstrapRdfGraphFetcher(
        rdfCore: rdfCore,
        iriFactory: IriTerm.validated,
        // note-v1 is added on top of the built-in bootstrapMappings that
        // already contain core-v1.
        bootstrapSources: [noteV1Ttl],
      );
      final loader = RecursiveRdfLoader(
        fetcher: fetcher,
        iriFactory: IriTerm.validated,
      );
      return StandardMergeContractLoader(
        loader,
        CrdtTypeRegistry.forStandardTypes(),
      ).load([noteV1GovernanceIri]);
    }

    test(
        'rdf:subject is a stop-traversal predicate when core-v1 is '
        'reached through an explicit-fragment import chain', () async {
      // This test will FAIL with the current code because:
      // 1. _loadRecursivelySingle looks up rdf:type with the document IRI
      //    (note-v1, without #) but the graph subject is note-v1#.
      // 2. type == null → DocumentMappingDependencyExtractor not called.
      // 3. core-v1 never fetched → predicateRules = {}.
      // 4. withFallback receives null for rdf:subject → stopTraversal stays null.
      // 5. splitDocument traverses into app resource → frameworkGraph contains
      //    app-resource triples → assertion fires.
      //
      // After the fix (use inputIri, not iri, for type-lookup and extraction),
      // core-v1 IS loaded, predicateRules gain rdf:subject:stopTraversal=true,
      // and this test passes.
      final mergeContract = await buildContract();

      // Build a document that mirrors the real crash scenario:
      //   documentIri
      //     → sync:hasStatement → tombstone
      //     → rdf:subject       → appIri   ← traversal must STOP here
      //
      //   appIri carries several app-data triples that must NOT bleed into
      //   the framework graph.
      final documentIri =
          IriTerm.validated('https://test.example.org/doc/note-1');
      final tombstoneIri =
          IriTerm.validated('https://test.example.org/doc/note-1#lcrd-stmt-1');
      final appIri =
          IriTerm.validated('https://test.example.org/doc/note-1#note');

      final document = RdfGraph.fromTriples([
        Triple(documentIri, Rdf.type, Sync.ManagedDocument),
        Triple(documentIri, Sync.hasStatement, tombstoneIri),
        // Statement tombstone: rdf:subject points to the app resource.
        // No rdf:type triple — type must be inferred from the predicate rule,
        // exactly as in the production bug.
        Triple(tombstoneIri, Rdf.subject, appIri),
        Triple(
          tombstoneIri,
          Crdt.deletedAt,
          LiteralTerm(
            '2026-04-20T08:01:58.365Z',
            datatype: IriTerm('http://www.w3.org/2001/XMLSchema#dateTime'),
          ),
        ),
        // App data — must stay out of the framework graph.
        Triple(
            appIri, Rdf.type, IriTerm('https://test.example.org/vocab#Note')),
        Triple(
          appIri,
          IriTerm('https://schema.org/name'),
          LiteralTerm.string('My Note'),
        ),
        Triple(
          appIri,
          IriTerm('https://schema.org/text'),
          LiteralTerm.string('Some content'),
        ),
      ]);

      final (:frameworkGraph, :appGraph) =
          splitDocument(document, documentIri, mergeContract);

      expect(
        frameworkGraph.subjects,
        isNot(contains(appIri)),
        reason: 'App resource $appIri must not appear in frameworkGraph. '
            'The import chain note-v1# → core-v1 must be resolved so that '
            'rdf:subject carries stopTraversal=true.',
      );
      expect(
        appGraph.subjects,
        contains(appIri),
        reason: 'App resource must be preserved in appGraph',
      );
    });

    test(
        'merge contract loaded through explicit-fragment import chain '
        'has stopTraversal for rdf:subject', () async {
      // A more direct assertion: the resulting MergeContract must report
      // rdf:subject as a stop-traversal predicate (type=null → global rule).
      final mergeContract = await buildContract();

      expect(
        mergeContract.isStopTraversalPredicate(null, Rdf.subject),
        isTrue,
        reason:
            'core-v1 must be loaded via the import chain so that the global '
            'rdf:subject predicate rule (stopTraversal=true) is present.',
      );
    });
  });
}
