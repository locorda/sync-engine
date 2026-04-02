/// Main facade for the CRDT sync system.
library;

import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_core/src/crdt/crdt_types.dart';
import 'package:locorda_core/src/crdt_document_manager.dart';
import 'package:locorda_core/src/hlc_service.dart';
import 'package:locorda_core/src/index/group_index_subscription_manager.dart';
import 'package:locorda_core/src/index/index_config_base.dart';
import 'package:locorda_core/src/index/index_discovery.dart';
import 'package:locorda_core/src/index/index_manager.dart';
import 'package:locorda_core/src/index/index_parser.dart';
import 'package:locorda_core/src/index/index_rdf_generator.dart';
import 'package:locorda_core/src/index/shard_determiner.dart';
import 'package:locorda_core/src/index/shard_manager.dart';
import 'package:locorda_core/src/installation_service.dart'
    show InstallationService, InstallationIdFactory;
import 'package:locorda_core/src/local_document_merger.dart';
import 'package:locorda_core/src/mapping/framework_iri_generator.dart';
import 'package:locorda_core/src/mapping/merge_contract_loader.dart';
import 'package:locorda_core/src/mapping/recursive_rdf_loader.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/storage/document_save_service.dart';
import 'package:locorda_core/src/storage/storage_interface.dart' as storage;
import 'package:locorda_core/src/sync/pipeline/document_shard_reconciler.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_support.dart';
import 'package:locorda_core/src/sync/pipeline/content_index_resolver.dart';
import 'package:locorda_core/src/sync/pipeline/streaming_remote_sync_orchestrator.dart';
import 'package:locorda_core/src/sync/remote_document_merger.dart';
import 'package:locorda_core/src/sync/remote_sync_orchestrator.dart';
import 'package:locorda_core/src/sync/shard_document_generator.dart';
import 'package:locorda_core/src/sync/sync_function.dart';
import 'package:locorda_core/src/util/build_effective_config.dart';
import 'package:locorda_core/src/util/retry.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:locorda_rdf_jelly/jelly.dart';
import 'package:logging/logging.dart';
import 'package:rxdart/rxdart.dart';

final _log = Logger('StandardSyncEngine');

typedef IdentifiedGraph = (IriTerm id, RdfGraph graph);
typedef HydrationBatch = ({
  List<IdentifiedGraph> updates,
  List<IdentifiedGraph> deletions,
  String? cursor
});

/// Simple config service for testing that doesn't listen to remote changes.
class SimpleConfigService extends ConfigService {
  SimpleConfigService(super.initialConfig)
      : super(classicBackends: [], pipelineBackends: []);
}

class ConfigService {
  final BehaviorSubject<SyncEngineConfig> _configSubject;
  final SyncEngineConfig _initialConfig;
  final List<ClassicBackend> _classicBackends;
  final List<PipelineBackend> _pipelineBackends;
  final List<StreamSubscription> _remoteSubscriptions = [];
  bool _needsPrefetchAll = false;

  Stream<SyncEngineConfig> get configChanges => _configSubject.stream;
  SyncEngineConfig get currentConfig => _configSubject.value;

  ConfigService(
    SyncEngineConfig initialConfig, {
    required List<ClassicBackend> classicBackends,
    required List<PipelineBackend> pipelineBackends,
  })  : _configSubject =
            BehaviorSubject<SyncEngineConfig>.seeded(initialConfig),
        _initialConfig = initialConfig,
        _classicBackends = classicBackends,
        _pipelineBackends = pipelineBackends {
    _setupRemoteListeners();
  }

  /// Setup listeners for remote availability changes across all backends.
  void _setupRemoteListeners() {
    for (final backend in _classicBackends) {
      final subscription = backend.remotesChanged.listen((_) {
        _onRemotesChanged();
      });
      _remoteSubscriptions.add(subscription);
    }
    for (final backend in _pipelineBackends) {
      final subscription = backend.pipelineRemotesChanged.listen((_) {
        _onRemotesChanged();
      });
      _remoteSubscriptions.add(subscription);
    }

    // Check initial state
    _onRemotesChanged();
  }

  /// Handle remote availability changes.
  void _onRemotesChanged() {
    // Check if any available remote uses shard datasets
    // pipeline remotes do not communicate their storage model any more,
    // they are expected to "push" extra data into the pipeline, so this
    // setting is only for classic backends.
    final anyDatasetRemote = _classicBackends.any((backend) {
      return backend.remotes.any((remote) {
        // Remote must be available to be considered
        // We can't check availability synchronously here, but remotes list
        // only contains authenticated/configured remotes, so we can assume they're potentially available
        return remote.useShardDatasets;
      });
    });

    if (anyDatasetRemote != _needsPrefetchAll) {
      _needsPrefetchAll = anyDatasetRemote;
      final SyncEngineConfig _effectiveConfig;
      if (_needsPrefetchAll) {
        _log.info(
            'Dataset-based remote detected - adjusting RootResourceFetchPolicy to Prefetch() for all indices');
        _effectiveConfig = _adjustConfigForDatasets(_initialConfig);
      } else {
        _log.info('No dataset-based remotes - using original configuration');
        _effectiveConfig = _initialConfig;
      }
      _configSubject.add(_effectiveConfig);
      // Note: Config change takes effect on next sync cycle
      // Active sync operations continue with their original config
    }
  }

  /// Adjust configuration to enforce Prefetch policy for dataset compatibility.
  static SyncEngineConfig _adjustConfigForDatasets(SyncEngineConfig config) {
    final adjustedResources = config.resources.map((resource) {
      final adjustedIndices = resource.indices.map((index) {
        // Only FullIndex has rootResourceFetchPolicy that needs adjustment
        return switch (index) {
          FullIndexData(rootResourceFetchPolicy: final policy)
              when policy is! Prefetch =>
            () {
              _log.warning(
                  'Overriding RootResourceFetchPolicy for index ${index.localName} to Prefetch() for dataset compatibility');

              return index.copyWith(
                rootResourceFetchPolicy: RootResourceFetchPolicy.prefetch,
              );
            }(),
          _ => index, // GroupIndexData or already Prefetch - no change needed
        };
      }).toList();

      // Create new resource config with adjusted indices
      return resource.copyWith(indices: adjustedIndices);
    }).toList();

    return config.copyWith(
      resources: adjustedResources,
    );
  }

  Future<void> close() async {
    // Cancel remote listeners
    for (final subscription in _remoteSubscriptions) {
      await subscription.cancel();
    }
    _remoteSubscriptions.clear();
  }
}

