/// Main facade for the CRDT sync system.
library;

import 'dart:async';

import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_core/src/crdt/property_clock.dart';
import 'package:locorda_core/src/hlc_service.dart';
import 'package:locorda_core/src/index/shard_determiner.dart';
import 'package:locorda_core/src/local_document_merger.dart';
import 'package:locorda_core/src/mapping/framework_iri_generator.dart';
import 'package:locorda_core/src/mapping/identified_blank_node_builder.dart';
import 'package:locorda_core/src/mapping/merge_contract.dart';
import 'package:locorda_core/src/mapping/merge_contract_loader.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/split_document.dart';
import 'package:locorda_core/src/standard_sync_engine.dart';
import 'package:locorda_core/src/storage/document_save_service.dart';
import 'package:locorda_core/src/vocab/generated/_index.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:logging/logging.dart';

final _log = Logger('CrdtDocumentManager');

typedef DocumentSaveResult = ({
  RdfSubject resourceIri,
  IriTerm documentIri,
  String? previousCursor, // The highest cursor for this type before this save (null if first)
  String currentCursor, // The cursor for this save operation
  RdfGraph crdtDocument,
  RdfGraph appData,
  int physicalTime,
  int updatedAt,
  List<ResolvedGroupIndex> resolvedGroupIndices,
});

/// Encapsulates the computed state for a deferred document write.
///
/// Returned by [CrdtDocumentManager.prepareModifyWithContract] to enable batching multiple
/// document writes into a single [Storage.saveDocuments] call. Callers must
/// pass [request] to [Storage.saveDocuments] to commit the change atomically.
typedef PreparedDocumentSave = ({
  IriTerm documentIri,
  IriTerm resourceIri,
  RdfGraph crdtDocument,
  RdfGraph appData,
  int physicalTime,
  int updatedAt,
  List<ResolvedGroupIndex> resolvedGroupIndices,
  SaveDocumentRequest request,
});

void _validateResourceGraph(
  IriTerm documentIri,
  IriTerm primaryResourceIri,
  IriTerm resourceType,
  RdfGraph resourceGraph,
) {
  // Validate that resourceGraph doesn't contain triples with documentIri as subject
  final hasDocumentTriples = resourceGraph.hasTriples(subject: documentIri);
  if (hasDocumentTriples) {
    throw ArgumentError('Resource graph contains triple(s) with document IRI '
        '$documentIri as subject. The document IRI is reserved for CRDT framework '
        'metadata and must not be used in resource data. Resource data should use '
        'fragment identifiers (e.g., ${documentIri.value}#it).');
  }

  // Validate that the primary resource actually exists in the resource graph with the correct type
  final hasPrimaryResourceTriples = resourceGraph.hasTriples(
      subject: primaryResourceIri, predicate: Rdf.type, object: resourceType);
  if (!hasPrimaryResourceTriples) {
    throw ArgumentError(
        'Primary resource IRI ($primaryResourceIri) not found in resource graph '
        'or does not have the expected type ($resourceType)');
  }

  final documentIriValue = documentIri.value;

  // Validate all resource IRIs are a proper fragment of the document IRI
  final iriSubjects = resourceGraph.subjects.whereType<IriTerm>().toSet();
  for (final iriSubject in iriSubjects) {
    final iriSubjectValue = iriSubject.value;
    if (!iriSubjectValue.startsWith('$documentIriValue#')) {
      throw ArgumentError(
          'Resource IRI ($iriSubjectValue) must be a fragment of the '
          'document IRI ($documentIriValue). Expected format: ${documentIriValue}#fragmentId');
    }
    if (iriSubjectValue.startsWith(
        '$documentIriValue#${FrameworkIriGenerator.fragmentPrefix}')) {
      throw ArgumentError(
          'Resource IRI ($iriSubjectValue) must not start with reserved prefix #lcrd- in fragment identifier. '
          'This prefix is reserved for CRDT framework metadata.');
    }
  }
}

