import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:locorda_core/src/crdt_document_manager.dart';
import 'package:locorda_core/src/vocab/generated/_index.dart';
import 'package:locorda_core/src/index/index_manager.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/storage/concurrent_update_exception.dart';
import 'package:locorda_core/src/storage/storage_interface.dart';
import 'package:locorda_core/src/util/retry.dart';
import 'package:logging/logging.dart';
import 'package:locorda_rdf_core/core.dart';

final _log = Logger('ShardDocumentGenerator');

typedef _ShardInfo = ({
  IriTerm shardIri,
  IriTerm indexIri,
  IriTerm resourceTypeIri,
  int maxPhysicalClock,
});

class ShardDocumentGenerator {
  final Storage _storage;
  final CrdtDocumentManager _documentManager;
  final IndexManager _indexManager;

  ShardDocumentGenerator({
    required Storage storage,
    required CrdtDocumentManager documentManager,
    required IndexManager indexManager,
  })  : _storage = storage,
        _documentManager = documentManager,
        _indexManager = indexManager;

  Future<void> call(DateTime syncTime, int lastSyncTimestamp) async {
    _log.info('Sync triggered - finding shards to update');
    _log.fine('Last sync timestamp: $lastSyncTimestamp');

    final shardsToUpdate = await _storage.getShardsToUpdate(lastSyncTimestamp);

    if (shardsToUpdate.isEmpty) {
      _log.info('No shards to update');
      return;
    }

    _log.info('Found ${shardsToUpdate.length} shard(s) to update, batching');

    await retryOnConflict(
      () => _syncShardsBatch(shardsToUpdate),
      debugOperationName: 'batch sync of ${shardsToUpdate.length} shards',
    );
  }

  /// Batch-syncs all [shardsToUpdate] in 4 storage roundtrips total.
  ///
  /// Phase 1 (2 reads): bulk-fetch shard entries and existing shard documents.
  /// Phase 2 (CPU): compute CRDT merges for all shards without I/O.
  /// Phase 3 (2 writes): batch-save all changed documents and their index entries.
  ///
  /// Throws [ConcurrentUpdateException] if a shard document was concurrently
  /// modified between the Phase 1 reads and the Phase 3 write; the caller
  /// ([retryOnConflict]) will retry the entire batch in that case.
  Future<void> _syncShardsBatch(List<_ShardInfo> shardsToUpdate) async {
    final allShardIris = shardsToUpdate.map((s) => s.shardIri).toList();
    final allShardDocumentIris =
        allShardIris.map((iri) => iri.getDocumentIri()).toList();

    // Phase 1: two batch reads — replaces 155×1 roundtrips per call type
    final entriesByShardIri =
        await _storage.getActiveIndexEntriesForShards(allShardIris);
    final existingDocsByIri =
        await _storage.getDocumentsByIri(allShardDocumentIris);

    // Phase 2: CPU-only CRDT merge for each shard (no I/O)
    final preparedSaves = <(_ShardInfo, PreparedDocumentSave)>[];
    for (final shardInfo in shardsToUpdate) {
      final shardDocumentIri = shardInfo.shardIri.getDocumentIri();
      final entries = entriesByShardIri[shardInfo.shardIri] ?? [];
      final existingDoc = existingDocsByIri[shardDocumentIri];

      final newTriples = generateShardNodes(
        shardDocumentIri: shardDocumentIri,
        shardResourceIri: shardInfo.shardIri,
        entries: entries,
      ).expand((node) => [
            Triple(shardInfo.shardIri, IdxShard.containsEntry, node.$1),
            ...node.$2.triples,
          ]);

      final prepared = await _documentManager.prepareModify(
        IdxShard.classIri,
        shardInfo.shardIri,
        (oldAppData) => buildShardAppData(
            oldAppData, shardInfo.shardIri, shardInfo.indexIri, newTriples),
        existingDoc,
        physicalTime: shardInfo.maxPhysicalClock,
        // shard documents may not exist yet on first write
        acceptMissing: true,
      );

      if (prepared != null) {
        preparedSaves.add((shardInfo, prepared));
      }
    }

    if (preparedSaves.isEmpty) {
      _log.info('No shard changes detected');
      return;
    }

    // Phase 3: two batch writes — replaces 155×2 roundtrips
    await _storage
        .saveDocuments(preparedSaves.map((pair) => pair.$2.request).toList());

    // For shard documents, prepareIndexEntryWrites is effectively a no-op
    // (shards are not themselves indexed), but we call it for correctness.
    final allIndexRequests = <SaveIndexEntryRequest>[];
    for (final (shardInfo, prepared) in preparedSaves) {
      final indexRequests = await _indexManager.prepareIndexEntryWrites(
        document: prepared.crdtDocument,
        documentIri: prepared.documentIri,
        resourceTypeIri: shardInfo.resourceTypeIri,
        physicalTime: prepared.physicalTime,
        updatedAt: prepared.updatedAt,
        missingGroupIndices: prepared.missingGroupIndices,
      );
      allIndexRequests.addAll(indexRequests);
    }

    if (allIndexRequests.isNotEmpty) {
      await _storage.saveIndexEntries(allIndexRequests);
    }

    _log.info('Synced ${preparedSaves.length} shard(s)');
  }