/// Main facade for the locorda system.
///
/// Provides a simple, high-level API for offline-first applications with
/// optional Solid Pod synchronization. Handles RDF mapping, storage,
/// and sync operations transparently.
class StandardSyncEngine implements SyncEngine {
  final Storage _storage;
  final IndexManager _indexManager;
  final ConfigService _configService;
  final CrdtDocumentManager _crdtDocumentManager;
  final IriTranslator _iriTranslator;
  final GroupIndexGraphSubscriptionManager _groupIndexManager;
  final SyncManager _syncManager;
  final PhysicalTimestampFactory _physicalTimestampFactory;
  final IndexRdfGenerator _indexRdfGenerator;
  final List<Future<void> Function()> _closeFunctions;
  final Map<IriTerm, String> _groupIndexSubscriptionFingerprints = {};
  final Perflog _perflog;

  static final List<RdfBinaryGraphCodec> extraBinaryGraphCodecs = [jellyGraph];
  static final List<RdfBinaryDatasetCodec> extraBinaryDatasetCodecs = [jelly];

  /// Access the sync manager for manual sync triggering and status monitoring.
  SyncManager get syncManager => _syncManager;

  StandardSyncEngine._(
      {required Storage storage,
      required IndexManager indexManager,
      required ConfigService configService,
      required ResourceLocator resourceLocator,
      required CrdtDocumentManager crdtDocumentManager,
      required IndexRdfGenerator indexRdfGenerator,
      required PhysicalTimestampFactory physicalTimestampFactory,
      required SyncManager syncManager,
      required List<Backend> backends,
      required Perflog perflog,
      List<Future<void> Function()> closeFunctions = const []})
      : _storage = storage,
        _indexManager = indexManager,
        _configService = configService,
        _groupIndexManager = GroupIndexGraphSubscriptionManager(
          configService: configService,
        ),
        _iriTranslator = IriTranslator.forConfig(
          resourceLocator: resourceLocator,
          resourceConfigs: configService.currentConfig.resources,
        ),
        _crdtDocumentManager = crdtDocumentManager,
        _syncManager = syncManager,
        _indexRdfGenerator = indexRdfGenerator,
        _physicalTimestampFactory = physicalTimestampFactory,
        _perflog = perflog,
        _closeFunctions = closeFunctions;

  SyncEngineConfig get _effectiveConfig => _configService.currentConfig;

  IndexInstanceSyncState _normalizeSnapshotWithConfiguredRemotes(
    IndexInstanceSyncState snapshot,
    Set<RemoteId> configuredRemotes,
  ) {
    final perRemote = Map<RemoteId, RemoteSyncEntry>.from(
      snapshot.perRemote,
    );

    for (final remoteId in configuredRemotes) {
      perRemote.putIfAbsent(
        remoteId,
        () => RemoteSyncEntry(
          remoteId: remoteId,
          phase: RemoteSyncPhase.notSynced,
        ),
      );
    }

    return IndexInstanceSyncState(
      indexInstanceIri: snapshot.indexInstanceIri,
      perRemote: perRemote,
    );
  }

  Future<void> _autoSubscribeGroupIndicesOnSave(
      List<ResolvedGroupIndex> resolvedGroupIndices) async {
    if (resolvedGroupIndices.isEmpty) {
      return;
    }

    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    final uniqueByIndexIri = <IriTerm, ResolvedGroupIndex>{
      for (final resolved in resolvedGroupIndices)
        resolved.groupIndexIri: resolved,
    };

    for (final resolved in uniqueByIndexIri.values) {
      await _saveGroupIndexSubscriptionIfNeeded(
        groupIndexIri: resolved.groupIndexIri,
        groupIndexTemplateIri: resolved.templateIri,
        indexedType: resolved.typeIri,
        rootResourceFetchPolicy: resolved.rootResourceFetchPolicy,
        createdAtMs: now,
      );
    }
  }

  Future<void> _saveGroupIndexSubscription({
    required IriTerm groupIndexIri,
    required IriTerm groupIndexTemplateIri,
    required IriTerm indexedType,
    required RootResourceFetchPolicy rootResourceFetchPolicy,
    required int createdAtMs,
  }) {
    return _storage.saveGroupIndexSubscription(
      groupIndexIri: groupIndexIri,
      groupIndexTemplateIri: groupIndexTemplateIri,
      indexedType: indexedType,
      rootResourceFetchPolicy: rootResourceFetchPolicy,
      createdAt: createdAtMs,
    );
  }

  String _groupIndexSubscriptionFingerprint({
    required IriTerm groupIndexTemplateIri,
    required IriTerm indexedType,
    required RootResourceFetchPolicy rootResourceFetchPolicy,
  }) {
    final policyFingerprint = switch (rootResourceFetchPolicy) {
      Prefetch() => 'prefetch',
      OnRequest() => 'onRequest',
      PrefetchFiltered(:final filterPredicate, :final acceptedObjectValues) =>
        () {
          final values = acceptedObjectValues
              .map((obj) => switch (obj) {
                    IriTerm(:final value) => 'iri:$value',
                    LiteralTerm(
                      :final value,
                      :final datatype,
                      :final language
                    ) =>
                      'lit:$value|${datatype.value}|${language ?? ''}',
                    _ => throw UnsupportedError(
                        'Unsupported RdfObject in PrefetchFiltered fingerprint: ${obj.runtimeType}')
                  })
              .toList()
            ..sort();
          return 'prefetchFiltered:${filterPredicate.value}:${values.join(',')}';
        }(),
    };

    return '${groupIndexTemplateIri.value}|${indexedType.value}|$policyFingerprint';
  }

  Future<void> _saveGroupIndexSubscriptionIfNeeded({
    required IriTerm groupIndexIri,
    required IriTerm groupIndexTemplateIri,
    required IriTerm indexedType,
    required RootResourceFetchPolicy rootResourceFetchPolicy,
    required int createdAtMs,
  }) async {
    final fingerprint = _groupIndexSubscriptionFingerprint(
      groupIndexTemplateIri: groupIndexTemplateIri,
      indexedType: indexedType,
      rootResourceFetchPolicy: rootResourceFetchPolicy,
    );

    if (_groupIndexSubscriptionFingerprints[groupIndexIri] == fingerprint) {
      return;
    }

    await _saveGroupIndexSubscription(
      groupIndexIri: groupIndexIri,
      groupIndexTemplateIri: groupIndexTemplateIri,
      indexedType: indexedType,
      rootResourceFetchPolicy: rootResourceFetchPolicy,
      createdAtMs: createdAtMs,
    );

    _groupIndexSubscriptionFingerprints[groupIndexIri] = fingerprint;
  }