final _defaultManagedDocumentLevelPredicates = <IriTerm>{
  Rdf.type,
  SyncManagedDocument.managedResourceType,
  SyncManagedDocument.foafPrimaryTopic,
  SyncManagedDocument.isGovernedBy,
  SyncManagedDocument.crdtHasClockEntry,
  SyncManagedDocument.crdtClockHash,
  // crdtCreatedAt is intentionally absent: all existing cm:createdAt values
  // are pre-copied into allTriples in step 7, so step 10's dynamic skip-set
  // naturally covers them — no copy-through needed and no tombstones generated.
  SyncManagedDocument.crdtDeletedAt,
  SyncManagedDocument.hasBlankNodeMapping,
  SyncManagedDocument.hasStatement,
  // sync:hasPropertyClock pointers are emitted via a dedicated channel in
  // step 11 (below) — the local merger explicitly removes overridden
  // pointers via triplesToRemove. Listing the predicate here prevents
  // step 10 from re-copying them and creating duplicates.
  SyncPropertyClock.hasPropertyClock,
};

/// Removes resource tombstones from [oldFrameworkGraph] for subjects that are
/// still present in [liveAppSubjects].
///
/// During a local save, [appData] is authoritative. A resource tombstone for a
/// subject that exists in the current app graph is a stale artifact — typically
/// created by a prior traversal bug — and must be purged before CRDT comparison
/// or document construction. Carrying it forward would cause it to propagate to
/// remote peers or trigger spurious deletions during merge.
///
/// A resource tombstone is a `sync:hasStatement` node with `rdf:subject` set
/// but no `rdf:predicate`, distinguishing it from property-level metadata.
RdfGraph? removeStaleResourceTombstones(
  IriTerm documentIri,
  RdfGraph? oldFrameworkGraph,
  Set<RdfSubject> liveAppSubjects,
) {
  if (oldFrameworkGraph == null || liveAppSubjects.isEmpty) {
    return oldFrameworkGraph;
  }
  final staleStatementIris = <IriTerm>[];
  for (final stmtIri in oldFrameworkGraph.getMultiValueObjects<IriTerm>(
      documentIri, SyncManagedDocument.hasStatement)) {
    final stmtSubject = oldFrameworkGraph.findSingleObject<RdfSubject>(
        stmtIri, RdfStatement.subject);
    final stmtPredicate = oldFrameworkGraph.findSingleObject<IriTerm>(
        stmtIri, RdfStatement.predicate);
    final isTombstone = oldFrameworkGraph
        .findTriples(subject: stmtIri, predicate: RdfStatement.crdtDeletedAt)
        .isNotEmpty;
    if (stmtSubject != null &&
        stmtPredicate == null &&
        isTombstone &&
        liveAppSubjects.contains(stmtSubject)) {
      staleStatementIris.add(stmtIri);
    }
  }
  if (staleStatementIris.isEmpty) return oldFrameworkGraph;

  final triplesToRemove = <Triple>[];
  for (final stmtIri in staleStatementIris) {
    triplesToRemove
        .add(Triple(documentIri, SyncManagedDocument.hasStatement, stmtIri));
    triplesToRemove.addAll(oldFrameworkGraph.findTriples(subject: stmtIri));
  }
  return oldFrameworkGraph.without(RdfGraph.fromTriples(triplesToRemove));
}

