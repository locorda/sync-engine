/// Main facade for the CRDT sync system.
library;

import 'package:locorda_core/src/generated/_index.dart';
import 'package:locorda_core/src/mapping/merge_contract.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_rdf_core/core.dart';

({RdfGraph appGraph, RdfGraph frameworkGraph}) splitDocument(
    RdfGraph document, IriTerm documentIri, MergeContract mergeContract) {
  // We have to split the document into application data and framework metadata.

  final types = <RdfSubject, IriTerm?>{};
  final frameworkGraph =
      document.subgraph(documentIri, filter: (triple, depth) {
    final type = types.putIfAbsent(triple.subject,
        () => document.findSingleObject<IriTerm>(triple.subject, Rdf.type));

    final isStopTraversal =
        mergeContract.isStopTraversalPredicate(type, triple.predicate);
    return isStopTraversal
        ? TraversalDecision.includeButDontDescend
        : TraversalDecision.include;
  });

  return (
    appGraph: document.without(frameworkGraph),
    frameworkGraph: frameworkGraph
  );
}
