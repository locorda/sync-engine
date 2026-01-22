/// Main facade for the CRDT sync system.
library;

import 'dart:async';

import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_core/src/local_document_merger.dart';
import 'package:locorda_core/src/generated/_index.dart';
import 'package:locorda_core/src/hlc_service.dart';
import 'package:locorda_core/src/index/shard_determiner.dart';
import 'package:locorda_core/src/mapping/framework_iri_generator.dart';
import 'package:locorda_core/src/mapping/identified_blank_node_builder.dart';
import 'package:locorda_core/src/mapping/merge_contract.dart';
import 'package:locorda_core/src/mapping/merge_contract_loader.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/split_document.dart';
import 'package:logging/logging.dart';
import 'package:locorda_rdf_core/core.dart';

final _log = Logger('CrdtDocumentManager');

typedef IdentifiedGraph = (IriTerm id, RdfGraph graph);
typedef DocumentSaveResult = ({
  RdfSubject resourceIri,
  IriTerm documentIri,
  String? previousCursor, // The highest cursor for this type before this save (null if first)
  String currentCursor, // The cursor for this save operation
  RdfGraph crdtDocument,
  RdfGraph appData,
  int physicalTime,
  int updatedAt,
  List<
      MissingGroupIndex> missingGroupIndices // GroupIndices that need to be created
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
  SyncManagedDocument.crdtCreatedAt,
  SyncManagedDocument.crdtDeletedAt,
  SyncManagedDocument.hasBlankNodeMapping,
  SyncManagedDocument.hasStatement
};

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

  // 7. Add creation timestamp (OR-Set semantics for document lifecycle)

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
        Rdf.type,
        SyncBlankNodeMapping.classIri,
      );
      */
    }
  }
}

