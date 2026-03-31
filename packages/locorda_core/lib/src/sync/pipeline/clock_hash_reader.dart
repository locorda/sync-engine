/// Reads clock hashes from stored documents for meta-index stability checks.
///
/// Shared between [StreamingRemoteSyncOrchestrator] (initial snapshot) and
/// Stage 14 (stability verification after a pipeline pass).
///
/// The current implementation loads full documents and extracts the clock hash
/// from the RDF graph. For the typical use case of 3 meta-index documents
/// this is acceptable, but should be verified with profiling if the number
/// of documents grows.
library;

import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/storage/storage_interface.dart' show Storage;
import 'package:locorda_core/src/vocab/generated/_index.dart';
import 'package:locorda_rdf_core/core.dart';

/// Read clock hashes for the given document IRIs from storage (batch).
///
/// Returns a map of document IRI → clock hash string. Documents that don't
/// exist or have no clock hash are omitted from the result.
Future<Map<IriTerm, String>> readClockHashes(
  Storage storage,
  Iterable<IriTerm> documentIris,
) async {
  final docs = await storage.getDocumentsByIri(documentIris);
  final result = <IriTerm, String>{};
  for (final entry in docs.entries) {
    final doc = entry.value;
    if (doc == null) continue;
    final clockHash = doc.document
        .findSingleObject<LiteralTerm>(
            entry.key, SyncManagedDocument.crdtClockHash)
        ?.value;
    if (clockHash != null) {
      result[entry.key] = clockHash;
    }
  }
  return result;
}