  Future<void> _configureGroupIndexSubscription({
    required String indexName,
    required RdfGraph groupKeyGraph,
    RootResourceFetchPolicy? rootResourceFetchPolicy,
  }) async {
    final (resourceConfig, groupIndexTemplateIri, iris, indexConfig) =
        await _resolveGroupIndexIris(
            groupKeyGraph: groupKeyGraph, indexName: indexName);

    // Resolve policy: explicit parameter overrides config, which overrides default
    final effectivePolicy =
        rootResourceFetchPolicy ?? indexConfig.rootResourceFetchPolicy;

    for (final iri in iris) {
      await _saveGroupIndexSubscriptionIfNeeded(
        groupIndexIri: iri,
        groupIndexTemplateIri: groupIndexTemplateIri,
        indexedType: resourceConfig.typeIri,
        rootResourceFetchPolicy: effectivePolicy,
        createdAtMs: _physicalTimestampFactory().millisecondsSinceEpoch,
      );
    }
  }

  Future<(ResourceConfigData, IriTerm, Iterable<IriTerm>, GroupIndexData)>
      _resolveGroupIndexIris({
    required String indexName,
    required RdfGraph groupKeyGraph,
  }) async {
    final (resourceConfig, indexConfig) =
        _effectiveConfig.findGroupIndexConfig(indexName)!;
    final groupIndexTemplateIri =
        _indexRdfGenerator.generateGroupIndexTemplateIri(
      indexConfig,
      resourceConfig.typeIri,
    );
    final groupIdentifiers =
        await _groupIndexManager.getGroupIdentifiers(indexName, groupKeyGraph);

    final iris = groupIdentifiers
        .map((g) => _indexRdfGenerator.generateGroupIndexIri(
              groupIndexTemplateIri,
              g,
            ))
        .toList(growable: false);
    return (resourceConfig, groupIndexTemplateIri, iris, indexConfig);
  }

  Future<IriTerm> _resolveSingleGroupIndexIri({
    required String indexName,
    required RdfGraph groupKeyGraph,
  }) async {
    final (_, _, iris, _) = await _resolveGroupIndexIris(
        indexName: indexName, groupKeyGraph: groupKeyGraph);
    final groupIdentifierList = iris.toList(growable: false);
    if (groupIdentifierList.isEmpty) {
      throw StateError(
          'No group identifiers were generated for index "$indexName".');
    }
    if (groupIdentifierList.length > 1) {
      throw StateError('''
watchGroupIndexSyncState watches exactly one group instance, but the provided \
groupKeyGraph yielded ${groupIdentifierList.length} group identifiers for index "$indexName".

This happens when a grouping property is multi-valued (e.g. multiple tags on a document). \
Pass a groupKeyGraph with a single value per grouping property.

To observe multiple groups, call watchGroupIndexSyncState once per group and combine \
the streams yourself.''');
    }
    return groupIdentifierList.single;
  }

  @override
  Stream<IndexInstanceSyncState> watchGroupIndexSyncState({
    required String indexName,
    required RdfGraph groupKeyGraph,
  }) {
    return Rx.fromCallable(
      () => _resolveSingleGroupIndexIri(
        indexName: indexName,
        groupKeyGraph: groupKeyGraph,
      ),
    ).switchMap((groupIndexIri) {
      return Rx.combineLatest2<IndexInstanceSyncState, Set<RemoteId>,
          IndexInstanceSyncState>(
        _storage.watchIndexInstanceSyncState(groupIndexIri),
        _storage.watchConfiguredRemoteIds(),
        (snapshot, configuredRemotes) =>
            _normalizeSnapshotWithConfiguredRemotes(
                snapshot, configuredRemotes),
      );
    });
  }

  @override
  Stream<IndexInstanceSyncState> watchSyncState({
    required IriTerm typeIri,
    String? indexName,
  }) {
    final resourceConfig = _effectiveConfig
        .getResourceConfig(typeIri); // Validate typeIri and throw if not found
    final fullIndex = indexName == null
        ? resourceConfig.indices.whereType<FullIndexData>().single
        : resourceConfig.getIndexByName(indexName) as FullIndexData;

    final fullIndexIri = _indexRdfGenerator.generateFullIndexIri(
      fullIndex,
      typeIri,
    );

    return Rx.combineLatest2<IndexInstanceSyncState, Set<RemoteId>,
        IndexInstanceSyncState>(
      _storage.watchIndexInstanceSyncState(fullIndexIri),
      _storage.watchConfiguredRemoteIds(),
      (snapshot, configuredRemotes) =>
          _normalizeSnapshotWithConfiguredRemotes(snapshot, configuredRemotes),
    );
  }

  @override
  @override
  Future<void> ensureGroupIndexSubscription({
    required String indexName,
    required RdfGraph groupKeyGraph,
    RootResourceFetchPolicy? rootResourceFetchPolicy,
    bool triggerSync = true,
  }) async {
    await _configureGroupIndexSubscription(
      indexName: indexName,
      groupKeyGraph: groupKeyGraph,
      rootResourceFetchPolicy: rootResourceFetchPolicy,
    );

    if (!triggerSync) {
      return;
    }

    final currentState = await watchGroupIndexSyncState(
      indexName: indexName,
      groupKeyGraph: groupKeyGraph,
    ).first;

    if (!currentState.hasCompletedInitialSync) {
      unawaited(syncManager.sync(trigger: SyncTrigger.dataChange));
    }
  }

  @override
  Future<void> ensureGroupIndexSynced({
    required String indexName,
    required RdfGraph groupKeyGraph,
    RootResourceFetchPolicy? rootResourceFetchPolicy,
  }) async {
    await ensureGroupIndexSubscription(
      indexName: indexName,
      groupKeyGraph: groupKeyGraph,
      rootResourceFetchPolicy: rootResourceFetchPolicy,
      triggerSync: true,
    );

    final state = await watchGroupIndexSyncState(
      indexName: indexName,
      groupKeyGraph: groupKeyGraph,
    ).firstWhere(
      (snapshot) =>
          snapshot.hasCompletedInitialSync || snapshot.hasInitialSyncError,
    );

    if (state.hasInitialSyncError) {
      throw IndexInstanceSyncFailedException(
        'Initial sync failed for one or more remotes.',
        lastState: state,
      );
    }
  }