/// Constructs a complete CRDT-managed document with framework metadata.
///
/// Takes the resource graph and wraps it with all required CRDT framework metadata:
/// - sync:ManagedDocument type declaration
/// - sync:managedResourceType pointing to the resource type
/// - sync:isGovernedBy linking to merge contract
/// - CRDT clock entries with logical and physical times
/// - Clock hash for efficient change detection
/// - CRDT metadata (tombstones, etc.) from change detection
///
/// The resulting document contains both the original resource triples and
/// all the framework metadata needed for CRDT synchronization.
List<Triple> _constructCrdtDocument(
  IriTerm documentIri,
  RdfGraph? oldFrameworkGraph,
  List<Node> crdtMetadata,
  List<Node> propertyClocks,
  List<RdfObject> governedByFiles,
  IriTerm primaryResourceIri,
  IriTerm resourceType,
  RdfObject createdAt,
  CurrentCrdtClock clock,
  IdentifiedBlankNodes<IriTerm> blankNodeMappings,
  Iterable<IriTerm> shards,
) {
  final allTriples = <Triple>[];

  // 1. Add sync:ManagedDocument type declaration
  allTriples.add(Triple(
    documentIri,
    Rdf.type,
    SyncManagedDocument.classIri,
  ));

  // 2. Add managed resource type
  allTriples.add(Triple(
    documentIri,
    SyncManagedDocument.managedResourceType,
    resourceType,
  ));

  // 3. Add primary topic reference (the main resource this document describes)
  allTriples.add(Triple(
    documentIri,
    SyncManagedDocument.foafPrimaryTopic,
    primaryResourceIri,
  ));

  // 4. make sure the merge contracts are included
  allTriples.addRdfList(
      documentIri, SyncManagedDocument.isGovernedBy, governedByFiles);

  // 5. Add HLC clock entry
  allTriples.addNodes(
      documentIri, SyncManagedDocument.crdtHasClockEntry, clock.fullClock);

  // 6. Generate and add clock hash
  allTriples.add(Triple(
      documentIri, SyncManagedDocument.crdtClockHash, LiteralTerm(clock.hash)));

  // 7. Add creation timestamp (OR-Set semantics: union all existing values + new one).
  // All old values must be added to allTriples HERE — Step 10 dynamically builds its
  // skip-set from allTriples, so any predicate already present there will be skipped
  // when copying from oldFrameworkGraph. Without pre-copying the old values, Step 10
  // would omit them entirely, causing localValueChange to see them as "removed" and
  // emit tombstones — violating OR-Set add-wins semantics.
  if (oldFrameworkGraph != null) {
    allTriples.addAll(oldFrameworkGraph.findTriples(
      subject: documentIri,
      predicate: SyncManagedDocument.crdtCreatedAt,
    ));
  }
  allTriples.add(Triple(
    documentIri,
    SyncManagedDocument.crdtCreatedAt,
    createdAt,
  ));

  // 8. Add blank node mappings for identified blank nodes
  // Create framework-reserved fragment identifiers and map them to blank nodes
  allTriples.addAll(toBlankNodeMappingTriples(blankNodeMappings, documentIri));

  // 9. add shard references
  allTriples.addMultiple(
      documentIri, SyncManagedDocument.idxBelongsToIndexShard, shards);

  // 10. add old/foreign framework triples
  final allManagedDocumentLevelPredicates = {
    ..._defaultManagedDocumentLevelPredicates,
    ...allTriples.where((t) => t.subject == documentIri).map((t) => t.predicate)
  };
  final additionalGraph =
      oldFrameworkGraph?.subgraph(documentIri, filter: (t, depth) {
    if (t.subject != documentIri) {
      // We only filter triples with the document as subject, everything else is included
      // once we reached it via the non-skipped triples
      return TraversalDecision.include;
    }
    // Really important: do not skip any existing statements from the old framework graph, we need to copy them over!
    return t.predicate != SyncManagedDocument.hasStatement &&
            allManagedDocumentLevelPredicates.contains(t.predicate)
        ? TraversalDecision.skip
        : TraversalDecision.include;
  });
  if (additionalGraph != null) {
    allTriples.addAll(additionalGraph.triples);
  }

  // 11. Add CRDT metadata (tombstones, counters, etc.)
  allTriples.addNodes(
      documentIri, SyncManagedDocument.hasStatement, crdtMetadata);

  // 11b. Add per-property change clocks (sync:PropertyClock). These are
  // emitted on a dedicated predicate so they can be merged independently
  // of rdf:Statement-based property metadata. Pre-existing PropertyClock
  // pointers from the old framework graph are NOT in the skip-list at
  // step 10 (sync:hasPropertyClock is in
  // _defaultManagedDocumentLevelPredicates), so we explicitly re-copy
  // surviving (non-overridden) records here.
  if (oldFrameworkGraph != null) {
    final newClockIris = propertyClocks.map((n) => n.$1).toSet();
    for (final t in oldFrameworkGraph.findTriples(
        subject: documentIri,
        predicate: SyncPropertyClock.hasPropertyClock)) {
      final clockIri = t.object;
      if (clockIri is! IriTerm) continue;
      if (newClockIris.contains(clockIri)) continue;
      allTriples.add(t);
      // Copy the clock subgraph (resource, hasClockEntry, changedProperty
      // etc.) — triplesToRemove on the merger output already prunes
      // overridden changedProperty triples.
      allTriples.addAll(oldFrameworkGraph.findTriples(subject: clockIri));
    }
  }
  allTriples.addNodes(
      documentIri, SyncPropertyClock.hasPropertyClock, propertyClocks);

  return allTriples;
}