List<IriTerm> _computeIsGovernedBy(RdfGraph? oldFrameworkGraph,
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
  final SyncEngineConfig _config;
  final MergeContractLoader _mergeContractLoader;
  final ShardDeterminer _shardDeterminer;
  final LocalDocumentMerger _localDocumentMerger;
  final PhysicalTimestampFactory _physicalTimestampFactory;

  // Factory functions for configurable time and clock generation
  final HlcService _hlcService;

  CrdtDocumentManager({
    required Storage storage,
    required SyncEngineConfig config,
    required MergeContractLoader mergeContractLoader,
    required HlcService hlcService,
    required ShardDeterminer shardDeterminer,
    required LocalDocumentMerger localDocumentMerger,
    required PhysicalTimestampFactory physicalTimestampFactory,
  })  : _storage = storage,
        _config = config,
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
    IriTerm documentIri = primaryResourceIri.getDocumentIri();
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
        _computeIsGovernedBy(oldDocument, documentIri, _config, type);

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
    int?
        oldUpdatedAt, // For optimistic locking - use updatedAt (changes on every save)
  }) async {
    RdfGraph? oldDocument;
    RdfGraph? crdtDocument;
    RdfGraph? frameworkGraph;
    try {
      // Validate input parameters
      if (appData.isEmpty) {
        throw ArgumentError('Cannot save empty graph');
      }

      // Validate resource graph structure
      _validateResourceGraph(documentIri, resourceIri, type, appData);

      _log.fine(
          'Saving resource ${resourceIri.debug} to document ${documentIri.debug}');

      // 3. Generate latest clock
      final clock = _hlcService.createOrIncrementClock(
        oldFrameworkGraph,
        documentIri,
        physicalTime: physicalTime,
        logicalTime: logicalTime,
      );
      final physicalTimestamp = clock.physicalTime;

      // We use PhysicalTimestampFactory to get "now" for updatedAt (and createdAt if needed) because
      // this is about the time the document was created/updated in storage, where
      // the physical clock of the CRDT is about the time of the change itself.
      final updatedAtTimestamp = _physicalTimestampFactory();
      // 4. Detect property changes between old and new app graphs and generate CRDT metadata
      final (
        metadata: crdtMetadata,
        newBlankNodes: appBlankNodes,
        oldBlankNodes: oldAppBlankNodes
      ) = _localDocumentMerger.generateMetadata(
        documentIri,
        appData,
        oldAppData,
        oldFrameworkGraph,
        mergeContract,
        clock,
        appDataTypeIri: type,
      );
      final propertyChanges = crdtMetadata.propertyChanges;
      if (propertyChanges.isEmpty) {
        _log.info(
            'No property changes detected for ${resourceIri.debug}, skipping save');
        return null;
      }
      final createdAt = oldFrameworkGraph?.findSingleObject<LiteralTerm>(
              documentIri, SyncManagedDocument.crdtCreatedAt) ??
          LiteralTermExtensions.dateTime(updatedAtTimestamp);

      // Calculate new shards based on current appData
      // Use lenient mode for user-initiated saves - we proceed even if indices
      // haven't been synced yet. Missing shards will be self-healing on next sync.
      final (allShards, removed, missingGroupIndices, missingIndexDocuments) =
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

      // 5. Construct complete CRDT document with framework metadata
      final documentTriples = _constructCrdtDocument(
        documentIri,
        oldFrameworkGraph,
        crdtMetadata.statements,
        governedByFiles,
        resourceIri,
        type,
        createdAt,
        clock,
        appBlankNodes,
        allShards,
      );
      frameworkGraph = RdfGraph.fromTriples(documentTriples);
      final (metadata: frameworkMetadata, oldBlankNodes: _, newBlankNodes: _) =
          _localDocumentMerger.generateMetadata(
        documentIri,
        frameworkGraph,
        oldFrameworkGraph,
        oldFrameworkGraph,
        mergeContract,
        clock,
        appDataTypeIri: type,
        isFrameworkData: true, // Mark as framework data
      );
      // add framework property changes
      propertyChanges.addAll(frameworkMetadata.propertyChanges);

      // Add all framework metadata triples
      documentTriples.addNodes(documentIri, SyncManagedDocument.hasStatement,
          frameworkMetadata.statements);

      // And cleanup: remove any triples that are marked for removal, e.g. tombstones and statements that need to be removed eg. because their value re-occured.
      crdtMetadata.triplesToRemove.forEach(documentTriples.remove);
      frameworkMetadata.triplesToRemove.forEach(documentTriples.remove);

      // Add all app data triples
      documentTriples.addAll(appData.triples);

      crdtDocument = RdfGraph.fromTriples(documentTriples);

      // 6. Create document metadata for storage
      final documentMetadata = DocumentMetadata(
        ourPhysicalClock: physicalTimestamp,
        updatedAt: updatedAtTimestamp
            .millisecondsSinceEpoch, // Storage will update this
      );

      // 7. Save to storage atomically (document + metadata + property changes)
      // Use optimistic locking to prevent lost updates from concurrent modifications
      late final SaveDocumentResult saveResult;
      try {
        saveResult = await _storage.saveDocument(
          documentIri,
          type,
          crdtDocument,
          documentMetadata,
          propertyChanges,
          ifMatchUpdatedAt: oldUpdatedAt,
        );
      } on ConcurrentUpdateException {
        // concurrent update detected, will be retried by caller
        rethrow;
      } catch (e) {
        _log.severe(
            'Failed to save document ${documentIri.debug} to storage: $e');
        rethrow; // Don't emit hydration event if storage failed
      }

      _log.info(
          'Successfully saved document ${documentIri.debug} with ${propertyChanges.length} property changes');
      return (
        documentIri: documentIri,
        resourceIri: resourceIri,
        crdtDocument: crdtDocument,
        appData: appData,
        previousCursor: saveResult.previousCursor,
        currentCursor: saveResult.currentCursor,
        missingGroupIndices: missingGroupIndices,
        physicalTime: clock.physicalTime,
        updatedAt: updatedAtTimestamp.millisecondsSinceEpoch,
      );
    } on UnidentifiedBlankNodeException catch (e, stackTrace) {
      _log.severe(
          'Save operation failed for type ${type.debug}', e, stackTrace);
      final blankNode = e.blankNode;
      _throwIfUsedIn(stackTrace, "Old Document", oldDocument, blankNode);
      _throwIfUsedIn(stackTrace, "New App Data", appData, blankNode);
      _throwIfUsedIn(
          stackTrace, "New Framework Data", frameworkGraph, blankNode);
      _throwIfUsedIn(stackTrace, "New Document", crdtDocument, blankNode);
      rethrow;
    } catch (e, stackTrace) {
      _log.severe(
          'Save operation failed for type ${type.debug}', e, stackTrace);
      rethrow;
    }
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