  /// Set up the CRDT sync system with resource-focused configuration.
  ///
  /// This is the main entry point for applications. Creates a fully
  /// configured sync system that works locally by default.
  ///
  /// Configuration is organized around resources (Note, Category, etc.)
  /// with their paths, CRDT mappings, and indices all defined together.
  ///
  /// Throws [SyncConfigValidationException] if the configuration is invalid.
  static Future<SyncEngine> create({
    required List<Backend> backends,
    required Storage storage,
    required SyncEngineConfig config,
    PhysicalTimestampFactory? physicalTimestampFactory,
    InstallationIdFactory? installationIdFactory,
    IriTermFactory? iriFactory,
    RdfCore? rdfCore,
    http.Client? httpClient,
    Fetcher? fetcher,
    Iterable<String>? mappingBootstrapSources,
    Perflog? perflog,
  }) async {
    rdfCore ??= RdfCore.withStandardCodecs(
        additionalBinaryDatasetCodecs: extraBinaryDatasetCodecs,
        additionalBinaryGraphCodecs: extraBinaryGraphCodecs);
    httpClient ??= http.Client();
    fetcher ??= HttpFetcher(httpClient: httpClient);
    iriFactory ??= IriTerm.validated;
    perflog ??= Perflog.root();

    final timestampFactory =
        physicalTimestampFactory ?? defaultPhysicalTimestampFactory;
    final (classicBackends, pipelineBackends) = backends
        .fold((<ClassicBackend>[], <PipelineBackend>[]), (acc, backend) {
      switch (backend) {
        // priority to PipelineBackend
        case PipelineBackend():
          acc.$2.add(backend);
        case ClassicBackend():
          acc.$1.add(backend);
      }
      return acc;
    });
    // Automatically add configuration for Framework-Owned resources
    final configService = ConfigService(
      buildEffectiveConfig(config),
      classicBackends: classicBackends,
      pipelineBackends: pipelineBackends,
    );

    // Validate configuration before proceeding
    final configValidationResult =
        SyncEngineConfigValidator().validate(configService.currentConfig);

    // Throw if any validation failed
    configValidationResult.throwIfInvalid();

    // Initialize storage
    await storage.initialize();

    final localResourceLocator =
        LocalResourceLocator(iriTermFactory: iriFactory);
    // Initialize installation service
    final installationService = await InstallationService.create(
      storage: storage,
      resourceLocator: localResourceLocator,
      installationIdFactory: installationIdFactory,
      iriTermFactory: iriFactory,
      physicalTimestampFactory: timestampFactory,
    );

    // Create HlcService with installation IRI and localId
    final hlcService = HlcService(
      installationLocalId: installationService.installationLocalId,
      physicalTimestampFactory: timestampFactory,
    );
    final crdtTypeRegistry = CrdtTypeRegistry.forStandardTypes();

    final onlineLoader = StandardMergeContractLoader(
      RecursiveRdfLoader(
          fetcher: StandardRdfGraphFetcher(fetcher: fetcher, rdfCore: rdfCore),
          iriFactory: iriFactory),
      crdtTypeRegistry,
    );

    final bootstrapLoader = StandardMergeContractLoader(
        RecursiveRdfLoader(
            fetcher: BootstrapRdfGraphFetcher(
              rdfCore: rdfCore,
              iriFactory: iriFactory,
              bootstrapSources: mappingBootstrapSources,
              onlineFetcher:
                  StandardRdfGraphFetcher(fetcher: fetcher, rdfCore: rdfCore),
            ),
            iriFactory: iriFactory),
        crdtTypeRegistry);

    // TODO: the HttpRdfGraphFetcher should be db-cached (storage can optionally implement MergeContractCache which can be used here for persistent caching)
    final mergeContractLoader = CachingMergeContractLoader(
      onlineLoader,
      bootstrapInner: bootstrapLoader,
    );

    final shardManager = const ShardManager();

    final indexRdfGenerator = IndexRdfGenerator(
        resourceLocator: localResourceLocator, shardManager: shardManager);

    final indexParser = IndexParser(
        knownConfig: configService.currentConfig,
        rdfGenerator: indexRdfGenerator);

    final indexDiscovery = IndexDiscovery(
      storage: storage,
      parser: indexParser,
      rdfGenerator: indexRdfGenerator,
      configService: configService,
    );

    final shardDeterminer = ShardDeterminer(
      storage: storage,
      rdfGenerator: indexRdfGenerator,
      shardManager: shardManager,
      indexDiscovery: indexDiscovery,
    );

    final frameworkIriGenerator =
        FrameworkIriGenerator(iriTermFactory: iriFactory);

    final localDocumentMerger = LocalDocumentMerger(
      frameworkIriGenerator: frameworkIriGenerator,
      crdtTypeRegistry: crdtTypeRegistry,
    );

    final documentSaveService = DocumentSaveService(storage);

    final crdtDocumentManager = CrdtDocumentManager(
      storage: storage,
      documentSaveService: documentSaveService,
      configService: configService,
      shardDeterminer: shardDeterminer,
      mergeContractLoader: mergeContractLoader,
      localDocumentMerger: localDocumentMerger,
      hlcService: hlcService,
      physicalTimestampFactory: timestampFactory,
    );

    // Initialize indices after installation document is created
    final indexManager = IndexManager(
      crdtDocumentManager: crdtDocumentManager,
      rdfGenerator: indexRdfGenerator,
      storage: storage,
      installationIri: installationService.installationIri,
      configService: configService,
      indexDiscovery: indexDiscovery,
      resourceLocator: localResourceLocator,
      shardDeterminer: shardDeterminer,
    );

    await indexManager.initializeIndices();

    final remoteDocumentMerger = RemoteDocumentMerger(
      storage: storage,
      hlcService: hlcService,
      crdtTypeRegistry: crdtTypeRegistry,
      frameworkIriGenerator: frameworkIriGenerator,
    );
    final shardDocumentGenerator = ShardDocumentGenerator(
      storage: storage,
      documentManager: crdtDocumentManager,
      indexManager: indexManager,
    );
    final remoteSyncOrchestratorFactory = (
      RemoteSyncStorage remoteSyncStorage,
      RemoteId remoteId, {
      required bool useShardDatasets,
    }) =>
        RemoteSyncOrchestrator(
          remoteSyncStorage: remoteSyncStorage,
          remoteId: remoteId,
          storage: storage,
          documentSaveService: documentSaveService,
          merger: remoteDocumentMerger,
          indexRdfGenerator: indexRdfGenerator,
          indexManager: indexManager,
          shardDeterminer: shardDeterminer,
          hlcService: hlcService,
          mergeContractLoader: mergeContractLoader,
          localDocumentMerger: localDocumentMerger,
          shardDocumentGenerator: shardDocumentGenerator,
          physicalTimestampFactory: timestampFactory,
          useShardDatasets: useShardDatasets,
          perflog: perflog!,
        );
    final documentShardReconciler = DocumentShardReconciler(
      shardDeterminer: shardDeterminer,
      localDocumentMerger: localDocumentMerger,
      hlcService: hlcService,
      mergeContractLoader: mergeContractLoader,
    );
    final streamingOrchestratorFactory = (
      PipelineRemoteSyncStorage pipelineSupport,
      RemoteId remoteId,
      SyncEngineConfig effectiveConfig,
    ) =>
        StreamingRemoteSyncOrchestrator(
          storage: storage,
          documentSaveService: documentSaveService,
          remoteId: remoteId,
          pipelineSupport: pipelineSupport,
          rdfCore: rdfCore!,
          merger: remoteDocumentMerger,
          mergeContractLoader: mergeContractLoader,
          reconciler: documentShardReconciler,
          indexManager: indexManager,
          documentManager: crdtDocumentManager,
          shardDocGen: shardDocumentGenerator,
          indexRdfGenerator: indexRdfGenerator,
          indexDiscovery: indexDiscovery,
          shardDeterminer: shardDeterminer,
          indexResolver: ContentIndexResolver(
            storage: storage,
            indexRdfGenerator: indexRdfGenerator,
            remoteId: remoteId,
            config: effectiveConfig,
          ),
        );
    final syncFunction = SyncFunction(
      storage: storage,
      configService: configService,
      shardDocumentGenerator: shardDocumentGenerator,
      classicBackends: classicBackends,
      pipelineBackends: pipelineBackends,
      remoteSyncOrchestratorFactory: remoteSyncOrchestratorFactory,
      streamingOrchestratorFactory: streamingOrchestratorFactory,
      perflog: perflog,
    );
    final syncManager = StandardSyncManager(
        syncFunction: (DateTime syncTime) => (perflog ?? Perflog.disabled)
            .measure('syncFunction', () => syncFunction(syncTime)),
        configService: configService,
        physicalTimestampFactory: timestampFactory);

    final sync = StandardSyncEngine._(
        storage: storage,
        indexManager: indexManager,
        configService: configService,
        resourceLocator: localResourceLocator,
        crdtDocumentManager: crdtDocumentManager,
        indexRdfGenerator: indexRdfGenerator,
        physicalTimestampFactory: timestampFactory,
        syncManager: syncManager,
        backends: backends,
        perflog: perflog,
        closeFunctions: backends.map((b) => b.dispose).toList());

    // installation documents might be organized in indices, so we need to use graph sync instead of crdtDocumentManager directly
    await installationService.ensureDocumentSaved(sync);

    return sync;
  }

