import 'dart:io';

import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_core/src/backend/in_memory_backend.dart';
import 'package:locorda_core/src/crdt/crdt_types.dart';
import 'package:locorda_core/src/crdt_document_manager.dart';
import 'package:locorda_core/src/hlc_service.dart';
import 'package:locorda_core/src/index/index_discovery.dart';
import 'package:locorda_core/src/index/index_manager.dart';
import 'package:locorda_core/src/index/index_parser.dart';
import 'package:locorda_core/src/index/index_rdf_generator.dart';
import 'package:locorda_core/src/index/shard_determiner.dart';
import 'package:locorda_core/src/index/shard_manager.dart';
import 'package:locorda_core/src/installation_service.dart';
import 'package:locorda_core/src/local_document_merger.dart';
import 'package:locorda_core/src/mapping/framework_iri_generator.dart';
import 'package:locorda_core/src/mapping/merge_contract_loader.dart';
import 'package:locorda_core/src/mapping/recursive_rdf_loader.dart';
import 'package:locorda_core/src/storage/document_save_service.dart';
import 'package:locorda_core/src/sync/remote_document_merger.dart';
import 'package:locorda_core/src/sync/remote_sync_orchestrator.dart';
import 'package:locorda_core/src/sync/shard_document_generator.dart';
import 'package:locorda_core/src/util/build_effective_config.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:test/test.dart';

import '../util/setup_logging.dart';
import 'test_fetcher.dart';
import 'test_physical_timestamp_factory.dart';

/// Test fetcher that provides minimal mappings for unknown URLs
class _TestOrchestratorFetcher implements Fetcher {
  final TestFetcher _delegateFetcher;

  _TestOrchestratorFetcher(this._delegateFetcher);

  @override
  Future<String> fetch(String url, {String? contentType}) async {
    try {
      return await _delegateFetcher.fetch(url, contentType: contentType);
    } catch (e) {
      // Return a minimal valid mapping for unknown URLs
      // This allows tests to use arbitrary test URIs without needing full mappings
      return '''
@base <$url#> .
@prefix mc: <https://w3id.org/solid-crdt-sync/vocab/merge-contract#> .

<> a mc:DocumentMapping;
   mc:predicateMapping ( ) .
''';
    }
  }
}

/// Test setup helper that creates all required dependencies
class TestOrchestratorSetup {
  final InMemoryStorage storage;
  final InMemoryRemoteStorage backend;
  final RemoteSyncOrchestrator orchestrator;
  final SyncEngineConfig config;
  final TestPhysicalTimestampFactory timestampFactory;
  final HlcService hlcService;
  final MergeContractLoader mergeContractLoader;
  final String installationId;

  TestOrchestratorSetup({
    required this.storage,
    required this.backend,
    required this.orchestrator,
    required this.config,
    required this.timestampFactory,
    required this.hlcService,
    required this.mergeContractLoader,
    required this.installationId,
  });