  /// Synchronizes a single shard by generating its document from DB entries.
  ///
  /// Process:
  /// 1. Load all active (non-deleted) entries for the shard from DB
  /// 2. Generate RDF graph with all entry fragments
  /// 3. Save shard document (DocumentManager handles diffing/tombstones)
  /// 4. Create missing GroupIndices from save results
  ///
  /// This method can be called:
  /// - By the sync timer for shards with changes
  /// - Manually after save operations in tests (via save_and_sync step)
  ///
  /// Retries up to 3 times on [ConcurrentUpdateException].
  ///
  /// Parameters:
  /// - [shardIri]: The IRI of the shard resource to sync
  ///
  /// Returns: SaveResult if changes were made, null if shard was up-to-date
  /// Throws: [StateError] if all retries fail due to concurrent updates
  Future<DocumentSaveResult?> syncShard(
    IriTerm shardIri,
    IriTerm indexIri,
    IriTerm resourceTypeIri,
    int maxPhysicalClock,
  ) =>
      retryOnConflict(
          () => _syncShardAttempt(
              shardIri, indexIri, resourceTypeIri, maxPhysicalClock),
          debugOperationName: 'syncing shard ${shardIri.debug}');

  /// Internal method that performs a single shard sync attempt.
  ///
  /// Throws [ConcurrentUpdateException] on optimistic lock failure.
  Future<DocumentSaveResult?> _syncShardAttempt(
    IriTerm shardIri,
    IriTerm indexIri,
    IriTerm resourceTypeIri,
    int maxPhysicalClock,
  ) async {
    final shardDocumentIri = shardIri.getDocumentIri();

    // 1. Load all active entries for this shard from DB
    final entries = await _storage.getActiveIndexEntriesForShard(shardIri);

    if (entries.isEmpty) {
      // No active entries - generate empty shard (will remove any existing entries)
      _log.fine(
          'Shard ${shardIri.debug} has no active entries, generating empty graph');
    } else {
      _log.fine(
          'Shard ${shardIri.debug} has ${entries.length} active entries, generating document');
    }
    // 2. Generate RDF graph for shard document from entries
    final newTriples = generateShardNodes(
      shardDocumentIri: shardDocumentIri,
      shardResourceIri: shardIri,
      entries: entries,
    ).expand((node) => [
          Triple(shardIri, IdxShard.containsEntry, node.$1),
          ...node.$2.triples
        ]);

    // 3. Modify shard document
    // DocumentManager will:
    // - load old data and call our callback to generate new graph from entries
    // - Compare with existing document
    // - Create tombstones for removed entries
    // - Return MissingGroupIndex instances if new groups detected
    final saveResult = await _documentManager.modify(
      IdxShard.classIri,
      shardIri,
      (oldAppData) =>
          buildShardAppData(oldAppData, shardIri, indexIri, newTriples),
      physicalTime: maxPhysicalClock,
      // shard documents may be created here if they didn't exist before
      acceptMissing: true,
    );

    if (saveResult == null) {
      _log.fine('Shard ${shardIri.debug} unchanged, skipping');
      return null;
    }

    // 4. Update indices for the saved document, e.g. create any missing GroupIndex documents
    await _indexManager.updateIndices(
      document: saveResult.crdtDocument,
      documentIri: saveResult.documentIri,
      physicalTime: saveResult.physicalTime,
      updatedAt: saveResult.updatedAt,
      resourceTypeIri: resourceTypeIri,
      missingGroupIndices: saveResult.missingGroupIndices,
    );

    return saveResult;
  }