  /// Save an object with CRDT processing.
  ///
  /// Stores the object locally and triggers sync if connected to Solid Pod.
  /// Application state is updated via the hydration stream - repositories should
  /// listen to hydrateStream() to receive updates.
  ///
  /// Process:
  /// 1. CRDT processing (merge with existing, clock increment)
  /// 2. Store locally in sync system
  /// 3. Hydration stream automatically emits update
  /// 4. Schedule async Pod sync
  Future<void> save(IriTerm type, RdfGraph appData) async {
    await _saveSingle(type, appData);
  }

  Future<void> _saveSingle(IriTerm type, RdfGraph appData) async {
    // 1. Translate external IRIs to internal format if documentIriTemplate is configured
    final internalAppData = _iriTranslator.translateGraphToInternal(appData);

    // 2. Extract resource IRI to determine shards
    final resourceIri = internalAppData.getIdentifier(type);
    if (!LocalResourceLocator.isLocalIri(resourceIri)) {
      throw ArgumentError('''
Cannot save resource with non-local IRI $resourceIri. Only local IRIs are supported for save(). 

Use the 'documentIriTemplate' property of the resource configuration to configure automatic IRI translation from your IRI to the internal format on save().
''');
    }

    // 4. save (with CRDT processing, diffing etc)
    final saved = await retryOnConflict(
        () => _crdtDocumentManager.save(type, internalAppData),
        debugOperationName: 'save for ${resourceIri.debug}');
    if (saved == null) {
      // nothing changed, nothing to do
      return;
    }

    await _autoSubscribeGroupIndicesOnSave(saved.resolvedGroupIndices);

    // 5. Update indices
    await _indexManager.updateIndices(
      document: saved.crdtDocument,
      documentIri: saved.documentIri,
      physicalTime: saved.physicalTime,
      resourceTypeIri: type,
      updatedAt: saved.updatedAt,
      resolvedGroupIndices: saved.resolvedGroupIndices,
    );
  }

  Future<void> _saveAllSequential(
      List<(IriTerm type, RdfGraph appData)> items) async {
    for (final (type, appData) in items) {
      await _saveSingle(type, appData);
    }
  }

  @override
  Future<void> saveAll(List<(IriTerm type, RdfGraph appData)> items) async {
    return _perflog.measure('saveAll', () async {
      await _storage.inTransaction(() => _saveAllSequential(items));
    }, args: [
      'count=${items.length}',
      if (items.isNotEmpty) 'lastType=${items.last.$1.value.split('/').last}',
    ]);
  }