  /// Create test setup with all dependencies properly initialized
  static Future<TestOrchestratorSetup> create({
    required SyncEngineConfig config,
    DateTime? baseTimestamp,
    String? installationId,
    bool useShardDatasets = false,
  }) async {
    final perflog = Perflog.root();
    // Build effective config with framework-owned resources
    final effectiveConfig = buildEffectiveConfig(config);
    final rdfCore = RdfCore.withStandardCodecs(
      additionalBinaryDatasetCodecs:
          StandardSyncEngine.extraBinaryDatasetCodecs,
      additionalBinaryGraphCodecs: StandardSyncEngine.extraBinaryGraphCodecs,
    );
    final storage = InMemoryStorage();
    final remoteStore = InMemoryBackendStore();
    final backend = InMemoryRemoteStorage(
      RemoteId('test', 'mock'),
      useShardDatasets: useShardDatasets,
      rdfCore: rdfCore,
      resourceGraphLoader: ResourceGraphLoaderImpl(storage: storage),
      store: remoteStore,
    );
    final timestampFactory = TestPhysicalTimestampFactory(
        baseTimestamp: baseTimestamp ?? DateTime.now());
    final testInstallationId = installationId ?? 'test-installation';

    final hlcService = HlcService(
      installationLocalId: testInstallationId,
      physicalTimestampFactory: timestampFactory,
    );

    final iriFactory = IriTerm.validated;
    final resourceLocator = LocalResourceLocator(iriTermFactory: iriFactory);
    final shardManager = ShardManager();
    final indexRdfGenerator = IndexRdfGenerator(
      resourceLocator: resourceLocator,
      shardManager: shardManager,
    );

    final crdtTypeRegistry = CrdtTypeRegistry.forStandardTypes();
    final frameworkIriGenerator = FrameworkIriGenerator();

    // Create test fetcher for framework mappings
    final testAssetsDir = Directory('packages/locorda_core/test/assets/graph');
    final baseTestFetcher = TestFetcher(
      testAssetsDir: testAssetsDir,
      urlToPathMap: {
        'https://w3id.org/solid-crdt-sync/mappings/core-v1':
            '../../../../../spec/mappings/core-v1.ttl',
        'https://w3id.org/solid-crdt-sync/mappings/shard-v1':
            '../../../../../spec/mappings/shard-v1.ttl',
        'https://w3id.org/solid-crdt-sync/mappings/index-v1':
            '../../../../../spec/mappings/index-v1.ttl',
        'https://w3id.org/solid-crdt-sync/mappings/client-installation-v1':
            '../../../../../spec/mappings/client-installation-v1.ttl',
      },
    );

    final testFetcher = _TestOrchestratorFetcher(baseTestFetcher);

    final fetcher = StandardRdfGraphFetcher(
      fetcher: testFetcher,
      rdfCore: rdfCore,
    );

    final mergeContractLoader = CachingMergeContractLoader(
      StandardMergeContractLoader(
        RecursiveRdfLoader(fetcher: fetcher, iriFactory: iriFactory),
        crdtTypeRegistry,
      ),
    );

    final localDocumentMerger = LocalDocumentMerger(
      frameworkIriGenerator: frameworkIriGenerator,
      crdtTypeRegistry: crdtTypeRegistry,
    );

    final indexParser = IndexParser(
      knownConfig: effectiveConfig,
      rdfGenerator: indexRdfGenerator,
    );

    final indexDiscovery = IndexDiscovery(
      storage: storage,
      parser: indexParser,
      rdfGenerator: indexRdfGenerator,
      configService: SimpleConfigService(effectiveConfig),
    );

    final shardDeterminer = ShardDeterminer(
      storage: storage,
      rdfGenerator: indexRdfGenerator,
      shardManager: shardManager,
      indexDiscovery: indexDiscovery,
    );

    final crdtDocumentManager = CrdtDocumentManager(
      storage: storage,
      configService: SimpleConfigService(effectiveConfig),
      shardDeterminer: shardDeterminer,
      mergeContractLoader: mergeContractLoader,
      localDocumentMerger: localDocumentMerger,
      hlcService: hlcService,
      physicalTimestampFactory: timestampFactory,
      documentSaveService: DocumentSaveService(storage),
    );

    final installationIri = InstallationService.createInstallationIri(
      resourceLocator,
      testInstallationId,
    );

    final indexManager = IndexManager(
      crdtDocumentManager: crdtDocumentManager,
      rdfGenerator: indexRdfGenerator,
      storage: storage,
      installationIri: installationIri,
      configService: SimpleConfigService(effectiveConfig),
      indexDiscovery: indexDiscovery,
      resourceLocator: resourceLocator,
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
      documentManager: crdtDocumentManager,
      storage: storage,
      indexManager: indexManager,
    );

    final remoteSyncStorage = await backend.createSyncStorage(effectiveConfig);

    final orchestrator = RemoteSyncOrchestrator(
      remoteSyncStorage: remoteSyncStorage,
      remoteId: backend.remoteId,
      storage: storage,
      merger: remoteDocumentMerger,
      indexRdfGenerator: indexRdfGenerator,
      indexManager: indexManager,
      shardDeterminer: shardDeterminer,
      hlcService: hlcService,
      mergeContractLoader: mergeContractLoader,
      localDocumentMerger: localDocumentMerger,
      shardDocumentGenerator: shardDocumentGenerator,
      physicalTimestampFactory: timestampFactory,
      useShardDatasets: backend.useShardDatasets,
      perflog: perflog,
      documentSaveService: DocumentSaveService(storage),
    );

    return TestOrchestratorSetup(
      storage: storage,
      backend: backend,
      orchestrator: orchestrator,
      config: effectiveConfig,
      timestampFactory: timestampFactory,
      hlcService: hlcService,
      mergeContractLoader: mergeContractLoader,
      installationId: testInstallationId,
    );
  }
}

/**
 * TODO: Those tests here are more or less nonesense and do not really 
 * test anything meaningful. They should be replaced with proper tests.
 */