Iterable<Triple> toBlankNodeMappingTriples(
    IdentifiedBlankNodes<IriTerm> blankNodeMappings,
    IriTerm documentIri) sync* {
  for (final entry in blankNodeMappings.identifiedMap.entries) {
    final blankNode = entry.key;
    final canonicalIris = entry.value;

    for (final canonicalIri in canonicalIris) {
      // Add sync:hasBlankNodeMapping link from document to mapping
      yield Triple(
        documentIri,
        SyncManagedDocument.hasBlankNodeMapping,
        canonicalIri,
      );

      // Add the mapping itself: canonicalIri sync:blankNode _:blankNode
      yield Triple(
        canonicalIri,
        Sync.blankNode,
        blankNode,
      );
      // Optimization: do not add the type for the mapping - it is not strictly necessary
      /*
      // Add type for the mapping
      yield Triple(
        canonicalIri,
        SyncBlankNodeMapping.classIri,
      );
      */
    }
  }
}

/// Computes the governance IRI list for a document.
///
/// Reads `sync:isGovernedBy` from the existing graph and ensures our
/// config's crdtMapping IRI is included.
List<IriTerm> computeIsGovernedBy(RdfGraph? oldFrameworkGraph,
    IriTerm documentIri, SyncEngineConfig config, IriTerm resourceType) {
  final oldIsGovernedByFiles = oldFrameworkGraph?.getListObjects<IriTerm>(
          documentIri, SyncManagedDocument.isGovernedBy) ??
      const <IriTerm>[];
  final ourGovernedByFile = IriTerm.validated(
      config.getResourceConfig(resourceType).crdtMapping.toString());
  return oldIsGovernedByFiles.contains(ourGovernedByFile)
      ? oldIsGovernedByFiles
      : ([...oldIsGovernedByFiles, ourGovernedByFile]);
}

/// Main facade for the locorda system.
///
/// Provides a simple, high-level API for offline-first applications with
/// optional Solid Pod synchronization. Handles RDF mapping, storage,
/// and sync operations transparently.
class CrdtDocumentManager {
  final Storage _storage;
  final DocumentSaveService _saveService;
  final ConfigService _configService;
  SyncEngineConfig get _config => _configService.currentConfig;
  final MergeContractLoader _mergeContractLoader;
  final ShardDeterminer _shardDeterminer;
  final LocalDocumentMerger _localDocumentMerger;
  final PhysicalTimestampFactory _physicalTimestampFactory;

  // Factory functions for configurable time and clock generation
  final HlcService _hlcService;

  CrdtDocumentManager({
    required Storage storage,
    required DocumentSaveService documentSaveService,
    required ConfigService configService,
    required MergeContractLoader mergeContractLoader,
    required HlcService hlcService,
    required ShardDeterminer shardDeterminer,
    required LocalDocumentMerger localDocumentMerger,
    required PhysicalTimestampFactory physicalTimestampFactory,
  })  : _storage = storage,
        _saveService = documentSaveService,
        _configService = configService,
        _mergeContractLoader = mergeContractLoader,
        _hlcService = hlcService,
        _localDocumentMerger = localDocumentMerger,
        _physicalTimestampFactory = physicalTimestampFactory,
        _shardDeterminer = shardDeterminer;