  /// Ensures a resource is available locally, fetching it from the remote source if necessary.
  ///
  /// This method guarantees that after its successful completion, the requested
  /// resource will exist in the local database and be managed by the sync system.
  /// It follows a "offline-first" approach.
  ///
  /// The process is as follows:
  /// 1. It first attempts to retrieve the item from the local database using the
  ///    provided [loadFromLocal] function.
  /// 2. If the item is found locally, it is returned immediately.
  /// 3. If the item is not found locally, this method triggers a fetch from the
  ///    remote Solid Pod.
  /// 4. Once fetched, the item is processed and inserted into the local database
  ///    via the standard hydration stream, which in turn makes it available to the
  ///    rest of the application.
  /// 5. The method then returns the newly fetched and stored item.
  ///
  /// This is the primary method repositories should use for on-demand loading of
  /// individual resources that may not be part of an eagerly synced group. It
  /// abstracts away all the complexity of network requests, caching, and state
  /// management.
  ///
  /// Throws a [TimeoutException] if the remote fetch takes too long.
  ///
  ///
  /// #### Parameters:
  ///   - [id]: The unique identifier of the resource to ensure is available.
  ///   - [loadFromLocal]: A callback function that takes the resource `id` and
  ///     is responsible for loading it from the local application database.
  ///
  /// #### Returns:
  /// A `Future` that completes with the resource of type [T] once it is available
  /// locally. Returns `null` if the resource cannot be found either locally or
  /// remotely, or if the request times out.
  ///
  /// #### Example:
  ///
  /// ```dart
  /// // Inside a repository class
  ///
  /// Future<Note?> getNoteById(String noteId) async {
  ///   return await _syncSystem.ensure<Note>(
  ///     noteId,
  ///     loadFromLocal: (id) async {
  ///       final driftNote = await _noteDao.getNoteById(id);
  ///       return driftNote != null ? _noteFromDrift(driftNote) : null;
  ///     },
  ///   );
  /// }
  /// ```
  Future<RdfGraph?> ensure(IriTerm typeIri, IriTerm localIri,
      {required Future<RdfGraph?> Function(IriTerm localIri) loadFromLocal,
      Duration? timeout = const Duration(seconds: 15),
      bool skipInitialFetch = false}) async {
    // 1. First, try to load from the local database.
    final localItem = skipInitialFetch ? null : await loadFromLocal(localIri);
    if (localItem != null) {
      return localItem;
    }

    // TODO: properly implement remote fetch with pending fetch tracking
    // TODO: check with fetch strategy - if fetch is prefetch, we can return a 404
    // immediately since the item must be present through sync - but note that
    // it would be a severe error if an ite is in the index entries, in prefetch mode, but not present in the documents.
/*
Check with https://g.co/gemini/share/60e9b2d3036e for the details

    // 2. If not found, check if a fetch is already in progress.
    if (_pendingFetches.containsKey(id)) {
      return (await _pendingFetches[id]!.future) as T?;
    }

    // 3. If not, initiate a new fetch.
    final completer = Completer<T?>();
    _pendingFetches[id] = completer;

    // 4. Trigger the remote fetch in the background.
    // (This reuses the logic from the previous proposal)
    _fetchAndEmit<T>(id);

    // 5. Return the future, which completes when the item arrives.
    return completer.future.timeout(const Duration(seconds: 15), onTimeout: () {
      _pendingFetches.remove(id);
      // Return null or throw a custom exception on timeout.
      return null;
    });

    */
    return null;
  }

  /// Delete a document with CRDT processing.
  ///
  /// This performs document-level deletion, marking the entire document as deleted
  /// and affecting all resources contained within, following CRDT semantics.
  /// Application state is updated via the hydration stream - repositories should
  /// listen to hydrateStream() to receive deletion notifications.
  ///
  /// Process:
  /// 1. Add crdt:deletedAt timestamp to document
  /// 2. Perform universal emptying (remove semantic content, keep framework metadata)
  /// 3. Store updated document in sync system
  /// 4. Hydration stream automatically emits deletion (via Drift's reactive queries)
  /// 5. Schedule async Pod sync
  Future<void> deleteDocument(IriTerm typeIri, IriTerm externalIri) async {
    // Translate external IRI to internal format
    // ignore: unused_local_variable
    final internalIri = _iriTranslator.externalToInternal(externalIri);

    // ignore: unused_local_variable
    final resourceConfig = _effectiveConfig.getResourceConfig(typeIri);

    // TODO: Implement proper CRDT deletion processing:
    // 1. Load existing document
    // 2. Add crdt:deletedAt timestamp
    // 3. Perform universal emptying (remove semantic content, keep framework metadata)
    // 4. Save to storage (this will trigger Drift's watch() to emit updates automatically)
    // 5. Update indices accordingly

    // TODO: universal emptying **must** preserve the primaryTopic relationship
    // to ensure the resource IRI remains known for hydration streams
    throw UnimplementedError('deleteDocument not yet fully implemented');
  }

  @override
  Future<void> deleteDocuments(
    IriTerm typeIri,
    Iterable<IriTerm> externalIris,
  ) async {
    for (final externalIri in externalIris) {
      await deleteDocument(typeIri, externalIri);
    }
  }

  /// Hydrates resources of the specified type using a reactive stream.
  ///
  /// Returns a stream of [HydrationBatch]es containing updates, deletions,
  /// and cursor information.
  ///
  /// ## Without Index (indexName == null)
  /// Hydrates complete resource documents:
  /// - Loads all existing documents in batches (bounded by [initialBatchSize])
  /// - Switches to reactive mode for ongoing changes (via Drift's watch())
  /// - Orders documents by updatedAt ascending for consistent processing
  /// - Emits (primaryTopicIri, appGraph) for each resource
  ///
  /// ## With Index (indexName != null)
  /// Hydrates lightweight index entries from the specified index:
  /// - Loads index entries in batches (bounded by [initialBatchSize])
  /// - Switches to reactive mode for ongoing changes
  /// - **Entry-level change tracking**: Only changed entries are re-emitted,
  ///   not entire shards. Uses progressive cursor tracking to minimize overhead.
  /// - Extracts entries with indexed properties only (not full resources)
  /// - Emits (resourceIri, entryGraph) for each indexed item
  /// - For GroupIndex: Automatically handles subscription changes and loads
  ///   historical data for newly subscribed groups
  ///
  /// ## Performance Characteristics
  /// - **Batch Loading Phase**: Controlled by [initialBatchSize], loads existing
  ///   data in configurable chunks to avoid memory spikes
  /// - **Reactive Phase**: Only emits entries that have actually changed since
  ///   the last emission, using entry-level timestamps for efficient filtering
  /// - **Memory Footprint**: Minimal overhead (one cursor int per active stream)
  ///
  /// The caller is responsible for:
  /// - Providing the current cursor position via [cursor]
  /// - Processing updates and deletions from the batch
  /// - Persisting cursor updates for resume capability
  ///
  Stream<HydrationBatch> hydrateStream({
    required IriTerm typeIri,
    String? indexName,
    String? cursor,
    int initialBatchSize = 100,
  }) async* {
    // Validate configuration
    final resourceConfig = _effectiveConfig.getResourceConfig(typeIri);
    if (indexName == null) {
      yield* _hydrateRootResourceStream(
        typeIri: typeIri,
        cursor: cursor,
        initialBatchSize: initialBatchSize,
      );
    } else {
      // Index-specific hydration
      final indexConfig = resourceConfig.getIndexByName(indexName);

      // Parse cursor format: "<millis-since-epoch>@<indexSetVersionId>"
      // e.g., "1697198445123@42"
      // If no @ present, assume just timestamp with no index set version tracking
      final (cursorTimestamp, cursorIndexSetVersionId) = _parseCursor(cursor);
      final startCursor = cursorTimestamp ?? 0;
      switch (indexConfig) {
        case GroupIndexData _:
          // For GroupIndex: Use reactive subscriptions that automatically rebuild the stream
          // when subscriptions change.
          final templateIri = _indexRdfGenerator.generateGroupIndexTemplateIri(
              indexConfig, typeIri);
          // Reactive approach: Watch subscription changes and rebuild the entry stream
          yield* _storage
              .watchSubscribedGroupIndexIris(templateIri)
              .switchMap((indexIris) => _doHydrateIndexEntryStream(
                    indexName,
                    indexIris,
                    startCursor,
                    useIndexSetVersionId: true,
                    cursorIndexSetVersionId: cursorIndexSetVersionId,
                    initialBatchSize: initialBatchSize,
                  ));
        case FullIndexData _: // FullIndex: there is just a single index
          final indexIri =
              _indexRdfGenerator.generateFullIndexIri(indexConfig, typeIri);
          yield* _doHydrateIndexEntryStream(
            indexName,
            {indexIri},
            startCursor,
            useIndexSetVersionId: false,
            initialBatchSize: initialBatchSize,
          );
      }
    }
  }