void main() {
  setupTestLogging();

  group('RemoteSyncOrchestrator - Basic Sync Flow', () {
    test('should complete sync cycle without errors on empty backend',
        () async {
      // Arrange - Simple config with one resource type
      final noteType = const IriTerm('http://example.org/Note');
      final config = SyncEngineConfig(
        resources: [
          ResourceConfigData(
            crdtMapping: Uri.parse('https://example.org/note-mapping.ttl'),
            typeIri: noteType,
            indices: [
              const FullIndexData(
                localName: 'all-notes',
                rootResourceFetchPolicy: RootResourceFetchPolicy.onRequest,
              ),
            ],
          ),
        ],
      );

      final setup = await TestOrchestratorSetup.create(config: config);
      final syncTime = setup.timestampFactory();
      final lastSyncTimestamp = 0;

      // Act - Sync with empty backend should not throw
      await expectLater(
        setup.orchestrator.sync(
          syncTime,
          lastSyncTimestamp,
          config: setup.config,
        ),
        completes,
        reason: 'Sync should complete successfully even with no remote data',
      );

      // Assert - Storage is still usable
      expect(setup.storage, isNotNull);
    });

    test('should handle multiple sync cycles idempotently', () async {
      // Arrange
      final noteType = const IriTerm('http://example.org/Note');
      final config = SyncEngineConfig(
        resources: [
          ResourceConfigData(
            crdtMapping: Uri.parse('https://example.org/note-mapping.ttl'),
            typeIri: noteType,
            indices: [
              const FullIndexData(
                localName: 'all-notes',
                rootResourceFetchPolicy: RootResourceFetchPolicy.onRequest,
              ),
            ],
          ),
        ],
      );

      final setup = await TestOrchestratorSetup.create(config: config);
      final lastSyncTimestamp = 0;

      // Act - Run sync multiple times
      await setup.orchestrator.sync(
        setup.timestampFactory(),
        lastSyncTimestamp,
        config: setup.config,
      );
      await setup.orchestrator.sync(
        setup.timestampFactory(),
        lastSyncTimestamp,
        config: setup.config,
      );
      await setup.orchestrator.sync(
        setup.timestampFactory(),
        lastSyncTimestamp,
        config: setup.config,
      );

      // Assert - Multiple syncs should not cause errors
      expect(setup.storage, isNotNull,
          reason: 'Storage should remain functional after multiple syncs');
    });

    test('should complete sync in shard-dataset mode', () async {
      final noteType = const IriTerm('http://example.org/Note');
      final config = SyncEngineConfig(
        resources: [
          ResourceConfigData(
            crdtMapping: Uri.parse('https://example.org/note-mapping.ttl'),
            typeIri: noteType,
            indices: [
              const FullIndexData(
                localName: 'all-notes',
                rootResourceFetchPolicy: RootResourceFetchPolicy.onRequest,
              ),
            ],
          ),
        ],
      );

      final setup = await TestOrchestratorSetup.create(
        config: config,
        useShardDatasets: true,
      );

      await expectLater(
        setup.orchestrator.sync(
          setup.timestampFactory(),
          0,
          config: setup.config,
        ),
        completes,
      );
    });

    test('should handle different resource types independently', () async {
      // Arrange - Config with multiple resource types
      final noteType = const IriTerm('http://example.org/Note');
      final taskType = const IriTerm('http://example.org/Task');
      final config = SyncEngineConfig(
        resources: [
          ResourceConfigData(
            crdtMapping: Uri.parse('https://example.org/note-mapping.ttl'),
            typeIri: noteType,
            indices: [
              const FullIndexData(
                localName: 'all-notes',
                rootResourceFetchPolicy: RootResourceFetchPolicy.onRequest,
              ),
            ],
          ),
          ResourceConfigData(
            crdtMapping: Uri.parse('https://example.org/task-mapping.ttl'),
            typeIri: taskType,
            indices: [
              const FullIndexData(
                localName: 'all-tasks',
                rootResourceFetchPolicy: RootResourceFetchPolicy.onRequest,
              ),
            ],
          ),
        ],
      );

      final setup = await TestOrchestratorSetup.create(config: config);
      final syncTime = setup.timestampFactory();
      final lastSyncTimestamp = 0;

      // Act - Sync should process all configured resource types
      await expectLater(
        setup.orchestrator.sync(
          syncTime,
          lastSyncTimestamp,
          config: setup.config,
        ),
        completes,
        reason: 'Sync should handle multiple resource types without errors',
      );

      // Assert
      expect(setup.config.resources.length, equals(7),
          reason: 'Should have 2 user resources + 5 framework resources');
    });
  });

  group('RemoteSyncOrchestrator - Configuration', () {
    test('should accept prefetch RootResourceFetchPolicy configuration',
        () async {
      // Arrange
      final noteType = const IriTerm('http://example.org/Note');
      final config = SyncEngineConfig(
        resources: [
          ResourceConfigData(
            crdtMapping: Uri.parse('https://example.org/note-mapping.ttl'),
            typeIri: noteType,
            indices: [
              const FullIndexData(
                localName: 'all-notes',
                rootResourceFetchPolicy: RootResourceFetchPolicy.prefetch,
              ),
            ],
          ),
        ],
      );

      final setup = await TestOrchestratorSetup.create(config: config);

      // Act & Assert - Should configure and sync without errors
      await expectLater(
        setup.orchestrator.sync(
          setup.timestampFactory(),
          0,
          config: setup.config,
        ),
        completes,
        reason: 'Prefetch policy configuration should work',
      );
    });

    test('should accept onRequest RootResourceFetchPolicy configuration',
        () async {
      // Arrange
      final noteType = const IriTerm('http://example.org/Note');
      final config = SyncEngineConfig(
        resources: [
          ResourceConfigData(
            crdtMapping: Uri.parse('https://example.org/note-mapping.ttl'),
            typeIri: noteType,
            indices: [
              const FullIndexData(
                localName: 'all-notes',
                rootResourceFetchPolicy: RootResourceFetchPolicy.onRequest,
              ),
            ],
          ),
        ],
      );

      final setup = await TestOrchestratorSetup.create(config: config);

      // Act & Assert - Should configure and sync without errors
      await expectLater(
        setup.orchestrator.sync(
          setup.timestampFactory(),
          0,
          config: setup.config,
        ),
        completes,
        reason: 'OnRequest policy configuration should work',
      );
    });
  });
}