  /// Save an object with CRDT processing.
  ///
  /// Stores the object locally and triggers sync if connected to Solid Pod.
  /// Application state is updated via the hydration stream - repositories should
  /// listen to hydrateStreaming() to receive updates.
  ///
  /// Process:
  /// 1. CRDT processing (merge with existing, clock increment)
  /// 2. Store locally in sync system
  /// 3. Hydration stream automatically emits update
  /// 4. Schedule async Pod sync
  ///
  /// Throws [ConcurrentUpdateException] on optimistic lock failure.
  Future<DocumentSaveResult?> save(IriTerm type, RdfGraph appData,
      {int? physicalTime, int? logicalTime}) async {
    // Validate input parameters
    if (appData.isEmpty) {
      throw ArgumentError('Cannot save empty graph');
    }
    // 1. Extract resource and document IRIs (with validation)
    late final IriTerm resourceIri;
    late final IriTerm documentIri;

    try {
      resourceIri = appData.getIdentifier(type);
      documentIri = resourceIri.getDocumentIri();
    } on ArgumentError catch (e) {
      _log.severe('Invalid resource configuration for type $type: $e');
      rethrow;
    } on StateError catch (e) {
      _log.severe('Multiple or no resources of type $type found in graph: $e');
      throw ArgumentError(
          'Graph must contain exactly one resource of type $type');
    }

    // 2. Load existing document from storage (if any)
    final (
      oldAppData: oldAppData,
      oldFrameworkGraph: oldFrameworkGraph,
      mergeContract: mergeContract,
      governedByFiles: governedByFiles,
      oldUpdatedAt: oldUpdatedAt,
    ) = await _prepare(type, documentIri);
    return await _save(type, resourceIri, documentIri, appData, oldAppData,
        oldFrameworkGraph, mergeContract, governedByFiles,
        oldUpdatedAt: oldUpdatedAt,
        physicalTime: physicalTime,
        logicalTime: logicalTime);
  }

  /// Throws [ConcurrentUpdateException] on optimistic lock failure.
  Future<DocumentSaveResult?> modify(IriTerm type, IriTerm primaryResourceIri,
      RdfGraph Function(RdfGraph oldAppData) modifier,
      {int? physicalTime, bool acceptMissing = false}) async {
    final IriTerm documentIri = primaryResourceIri.getDocumentIri();
    // 1. Extract resource and document IRIs (with validation)

    final (
      oldAppData: oldAppData,
      oldFrameworkGraph: oldFrameworkGraph,
      mergeContract: mergeContract,
      governedByFiles: governedByFiles,
      oldUpdatedAt: oldUpdatedAt,
    ) = await _prepare(type, documentIri);
    if (oldAppData == null && !acceptMissing) {
      throw ArgumentError(
          'Cannot patch non-existing document ${documentIri.debug} - use save() instead');
    }

    // let the caller derive the app data from the old state
    final appData = modifier(oldAppData == null ? RdfGraph() : oldAppData);

    return await _save(
      type,
      primaryResourceIri,
      documentIri,
      appData,
      oldAppData,
      oldFrameworkGraph,
      mergeContract,
      governedByFiles,
      physicalTime: physicalTime,
      oldUpdatedAt: oldUpdatedAt,
    );
  }

  /// Sync-only deferred-write variant using a pre-loaded [MergeContract].
  ///
  /// Shard calculation is skipped — callers must pass the expected shards
  /// directly. For shard documents ([IdxShard]), this is always empty.
  PreparedDocumentSave? prepareModifyWithContract(
    IriTerm type,
    IriTerm primaryResourceIri,
    RdfGraph Function(RdfGraph oldAppData) modifier,
    StoredDocument? preloadedDoc,
    MergeContract mergeContract, {
    Set<IriTerm> shards = const {},
    List<ResolvedGroupIndex> resolvedGroupIndices = const [],
    int? physicalTime,
    bool acceptMissing = false,
    PipeperfCollector? perf,
  }) {
    final documentIri = primaryResourceIri.getDocumentIri();
    final oldDocument = preloadedDoc?.document;
    final oldUpdatedAt = preloadedDoc?.metadata.updatedAt;

    final governedByFiles =
        computeIsGovernedBy(oldDocument, documentIri, _config, type);

    final (appGraph: oldAppData, frameworkGraph: oldFrameworkGraph) =
        oldDocument == null
            ? (appGraph: null, frameworkGraph: null)
            : splitDocument(oldDocument, documentIri, mergeContract);

    if (oldAppData == null && !acceptMissing) {
      throw ArgumentError(
          'Cannot patch non-existing document ${documentIri.debug} - use save() instead');
    }
    final appData = modifier(oldAppData ?? RdfGraph());
    return _computeSaveCore(
      type,
      primaryResourceIri,
      documentIri,
      appData,
      oldAppData,
      oldFrameworkGraph,
      mergeContract,
      governedByFiles,
      allShards: shards,
      resolvedGroupIndices: resolvedGroupIndices,
      physicalTime: physicalTime,
      oldUpdatedAt: oldUpdatedAt,
      perf: perf,
    );
  }