  (int? cursorTimestamp, int? setVersionId) _parseCursor(String? cursor) {
    // Parse cursor format: "<millis-since-epoch>@<setVersionId>"
    // e.g., "1697198445123@42"
    // If no @ present, assume old format (just timestamp) with no version tracking
    int? cursorTimestamp;
    int? cursorSetVersionId;
    if (cursor != null && cursor.isNotEmpty) {
      final parts = cursor.split('@');
      cursorTimestamp = int.tryParse(parts[0]);
      if (cursorTimestamp == null) {
        _log.warning(
            'Invalid cursor timestamp: ${parts[0]}, starting from beginning.');
      }
      if (parts.length > 1) {
        cursorSetVersionId = int.tryParse(parts[1]);
      }
    }
    return (cursorTimestamp, cursorSetVersionId);
  }

  /// Formats a cursor string from a timestamp and optional set version ID
  String _formatCursor(int timestamp, int? setVersionId) {
    return setVersionId != null ? '$timestamp@$setVersionId' : '$timestamp';
  }

  Stream<HydrationBatch> _doHydrateIndexEntryStream(
    String indexName,
    Set<IriTerm> indexIris,
    int startCursor, {
    bool useIndexSetVersionId = false,
    int? cursorIndexSetVersionId,
    required int initialBatchSize,
  }) async* {
    int? indexSetVersionId;
    // Track the last cursor emitted from batch loading
    int lastEmittedCursor = startCursor;

    // If useIndexSetVersionId is true, we need to associate the indexIris with a set version
    // to track which indices we query against. This also means that the set version
    // will be included in the actual (string) cursor we emit
    if (useIndexSetVersionId) {
      if (indexIris.isEmpty) {
        _log.warning(
            'No subscriptions for GroupIndex $indexName, emitting empty stream.');
        yield (
          updates: <IdentifiedGraph>[],
          deletions: <IdentifiedGraph>[],
          cursor: startCursor.toString()
        );
        return;
      }
      var now = _physicalTimestampFactory().millisecondsSinceEpoch;
      // Create/get set version for current subscriptions
      indexSetVersionId = await _storage.ensureIndexSetVersion(
        indexIris: indexIris,
        createdAt: now,
      );

      // Determine which index IRIs are new vs. old based on cursor
      final cursorIndexIris = cursorIndexSetVersionId == null
          ? const <IriTerm>{}
          : await _storage.getIndexIrisForVersion(cursorIndexSetVersionId);

      final newIndexIris = indexIris.difference(cursorIndexIris);

      final hasNewIndices = newIndexIris.isNotEmpty;

      // Phase 1a: Load historical data for new indices (0 → startCursor)
      if (hasNewIndices && startCursor > 0) {
        _log.info(
            'Loading historical data for ${newIndexIris.length} new indices up to cursor $startCursor');

        final result = _loadExistingEntriesAsStream(
          newIndexIris,
          indexSetVersionId,
          fromCursor: 0,
          toCursor: startCursor,
          initialBatchSize: initialBatchSize,
        );
        yield* result.stream;
        lastEmittedCursor = await result.lastCursor;
      }
    }

    // Phase 1b: Load current data for all subscriptions (from startCursor)
    final result = _loadExistingEntriesAsStream(
      indexIris,
      indexSetVersionId,
      fromCursor: lastEmittedCursor,
      initialBatchSize: initialBatchSize,
    );
    yield* result.stream;
    lastEmittedCursor = await result.lastCursor;

    // Phase 2: Switch to reactive watch for ongoing changes.
    // Cursor-reset wrapper prevents the Drift bg isolate from re-scanning an
    // ever-growing window of already-processed entries on every re-execution.
    yield* _withCursorReset(
      createWatch: (watchCursor) {
        final ts = watchCursor != null
            ? int.tryParse(watchCursor.split('@').first) ?? lastEmittedCursor
            : lastEmittedCursor;
        return _storage
            .watchIndexEntries(indexIris: indexIris, cursorTimestamp: ts)
            .where((entries) => entries.isNotEmpty)
            .map((entries) => _convertIndexEntriesToBatch(
                entries, entries.last.updatedAt, indexSetVersionId));
      },
      initialCursor: _formatCursor(lastEmittedCursor, indexSetVersionId),
    );
  }

  /// Streams index entries in batches and returns the last emitted cursor.
  ///
  /// Returns a record containing:
  /// - stream: The stream of hydration batches
  /// - lastCursor: A future that completes with the last cursor emitted
  ///
  /// This allows callers to know where the batch loading ended, which is
  /// necessary to correctly position the cursor for the reactive watch phase.
  ({Stream<HydrationBatch> stream, Future<int> lastCursor})
      _loadExistingEntriesAsStream(
          Set<IriTerm> indexIris, int? indexSetVersionId,
          {required int fromCursor,
          int? toCursor,
          required int initialBatchSize}) {
    final controller = StreamController<HydrationBatch>();
    final lastCursorCompleter = Completer<int>();
    var lastEmittedCursor = fromCursor;

    Future<void> loadEntries() async {
      try {
        int? cursor = fromCursor;
        while (cursor != null && (toCursor == null || cursor < toCursor)) {
          final page = await _storage.getIndexEntries(
            indexIris: indexIris,
            cursorTimestamp: cursor,
            limit: initialBatchSize,
          );

          if (page.entries.isNotEmpty) {
            final batch = _convertIndexEntriesToBatch(
                page.entries, page.lastCursor, indexSetVersionId);
            controller.add(batch);
            lastEmittedCursor = page.lastCursor ?? lastEmittedCursor;
            cursor = page.lastCursor;
          }

          if (!page.hasMore ||
              (toCursor != null && (cursor != null && cursor > toCursor))) {
            break;
          }
        }
        lastCursorCompleter.complete(lastEmittedCursor);
      } catch (e, st) {
        lastCursorCompleter.completeError(e, st);
        _log.severe('Error loading index entries', e, st);
        controller.addError(e, st);
      } finally {
        await controller.close();
      }
    }

    loadEntries();

    return (stream: controller.stream, lastCursor: lastCursorCompleter.future);
  }