  /// Generates RDF graph for a complete shard document.
  ///
  /// Creates a graph containing idx:containsEntry links and entry fragments
  /// for all provided entries. Entries must be from the same shard.
  ///
  /// The generated graph contains:
  /// - idx:containsEntry links from shard to each entry
  /// - Entry fragments with idx:resource, cm:clockHash, and optional headers
  ///
  /// All installations must generate identical graphs for the same entries
  /// to ensure CRDT convergence.
  List<Node> generateShardNodes({
    required IriTerm shardDocumentIri,
    required IriTerm shardResourceIri,
    required Iterable<IndexEntryWithIri> entries,
  }) {
    final nodes = <Node>[];
    for (final entry in entries) {
      if (entry.isDeleted) {
        // Skip deleted entries - they are handled by DocumentManager tombstones
        continue;
      }
      // Extract header properties from graph if present
      Map<IriTerm, List<RdfObject>>? headerProperties;
      if (entry.headerProperties != null) {
        headerProperties = {};
        for (final triple in entry.headerProperties!.triples) {
          if (triple.subject == entry.resourceIri) {
            headerProperties.putIfAbsent(triple.predicate as IriTerm, () => []);
            headerProperties[triple.predicate as IriTerm]!.add(triple.object);
          }
        }
        if (headerProperties.isEmpty) {
          headerProperties = null;
        }
      }

      // Generate entry IRI and fragment
      final (entryIri, entryGraph) = _generateIndexEntry(
        shardDocumentIri: shardDocumentIri,
        itemResourceIri: entry.resourceIri,
        clockHash: entry.clockHash,
        headerProperties: headerProperties,
      );

      // Add entry fragment triples
      nodes.add((entryIri, entryGraph));
    }

    return nodes;
  }

  /// Generates RDF graph for an index entry.
  ///
  /// Creates a graph containing:
  /// - Link from shard to entry (idx:containsEntry)
  /// - Entry properties (idx:resource, crdt:clockHash, optional headers)
  ///
  /// All installations must generate identical fragments for the same resource
  /// to ensure CRDT convergence. Uses MD5-based fragment generation as specified
  /// in proposal 010-index-entry-iri-identification.md
  Node _generateIndexEntry({
    required IriTerm shardDocumentIri,
    required IriTerm itemResourceIri,
    required String clockHash,
    Map<IriTerm, List<RdfObject>>? headerProperties,
  }) {
    // Generate deterministic fragment from resource IRI
    final entryFragment = _generateEntryFragment(itemResourceIri);
    final entryIri = IriTerm('${shardDocumentIri.value}#$entryFragment');

    final triples = <Triple>[
      // Entry properties
      Triple(entryIri, IdxShardEntry.resource, itemResourceIri), // Immutable
      Triple(
        entryIri,
        IdxShardEntry.crdtClockHash,
        LiteralTerm(clockHash),
      ), // LWW-Register
    ];

    // Optional header properties (all LWW-Register)
    if (headerProperties != null) {
      for (final entry in headerProperties.entries) {
        triples.addMultiple(entryIri, entry.key, entry.value);
      }
    }

    return (entryIri, triples.toRdfGraph());
  }

  /// Generates deterministic fragment identifier for index entry.
  ///
  /// Uses MD5 hash of resource IRI to ensure all installations
  /// generate identical fragment identifiers for the same resource.
  ///
  /// This is a specification requirement (proposal 010) - all implementations
  /// MUST use this exact algorithm for interoperability.
  ///
  /// Returns: `entry-{32-char-md5-hex}` (e.g., `entry-a1b2c3d4...`)
  String _generateEntryFragment(IriTerm resourceIri) {
    // Use full IRI value, not prefixed form
    final bytes = utf8.encode(resourceIri.value);
    final digest = md5.convert(bytes);
    return 'entry-${digest.toString()}'; // Full 32-character hex string
  }
}

RdfGraph buildShardAppData(RdfGraph oldAppData, IriTerm shardIri,
    IriTerm indexIri, Iterable<Triple> newTriples) {
  final hasIsShardOf =
      oldAppData.hasTriples(subject: shardIri, predicate: IdxShard.isShardOf);
  final hasType =
      oldAppData.hasTriples(subject: shardIri, predicate: IdxShard.rdfType);
  return RdfGraph.fromTriples([
    ...oldAppData
        .subgraph(
          shardIri,
          filter: (triple, depth) => triple.predicate == IdxShard.containsEntry
              ? TraversalDecision.skip
              : TraversalDecision.include,
        )
        .triples,
    if (!hasType) Triple(shardIri, IdxShard.rdfType, IdxShard.classIri),
    if (!hasIsShardOf) Triple(shardIri, IdxShard.isShardOf, indexIri),
    ...newTriples
  ]);
}