  Future<
      ({
        RdfGraph? oldAppData,
        RdfGraph? oldFrameworkGraph,
        MergeContract mergeContract,
        List<IriTerm> governedByFiles,
        int? oldUpdatedAt, // For optimistic locking - use updatedAt not ourPhysicalClock
      })> _prepare(IriTerm type, IriTerm documentIri) async {
    StoredDocument? existingStoredDocument;
    try {
      existingStoredDocument = await _storage.getDocument(documentIri);
    } catch (e) {
      _log.warning('Failed to load existing document $documentIri: $e');
      // Continue with save - treat as new document
    }
    final oldDocument = existingStoredDocument?.document;
    // Use updatedAt (not ourPhysicalClock) for optimistic locking because:
    // - updatedAt changes on every save (local AND remote merges)
    // - ourPhysicalClock only changes when we make local modifications
    // - updatedAt provides monotonic versioning across all operations
    final oldUpdatedAt = existingStoredDocument?.metadata.updatedAt;

    final governedByFiles =
        computeIsGovernedBy(oldDocument, documentIri, _config, type);

    // load the governing documents / merge contracts for correct document splitting
    final mergeContract = await _mergeContractLoader.load(governedByFiles);

    final (appGraph: oldAppData, frameworkGraph: oldFrameworkGraph) =
        oldDocument == null
            ? (appGraph: null, frameworkGraph: null)
            : splitDocument(oldDocument, documentIri, mergeContract);

    return (
      oldAppData: oldAppData,
      oldFrameworkGraph: oldFrameworkGraph,
      mergeContract: mergeContract,
      governedByFiles: governedByFiles,
      oldUpdatedAt: oldUpdatedAt,
    );
  }

  /// CPU-only CRDT merge and document construction, without a storage write.
  ///
  /// Returns null if no property changes are detected (document unchanged).
  /// Used by [_save], which adds the storage write.
  Future<PreparedDocumentSave?> _computeSave(
    IriTerm type,
    IriTerm resourceIri,
    IriTerm documentIri,
    RdfGraph appData,
    RdfGraph? oldAppData,
    RdfGraph? oldFrameworkGraph,
    MergeContract mergeContract,
    List<IriTerm> governedByFiles, {
    int? physicalTime,
    int? logicalTime,
    int? oldUpdatedAt,
  }) async {
    final (allShards, _, resolvedGroupIndices, missingIndexDocuments) =
        await _shardDeterminer.calculateShards(
      type,
      resourceIri,
      documentIri,
      appData,
      oldAppData,
      oldFrameworkGraph,
      mode: ShardDeterminationMode.lenient,
    );

    if (missingIndexDocuments.isNotEmpty) {
      _log.info(
          'Some index documents not yet available for ${resourceIri.debug}, '
          'shards will be recalculated on next sync: $missingIndexDocuments');
    }

    return _computeSaveCore(
      type,
      resourceIri,
      documentIri,
      appData,
      oldAppData,
      oldFrameworkGraph,
      mergeContract,
      governedByFiles,
      allShards: allShards,
      resolvedGroupIndices: resolvedGroupIndices,
      physicalTime: physicalTime,
      logicalTime: logicalTime,
      oldUpdatedAt: oldUpdatedAt,
    );
  }