  // Helper to convert DB entries to HydrationBatch
  HydrationBatch _convertIndexEntriesToBatch(
      List<storage.IndexEntryWithIri> entries,
      int? lastCursor,
      int? setVersionId) {
    final updates = <IdentifiedGraph>[];
    final deletions = <IdentifiedGraph>[];

    for (final entry in entries) {
      // Entry structure in DB:
      // - entry.resourceIri: The resource IRI (already external, stored as IriTerm.value)
      // - entry.clockHash: The CRDT clock hash of the resource
      // - entry.headerProperties: Turtle-encoded triples with indexed properties
      //
      // In RDF, the full entry looks like:
      //   entryIri idx:resource resourceIri .
      //   entryIri crdt:clockHash "hash" .
      //   entryIri schema:title "..." .  // header properties
      //
      // For hydration, we flatten this to just the resource IRI and its properties.
      final resourceIri = entry.resourceIri;

      // Build graph with header properties
      final triples = <Triple>[];

      // Add header properties if present
      if (entry.headerProperties != null) {
        triples.addAll(entry.headerProperties!.triples);
      }

      final graph = RdfGraph.fromTriples(triples);

      // Entries with isDeleted=true are tombstones
      if (entry.isDeleted) {
        deletions.add((resourceIri, graph));
      } else {
        updates.add((resourceIri, graph));
      }
    }

    return (
      updates: updates,
      deletions: deletions,
      cursor: _formatCursor(lastCursor ?? 0, setVersionId)
    );
  }

  Stream<HydrationBatch> _hydrateRootResourceStream({
    required IriTerm typeIri,
    String? cursor,
    int initialBatchSize = 100,
  }) async* {
    HydrationBatch convertResult(
        List<StoredDocument> documents, String? cursor) {
      final (deletions, updates) = documents
          .fold((<IdentifiedGraph>[], <IdentifiedGraph>[]), (acc, doc) {
        // Translate internal IRIs to external format for application consumption
        final externalIri = _iriTranslator.internalToExternal(doc.documentIri);
        final externalGraph =
            _iriTranslator.translateGraphToExternal(doc.document);

        final primaryTopicIri = externalGraph.expectSingleObject<IriTerm>(
            externalIri, SyncManagedDocument.foafPrimaryTopic);
        final appGraph = primaryTopicIri != null
            ? externalGraph.subgraph(primaryTopicIri)
            : externalGraph;
        final isDeletion = externalGraph.hasTriples(
            subject: externalIri, predicate: SyncManagedDocument.crdtDeletedAt);
        if (primaryTopicIri == null) {
          _log.warning(
              'Document ${doc.documentIri} (isDeletion: $isDeletion) is missing foaf:primaryTopic, cannot determine resource IRI. Skipping.');
          return acc;
        }
        (isDeletion ? acc.$1 : acc.$2).add((primaryTopicIri, appGraph));
        return acc;
      });
      return (updates: updates, deletions: deletions, cursor: cursor);
    }

    // Phase 1: Load all existing documents in batches using pagination
    // This ensures we don't load unbounded amounts of data into memory
    while (true) {
      final result = await _storage.getDocumentsModifiedSince(
        typeIri,
        cursor,
        limit: initialBatchSize,
      );

      // Process each document in the batch
      yield convertResult(result.documents, result.currentCursor);

      cursor = result.currentCursor;

      // If there are no more documents to fetch, we've loaded everything
      if (!result.hasNext) {
        break;
      }
    }

    // Phase 2: Switch to reactive watch for ongoing changes.
    // Cursor-reset wrapper prevents the Drift bg isolate from re-scanning an
    // ever-growing window of already-processed documents on every re-execution.
    yield* _withCursorReset(
      createWatch: (watchCursor) => _storage
          .watchDocumentsModifiedSince(typeIri, watchCursor)
          .map((result) =>
              convertResult(result.documents, result.currentCursor)),
      initialCursor: cursor,
    );
  }

  /// Wraps a watch stream with automatic DB-level cursor advancement.
  ///
  /// The problem: Drift's reactive watch queries use a static WHERE clause cursor
  /// (set at subscription time). After bulk sync commits large batches, the watch
  /// re-executes and scans all rows since the original subscription cursor —
  /// discarding most of them via the in-memory progressive filter. The scan window
  /// grows with every committed chunk.
  ///
  /// The fix: once accumulated items since the last reset exceed [resetThreshold],
  /// cancel the current Drift subscription and resubscribe with the advanced
  /// cursor. The new subscription's WHERE clause starts from the current position,
  /// keeping the scan window small.
  ///
  /// UX-safe: the watch is never paused, so user-initiated changes are always
  /// reflected immediately. The cancel+resubscribe gap is sub-millisecond and
  /// any changes during the gap are captured by the new subscription's initial
  /// query.
  Stream<HydrationBatch> _withCursorReset({
    required Stream<HydrationBatch> Function(String? cursor) createWatch,
    required String? initialCursor,
    int resetThreshold = 1000,
  }) async* {
    var currentCursor = initialCursor;
    while (true) {
      var accumulated = 0;
      var resetTriggered = false;
      await for (final batch in createWatch(currentCursor)) {
        if (batch.cursor != null) currentCursor = batch.cursor;
        yield batch;
        accumulated += batch.updates.length + batch.deletions.length;
        if (accumulated >= resetThreshold) {
          resetTriggered = true;
          break;
        }
      }
      if (!resetTriggered) break;
    }
  }

  /// Close the sync system and free resources.
  Future<void> close() async {
    await _configService.close();

    await _syncManager.dispose();
    await _crdtDocumentManager.close();
    for (final func in _closeFunctions) {
      await func();
    }
  }
}