  /// Sync core of [_computeSave]. All I/O (shard calculation, contract
  /// loading) must be completed beforehand.
  PreparedDocumentSave? _computeSaveCore(
    IriTerm type,
    IriTerm resourceIri,
    IriTerm documentIri,
    RdfGraph appData,
    RdfGraph? oldAppData,
    RdfGraph? oldFrameworkGraph,
    MergeContract mergeContract,
    List<IriTerm> governedByFiles, {
    required Set<IriTerm> allShards,
    required List<ResolvedGroupIndex> resolvedGroupIndices,
    int? physicalTime,
    int? logicalTime,
    int? oldUpdatedAt,
    PipeperfCollector? perf,
  }) {
    RdfGraph? crdtDocument;
    RdfGraph? frameworkGraph;
    final sw = perf?.start('_computeSave');
    try {
      if (appData.isEmpty) {
        throw ArgumentError('Cannot save empty graph');
      }

      _validateResourceGraph(documentIri, resourceIri, type, appData);

      _log.fine(
          'Saving resource ${resourceIri.debug} to document ${documentIri.debug}');

      final clock = _hlcService.createOrIncrementClock(
        oldFrameworkGraph,
        documentIri,
        physicalTime: physicalTime,
        logicalTime: logicalTime,
      );
      final physicalTimestamp = clock.physicalTime;

      final updatedAtTimestamp = _physicalTimestampFactory();

      sw?.stopSection('clock');

      final (
        metadata: crdtMetadata,
        newBlankNodes: appBlankNodes,
        oldBlankNodes: _,
      ) = _localDocumentMerger.generateMetadata(
        documentIri,
        appData,
        oldAppData,
        oldFrameworkGraph,
        mergeContract,
        clock,
        appDataTypeIri: type,
        ownClockEntryIri: _hlcService.getOwnClockEntryIri(documentIri),
      );

      sw?.stopSection('appMeta');

      final propertyChanges = crdtMetadata.propertyChanges;
      if (propertyChanges.isEmpty) {
        _log.info(
            'No property changes detected for ${resourceIri.debug}, skipping save');
        return null;
      }

      final createdAt = oldFrameworkGraph?.findMaxDateTimeObject(
              documentIri, SyncManagedDocument.crdtCreatedAt) ??
          LiteralTermExtensions.dateTime(updatedAtTimestamp);

      // During a local save appData is authoritative: purge resource tombstones
      // for subjects that are still live. Applying this before _constructCrdtDocument
      // AND generateMetadata(isFrameworkData) ensures both consumers see a
      // consistent view and prevents tombstone-of-tombstone artifacts.
      final effectiveOldFrameworkGraph = removeStaleResourceTombstones(
          documentIri, oldFrameworkGraph, appData.subjects);

      final documentTriples = _constructCrdtDocument(
        documentIri,
        effectiveOldFrameworkGraph,
        crdtMetadata.statements,
        crdtMetadata.propertyClocks,
        governedByFiles,
        resourceIri,
        type,
        createdAt,
        clock,
        appBlankNodes,
        allShards,
      );
      frameworkGraph = RdfGraph.fromTriples(documentTriples);
      final (
        metadata: frameworkMetadata,
        oldBlankNodes: _,
        newBlankNodes: _,
      ) = _localDocumentMerger.generateMetadata(
        documentIri,
        frameworkGraph,
        effectiveOldFrameworkGraph,
        effectiveOldFrameworkGraph,
        mergeContract,
        clock,
        appDataTypeIri: type,
        isFrameworkData: true,
      );
      propertyChanges.addAll(frameworkMetadata.propertyChanges);

      documentTriples.addNodes(documentIri, SyncManagedDocument.hasStatement,
          frameworkMetadata.statements);

      crdtMetadata.triplesToRemove.forEach(documentTriples.remove);
      frameworkMetadata.triplesToRemove.forEach(documentTriples.remove);

      // DEBUG: assert no resourceIri-subject triples snuck in before appData
      final _preAppDataResourceTriples =
          documentTriples.where((t) => t.subject == resourceIri).toList();
      assert(
        _preAppDataResourceTriples.isEmpty,
        'BUG: documentTriples already contains ${_preAppDataResourceTriples.length} '
        'resourceIri-subject triples BEFORE appData.addAll: \n${turtle.encode(RdfGraph.fromTriples(documentTriples))}\n\nOld Framework Graph:\n${turtle.encode(oldFrameworkGraph ?? RdfGraph())}\n\nApp Data:\n${turtle.encode(appData)}',
      );

      documentTriples.addAll(appData.triples);

      // DEBUG: assert appData.triples has no duplicates for resourceIri-subject triples
      final _appResourceTriples =
          appData.triples.where((t) => t.subject == resourceIri).toList();
      final _appResourceTriplesDeduped = _appResourceTriples.toSet().toList();
      assert(
        _appResourceTriples.length == _appResourceTriplesDeduped.length,
        'BUG: appData.triples contains ${_appResourceTriples.length - _appResourceTriplesDeduped.length} '
        'duplicate resourceIri-subject triples: '
        '${_appResourceTriples.where((t) => _appResourceTriples.where((t2) => t2 == t).length > 1).toSet()}',
      );

      crdtDocument = RdfGraph.fromTriples(documentTriples);

      sw?.stopSection('frameworkMetaAndMerge');

      final documentMetadata = DocumentMetadata(
        ourPhysicalClock: physicalTimestamp,
        updatedAt: updatedAtTimestamp.millisecondsSinceEpoch,
      );

      return (
        documentIri: documentIri,
        resourceIri: resourceIri,
        crdtDocument: crdtDocument,
        appData: appData,
        physicalTime: clock.physicalTime,
        updatedAt: updatedAtTimestamp.millisecondsSinceEpoch,
        resolvedGroupIndices: resolvedGroupIndices,
        request: SaveDocumentRequest(
          documentIri: documentIri,
          typeIri: type,
          document: crdtDocument,
          metadata: documentMetadata,
          changes: propertyChanges,
          ifMatchUpdatedAt: oldUpdatedAt,
        ),
      );
    } on UnidentifiedBlankNodeException catch (e, stackTrace) {
      _log.severe(
          'Save operation failed for type ${type.debug}', e, stackTrace);
      final blankNode = e.blankNode;
      _throwIfUsedIn(stackTrace, "New App Data", appData, blankNode);
      _throwIfUsedIn(
          stackTrace, "New Framework Data", frameworkGraph, blankNode);
      _throwIfUsedIn(stackTrace, "New Document", crdtDocument, blankNode);
      rethrow;
    } catch (e, stackTrace) {
      _log.severe(
          'Save operation failed for type ${type.debug}', e, stackTrace);
      rethrow;
    } finally {
      sw?.stop();
    }
  }

  /// Throws [ConcurrentUpdateException] on optimistic lock failure.
  Future<DocumentSaveResult?> _save(
    IriTerm type,
    IriTerm resourceIri,
    IriTerm documentIri,
    RdfGraph appData,
    RdfGraph? oldAppData,
    RdfGraph? oldFrameworkGraph,
    MergeContract mergeContract,
    List<IriTerm> governedByFiles, {
    int? physicalTime,
    int? logicalTime,
    int? oldUpdatedAt,
  }) async {
    final prepared = await _computeSave(
      type,
      resourceIri,
      documentIri,
      appData,
      oldAppData,
      oldFrameworkGraph,
      mergeContract,
      governedByFiles,
      physicalTime: physicalTime,
      logicalTime: logicalTime,
      oldUpdatedAt: oldUpdatedAt,
    );
    if (prepared == null) return null;

    late final SaveDocumentResult saveResult;
    try {
      saveResult = await _saveService.saveDocument(prepared.request);
    } on ConcurrentUpdateException {
      rethrow;
    } catch (e) {
      _log.severe(
          'Failed to save document ${documentIri.debug} to storage: $e');
      rethrow;
    }

    _log.finer(
        'Successfully saved document ${documentIri.debug} with ${prepared.request.changes.length} property changes');
    return (
      documentIri: prepared.documentIri,
      resourceIri: prepared.resourceIri,
      crdtDocument: prepared.crdtDocument,
      appData: prepared.appData,
      previousCursor: saveResult.previousCursor,
      currentCursor: saveResult.currentCursor,
      resolvedGroupIndices: prepared.resolvedGroupIndices,
      physicalTime: prepared.physicalTime,
      updatedAt: prepared.updatedAt,
    );
  }

  void _throwIfUsedIn(StackTrace stackTrace, String context,
      RdfGraph? oldDocument, BlankNodeTerm blankNode) {
    if (oldDocument != null) {
      final subjectTriples = oldDocument.findTriples(subject: blankNode);
      final objectTriples = oldDocument.findTriples(object: blankNode);
      if (subjectTriples.isNotEmpty || objectTriples.isNotEmpty) {
        final ex = UnidentifiedBlankNodeWithContextException(blankNode, context,
            subjectTriples.toList(), objectTriples.toList());
        Error.throwWithStackTrace(ex, stackTrace);
      }
    }
  }

  /// Close the sync system and free resources.
  Future<void> close() async {
    await _storage.close();
  }

  Future<bool> hasDocument(IriTerm documentIri) async {
    return (await _storage.getDocument(documentIri) != null);
  }
}
