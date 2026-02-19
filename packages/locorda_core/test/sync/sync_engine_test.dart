import 'dart:convert';
import 'dart:io';

import 'package:locorda_core/locorda_core.dart';
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
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/sync/shard_document_generator.dart';
import 'package:locorda_core/src/util/build_effective_config.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

import '../util/rdf_test_utils.dart';
import '../util/setup_logging.dart';
import 'test_fetcher.dart';
import 'test_physical_timestamp_factory.dart';

/// Record mode: When true, tests will write actual results as expected files
/// instead of comparing them. Use this to create/update test expectations.
///
/// Set via environment variable: RECORD_MODE=true dart test
const _forceRecordMode =
    false; // Set to true to enable record mode without env variable
final _recordMode =
    _forceRecordMode || Platform.environment['RECORD_MODE'] == 'true';
final debug = (dumpSharedBackend: false, logStep: false);

/// Context for a single installation (device) in multi-device tests.
/// Each installation has its own storage, clock, and sync instance.
class _InstallationContext {
  final String installationId;
  final InMemoryStorage storage;
  final IriTranslator iriTranslator;
  final TestPhysicalTimestampFactory timestampFactory;
  final Future<SyncEngine> syncFuture;

  _InstallationContext({
    required this.installationId,
    required this.storage,
    required this.iriTranslator,
    required this.timestampFactory,
    required this.syncFuture,
  });
}

void main() {
  if (_recordMode) {
    print('⚠️  Running in RECORD MODE - will overwrite expected files!');
  }
  // Load and parse all_tests.json
  final testAssetsDir = Directory('test/assets/graph');
  final allTestsFile = File('${testAssetsDir.path}/all_tests.json');
  final allTestsJson =
      jsonDecode(allTestsFile.readAsStringSync()) as Map<String, dynamic>;

  final fetcher = TestFetcher.fromTestJson(
    allTestsJson,
    testAssetsDir,
  );
  // Parse base configuration
  final baseJson = allTestsJson['base'] as Map<String, dynamic>;
  final baseTimestamp = DateTime.parse(baseJson['timestamp'] as String);
  final baseInstallationId = baseJson['installation_id'] as String?;

  final testSuites = allTestsJson['test_suites'] as List<dynamic>;

  // Group tests by suite
  for (final suiteJson in testSuites) {
    final suiteName = suiteJson['suite'] as String;
    final suiteDescription = suiteJson['description'] as String;
    final tests = suiteJson['tests'] as List<dynamic>;

    group('$suiteName - $suiteDescription', () {
      for (final testJson in tests) {
        final testId = testJson['id'] as String;
        final testTitle = testJson['title'] as String;
        //final testDescription = testJson['description'] as String;
        final shouldSkip = testJson['skip'] as bool? ?? false;

        test('$testId: $testTitle', () async {
          // Get test-specific baseTimestamp or use default
          final testBaseTimestampStr = testJson['baseTimestamp'] as String?;
          final testBaseTimestamp = testBaseTimestampStr != null
              ? DateTime.parse(testBaseTimestampStr)
              : baseTimestamp;

          // Execute test based on suite type
          switch (suiteName) {
            case 'save':
            case 'dataset':
            case 'group_index':
              setupTestLogging(Level.WARNING);
              await _executeSaveTestWithSteps(testJson, testAssetsDir, fetcher,
                  testBaseTimestamp, baseInstallationId);
              break;
            case 'save_error':
              setupTestLogging(Level.OFF);
              await _executeSaveErrorTest(testJson, testAssetsDir, fetcher,
                  testBaseTimestamp, baseInstallationId);
              break;
            default:
              fail('Unknown test suite: $suiteName');
          }
        }, skip: shouldSkip);
      }
    });
  }
  group('Generate Iri', () {
    test('Recipe Iri Generation', () {
      final loc = LocalResourceLocator(iriTermFactory: IriTerm.validated);
      final resourceIri = loc.toIri(ResourceIdentifier(
          IriTerm('https://schema.org/Recipe'), 'recipe123', "it"));
      expect(
          resourceIri.value,
          equals(
              "tag:locorda.org,2025:l:aHR0cHM6Ly9zY2hlbWEub3JnL1JlY2lwZQ==:cmVjaXBlMTIz#it"));
    });
  });
}

RdfGraph? _readGraphFromPath(Directory testAssetsDir, String? path) {
  if (path == null) return null;
  return readGraphFromFile(testAssetsDir, path);
}

/// Executes a save test with support for multiple sequential steps.
/// Each step can have its own input, action timestamps, and expectations.
/// Supports multiple installations for multi-device sync testing.
Future<void> _executeSaveTestWithSteps(
    Map<String, dynamic> testJson,
    Directory testAssetsDir,
    TestFetcher fetcher,
    DateTime baseTimestamp,
    String? baseInstallationId) async {
  final testId = testJson['id'] as String;

  // Load configurations - either per-installation or single global config
  final Map<String, SyncEngineConfig> installationConfigs;

  if (testJson.containsKey('installations')) {
    // New format: per-installation configs
    final installationsJson = testJson['installations'] as List<dynamic>;
    installationConfigs = {};
    for (final installationJson in installationsJson) {
      final installationMap = installationJson as Map<String, dynamic>;
      final installationId = installationMap['id'] as String;
      final configPath = installationMap['config'] as String;
      installationConfigs[installationId] =
          _loadConfig(testAssetsDir, configPath);
    }
  } else {
    // Legacy format: single global config
    final config = _loadConfig(testAssetsDir, testJson['config'] as String);
    installationConfigs = {'*': config}; // Use '*' as wildcard key
  }

  // Shared backend for all installations (simulates the remote storage)
  // Get useShardDatasets flag from test config (defaults to false for backwards compatibility)
  final useShardDatasets = testJson['use_shard_datasets'] as bool? ?? false;
  final backendIriTranslator = IriTranslator.forConfig(
    resourceLocator: LocalResourceLocator(iriTermFactory: IriTerm.validated),
    resourceConfigs: installationConfigs.values
        .map((config) => buildEffectiveConfig(config))
        .expand((config) => config.resources)
        .map((config) => config.copyWith(
            documentIriTemplate:
                'https://example.com/${config.typeIri.localName.toLowerCase()}/{id}'))
        .toList(),
  );
  final sharedBackend = InMemoryBackend(
    useShardDatasets: useShardDatasets,
    iriTranslator: backendIriTranslator,
  );

  // Map of installation_id -> SyncEngine instance
  // Each installation has its own storage, clock, etc.
  final installations = <String, _InstallationContext>{};

  final steps = testJson['steps'] as List<dynamic>;

  for (var stepIndex = 0; stepIndex < steps.length; stepIndex++) {
    final stepJson = steps[stepIndex] as Map<String, dynamic>;

    // Get installation ID for this step (can be different per step)
    final stepInstallationId = stepJson['installation_id'] as String? ??
        testJson['installation_id'] as String? ??
        baseInstallationId ??
        'default-installation';

    // Get config for this installation
    final config = installationConfigs[stepInstallationId] ??
        installationConfigs['*'] ??
        (throw StateError(
            'No config found for installation $stepInstallationId'));

    // Get or create installation context
    final installationContext = installations.putIfAbsent(
      stepInstallationId,
      () {
        final storage = InMemoryStorage();
        final iriTranslator = IriTranslator.forConfig(
          resourceLocator:
              LocalResourceLocator(iriTermFactory: IriTerm.validated),
          resourceConfigs: config.resources,
        );
        final timestampFactory =
            TestPhysicalTimestampFactory(baseTimestamp: baseTimestamp);

        // Get or create sync instance for this installation

        final syncFuture = SyncEngine.create(
          engineParams: EngineParams(
            backends: [sharedBackend],
            storage: storage,
            fetcher: fetcher,
            physicalTimestampFactory: timestampFactory,
            installationIdFactory: () => stepInstallationId,
          ),
          config: config,
        );

        return _InstallationContext(
          installationId: stepInstallationId,
          storage: storage,
          iriTranslator: iriTranslator,
          timestampFactory: timestampFactory,
          syncFuture: syncFuture,
        );
      },
    );

    await _executeStep(
      testId: testId,
      stepIndex: stepIndex,
      stepJson: stepJson,
      testAssetsDir: testAssetsDir,
      baseTimestamp: baseTimestamp,
      baseInstallationId: stepInstallationId,
      config: config,
      sharedBackend: sharedBackend,
      installationContext: installationContext,
      testFetcher: fetcher,
      backendIriTranslator: backendIriTranslator,
    );
  }
}

/// Executes a single step within a multi-step test.
Future<void> _executeStep({
  required String testId,
  required int stepIndex,
  required Map<String, dynamic> stepJson,
  required Directory testAssetsDir,
  required DateTime baseTimestamp,
  required String? baseInstallationId,
  required SyncEngineConfig config,
  required InMemoryBackend sharedBackend,
  required _InstallationContext installationContext,
  required TestFetcher testFetcher,
  required IriTranslator backendIriTranslator,
}) async {
  // Make sure to reset property changes for next step
  installationContext.storage.resetPropertyChanges();

  final storage = installationContext.storage;
  final iriTranslator = installationContext.iriTranslator;
  final timestampFactory = installationContext.timestampFactory;

  final action = stepJson['action'] as String;
  if (debug.logStep) {
    print('➡️ [$testId] Step $stepIndex ($action) [$baseInstallationId] ');
  }
  if (debug.dumpSharedBackend) {
    _dumpSharedBackend(sharedBackend, 'before $action');
  }

  // Load action timestamps if provided
  final actionTs = stepJson['action_ts'] as Map<String, dynamic>?;

  if (action == 'prepare') {
    // Prepare action: Load multiple documents into storage
    final documents = stepJson['documents'] as List<dynamic>;

    // Set timestamp for prepare.save if specified
    setTime(actionTs?['save'], timestampFactory);
    final now = timestampFactory();

    for (final docJson in documents) {
      final docMap = docJson as Map<String, dynamic>;
      final typeIri = IriTerm(docMap['typeIri'] as String);
      final graphPath = docMap['graph'] as String;
      final graph = _readGraphFromPath(testAssetsDir, graphPath)!;

      // Extract document IRI from the graph
      final documentIri = graph.subjects
          .whereType<IriTerm>()
          .map((s) => s.getDocumentIri())
          .toSet()
          .single;

      storage.saveDocument(
        documentIri,
        typeIri,
        graph,
        DocumentMetadata(
          ourPhysicalClock: now.millisecondsSinceEpoch,
          updatedAt: now.millisecondsSinceEpoch,
        ),
        [],
      );
    }
    return; // Prepare action has no expectations
  }

  if (action == 'sync') {
    // Sync action: Trigger sync for all shards that need updates

    // Set timestamp for sync action if specified
    setTime(actionTs?['sync'], timestampFactory);

    final sync = await installationContext.syncFuture;

    // Trigger sync - finds all shards with changes and syncs them
    await sync.syncManager.sync();

    // Verify expectations if provided
    final expectedJson = stepJson['expected'] as Map<String, dynamic>?;
    if (expectedJson != null) {
      // For sync action, we verify shard documents and group index documents
      await _verifyExpectations(
        testId: testId,
        stepIndex: stepIndex,
        expectedJson: expectedJson,
        testAssetsDir: testAssetsDir,
        storage: storage,
        config: buildEffectiveConfig(config),
        iriTranslator: iriTranslator,
        backendIriTranslator: backendIriTranslator,
        sharedBackend: sharedBackend,
      );
    }
    return;
  }

  if (action == 'generate_shard_documents') {
    // make sure the SyncEngine instance is fully initialized
    await installationContext.syncFuture;
    setTime(actionTs?['generate'], timestampFactory);
    final DateTime syncTime = timestampFactory();
    final lastSyncTimestamp = 0;
    final effectiveConfig = buildEffectiveConfig(config);
    final hlcService = HlcService(
        installationLocalId: baseInstallationId!,
        physicalTimestampFactory: timestampFactory);
    final shardManager = ShardManager();
    final iriTermFactory = IriTerm.validated;
    final resourceLocator =
        LocalResourceLocator(iriTermFactory: iriTermFactory);
    final rdfGenerator = IndexRdfGenerator(
        resourceLocator: resourceLocator, shardManager: shardManager);
    final parser =
        IndexParser(knownConfig: effectiveConfig, rdfGenerator: rdfGenerator);
    final indexDiscovery = IndexDiscovery(
      storage: storage,
      configService: SimpleConfigService(effectiveConfig),
      parser: parser,
      rdfGenerator: rdfGenerator,
    );
    final shardDeterminer = ShardDeterminer(
      indexDiscovery: indexDiscovery,
      rdfGenerator: rdfGenerator,
      shardManager: shardManager,
      storage: storage,
    );
    final crdtTypeRegistry = CrdtTypeRegistry.forStandardTypes();
    final frameworkIriGenerator = FrameworkIriGenerator();
    final localDocumentMerger = LocalDocumentMerger(
      crdtTypeRegistry: crdtTypeRegistry,
      frameworkIriGenerator: frameworkIriGenerator,
    );
    final mergeContractLoader = StandardMergeContractLoader(
        RecursiveRdfLoader(
          fetcher: StandardRdfGraphFetcher(fetcher: testFetcher, rdfCore: rdf),
          iriFactory: iriTermFactory,
        ),
        crdtTypeRegistry);
    final crdtDocumentManager = CrdtDocumentManager(
        storage: storage,
        configService: SimpleConfigService(effectiveConfig),
        hlcService: hlcService,
        localDocumentMerger: localDocumentMerger,
        mergeContractLoader: mergeContractLoader,
        physicalTimestampFactory: timestampFactory,
        shardDeterminer: shardDeterminer);
    final installationIri = InstallationService.createInstallationIri(
        resourceLocator, baseInstallationId);
    final indexManager = IndexManager(
      crdtDocumentManager: crdtDocumentManager,
      rdfGenerator: rdfGenerator,
      storage: storage,
      installationIri: installationIri,
      configService: SimpleConfigService(effectiveConfig),
      indexDiscovery: indexDiscovery,
      resourceLocator: resourceLocator,
    );
    final shardDocumentGenerator = ShardDocumentGenerator(
        documentManager: crdtDocumentManager,
        storage: storage,
        indexManager: indexManager);

    await shardDocumentGenerator(syncTime, lastSyncTimestamp);

    // Verify expectations if provided
    final expectedJson = stepJson['expected'] as Map<String, dynamic>?;
    if (expectedJson != null) {
      await _verifyExpectations(
        testId: testId,
        stepIndex: stepIndex,
        expectedJson: expectedJson,
        testAssetsDir: testAssetsDir,
        storage: storage,
        config: effectiveConfig,
        iriTranslator: iriTranslator,
        backendIriTranslator: backendIriTranslator,
        sharedBackend: sharedBackend,
      );
    }
    return;
  }
  if (action != 'save') {
    fail('Unknown action: $action');
  }

  // Get type IRI from step
  final typeIri = IriTerm(stepJson['typeIri'] as String);

  // Load input resource
  final inputResource =
      _readGraphFromPath(testAssetsDir, stepJson['input_resource'] as String)!;

  // Load stored_graph_before if specified (legacy support)
  final storedGraphBefore = _readGraphFromPath(
      testAssetsDir, stepJson['stored_graph_before'] as String?);

  // Extract document IRI from input
  final externalDocumentIri = inputResource.subjects
      .whereType<IriTerm>()
      .map((s) => s.getDocumentIri())
      .toSet()
      .single;

  if (storedGraphBefore != null) {
    // Legacy support: Set timestamp for prepare.save if specified
    setTime(actionTs?['prepare']?['save'], timestampFactory);
    final now = timestampFactory();

    storage.saveDocument(
        iriTranslator.externalToInternal(externalDocumentIri),
        typeIri,
        storedGraphBefore,
        DocumentMetadata(
          ourPhysicalClock: now.millisecondsSinceEpoch,
          updatedAt: now.millisecondsSinceEpoch,
        ),
        []);
  }

  final sync = await installationContext.syncFuture;

  // Set timestamp for save action if specified
  setTime(actionTs?['save'], timestampFactory);

  await sync.save(typeIri, inputResource);

  // Verify expectations if provided
  final expectedJson = stepJson['expected'] as Map<String, dynamic>?;
  if (expectedJson != null) {
    await _verifyExpectations(
      testId: testId,
      stepIndex: stepIndex,
      expectedJson: expectedJson,
      testAssetsDir: testAssetsDir,
      storage: storage,
      config: config,
      iriTranslator: iriTranslator,
      backendIriTranslator: backendIriTranslator,
      sharedBackend: sharedBackend,
      externalDocumentIri: externalDocumentIri,
      typeIri: typeIri,
    );
  }
}

void _dumpSharedBackend(InMemoryBackend sharedBackend, String when) {
  for (var remote in sharedBackend.remotes) {
    print(
        '🗄️  Shared Backend State ($when) - ${remote.remoteId.backend} - ${remote.remoteId.id}:');
    /*
    for (final entry in remote.documents.entries) {
      print(('-' * 10) +
          ' ${IriTerm(entry.key).debug} - ${entry.value.etag} ' +
          ('-' * 10));
      print(turtle.encode(entry.value.graph));
      print('-' * 80 + '\n');
    }
    */
  }
}

/// Verifies all expectations for a step.
Future<void> _verifyExpectations({
  required String testId,
  required int stepIndex,
  required Map<String, dynamic> expectedJson,
  required Directory testAssetsDir,
  required InMemoryStorage storage,
  required SyncEngineConfig config,
  required IriTranslator iriTranslator,
  required InMemoryBackend sharedBackend,
  required IriTranslator backendIriTranslator,
  IriTerm? externalDocumentIri,
  IriTerm? typeIri,
}) async {
  // Extract document IRI if we have external IRI (needed for property_changes)
  final documentIri = externalDocumentIri == null
      ? null
      : iriTranslator.externalToInternal(externalDocumentIri);

  // Verify documents if expected (new unified format)
  final expectedDocuments = expectedJson['documents'] as List<dynamic>?;
  final documentsDir = expectedJson['documents_dir'] as String?;
  // TODO: maybe ensure only dir or files are expected
  /*
  if (expectedDocuments != null && documentsDir != null) {
    fail('Expected only one of "documents" or "documents_dir"');
  }
  */
  if (expectedDocuments != null) {
    await _verifyDocuments(
        testId, stepIndex, expectedDocuments, testAssetsDir, storage);
  }
  if (documentsDir != null) {
    if (_recordMode) {
      await _recordDocumentsDirectory(
        testAssetsDir: testAssetsDir,
        relativeDir: documentsDir,
        actualDocuments: _getLocalDocumentsForTesting(storage),
        allowDatasets: false,
        backendIriTranslator: backendIriTranslator,
      );
    } else {
      await _verifyDocumentsDirectory(
        testId: testId,
        stepIndex: stepIndex,
        testAssetsDir: testAssetsDir,
        relativeDir: documentsDir,
        actualDocuments: _getLocalDocumentsForTesting(storage),
        allowDatasets: false,
        backendIriTranslator: backendIriTranslator,
      );
    }
  }

  final expectedRemoteDocuments =
      expectedJson['remote_documents'] as List<dynamic>?;
  final remoteDocumentsDir = expectedJson['remote_documents_dir'] as String?;
  /*
  // TODO: maybe ensure only dir or files are expected
  if (expectedRemoteDocuments != null && remoteDocumentsDir != null) {
    fail('Expected only one of "remote_documents" or "remote_documents_dir"');
  }
  */
  if (expectedRemoteDocuments != null) {
    await _verifyRemoteDocuments(
      testId: testId,
      stepIndex: stepIndex,
      expectedDocuments: expectedRemoteDocuments,
      testAssetsDir: testAssetsDir,
      sharedBackend: sharedBackend,
    );
  }
  if (remoteDocumentsDir != null) {
    if (_recordMode) {
      await _recordDocumentsDirectory(
        testAssetsDir: testAssetsDir,
        relativeDir: remoteDocumentsDir,
        actualDocuments:
            _getRemoteDocumentsForTesting(sharedBackend, backendIriTranslator),
        allowDatasets: true,
        backendIriTranslator: backendIriTranslator,
      );
    } else {
      await _verifyDocumentsDirectory(
        testId: testId,
        stepIndex: stepIndex,
        testAssetsDir: testAssetsDir,
        relativeDir: remoteDocumentsDir,
        actualDocuments:
            _getRemoteDocumentsForTesting(sharedBackend, backendIriTranslator),
        allowDatasets: true,
        backendIriTranslator: backendIriTranslator,
      );
    }
  }

  // Verify property changes if expected
  final expectedPropertyChanges = _parseExpectedPropertyChanges(expectedJson);
  if (expectedPropertyChanges != null) {
    if (documentIri == null) {
      fail('documentIri must be provided to verify property_changes');
    }
    final actualPropertyChanges = await storage.getPropertyChanges(documentIri);

    if (_recordMode) {
      // Record mode: Property changes are not recorded to files
      // (they're verified programmatically, not from static files)
      print('📝 Property changes recorded in memory (not written to file)');
    } else {
      // Normal mode: Compare with expected
      _expectEqualPropertyChanges(
          actualPropertyChanges, expectedPropertyChanges);
    }
  }
}

class _ExpectedDocumentFile {
  final IriTerm documentIri;
  final String path;
  final bool isDataset;

  const _ExpectedDocumentFile({
    required this.documentIri,
    required this.path,
    required this.isDataset,
  });
}

class _ActualDocument {
  final IriTerm documentIri;
  final Object data;

  const _ActualDocument({
    required this.documentIri,
    required this.data,
  });

  bool get isDataset => data is RdfDataset;
  bool get isGraph => data is RdfGraph;
  RdfGraph get graph => data as RdfGraph;
  RdfDataset get dataset => data as RdfDataset;
}

IriTerm _resolveDocumentIri(
  Map<String, dynamic> docMap,
  LocalResourceLocator resourceLocator,
) {
  if (docMap.containsKey('iri')) {
    return IriTerm(docMap['iri'] as String);
  }
  if (docMap.containsKey('type_iri') && docMap.containsKey('id')) {
    final typeIri = IriTerm(docMap['type_iri'] as String);
    final id = docMap['id'] as String;
    return resourceLocator.toIri(ResourceIdentifier.document(typeIri, id));
  }
  fail('Document spec must provide either "iri" or both "type_iri" and "id"');
}

void _expectEqualGraphs(String name, RdfGraph actual, RdfGraph expected) {
  expectEqualGraphs(name, actual, expected);
}

void setTime(String? ts, TestPhysicalTimestampFactory timestampFactory) {
  if (ts != null) {
    final dateTime = DateTime.parse(ts);
    timestampFactory.setTimestamp(dateTime);
  }
}

SyncEngineConfig _loadConfig(Directory testAssetsDir, String configPath) {
  final configFile = File('${testAssetsDir.path}/$configPath');
  final configJson =
      jsonDecode(configFile.readAsStringSync()) as Map<String, dynamic>;

  return SyncEngineConfig.fromJson(configJson);
}

/// Parse expected property changes from test JSON.
/// Returns null if property_changes is not specified (meaning: don't test).
/// Returns empty list if property_changes is specified as empty array.
List<PropertyChange>? _parseExpectedPropertyChanges(
    Map<String, dynamic> expectedJson) {
  if (!expectedJson.containsKey('property_changes')) {
    return null; // Not specified - don't test property changes
  }

  final propertyChangesJson = expectedJson['property_changes'] as List<dynamic>;
  return propertyChangesJson.map((json) {
    final map = json as Map<String, dynamic>;
    return PropertyChange(
      resourceIri: IriTerm(map['resource_iri'] as String),
      propertyIri: IriTerm(map['property_iri'] as String),
      changedAtMs:
          DateTime.parse(map['changed_at'] as String).millisecondsSinceEpoch,
      changeLogicalClock: map['logical_clock'] as int,
    );
  }).toList();
}

/// Compare actual and expected property changes (order-independent).
/// Filters out framework properties from actual changes, as tests only verify app data changes.
void _expectEqualPropertyChanges(
    List<PropertyChange> actual, List<PropertyChange> expected) {
  // Filter to app data changes only (exclude framework metadata)
  final actualAppChanges =
      actual.where((pc) => !pc.isFrameworkProperty).toList();

  // Sort both lists by a consistent key for comparison
  String key(PropertyChange pc) =>
      '${pc.resourceIri.value}|${(pc.propertyIri as IriTerm).value}|${pc.changeLogicalClock}';

  final actualSorted = actualAppChanges.toList()
    ..sort((a, b) => key(a).compareTo(key(b)));
  final expectedSorted = expected.toList()
    ..sort((a, b) => key(a).compareTo(key(b)));

  if (actualSorted.length != expectedSorted.length) {
    fail('Expected ${expectedSorted.length} property changes, '
        'but got ${actualSorted.length}.\n'
        '\nExpected: \n\t${expectedSorted.map(formatChangedProperty).join('\n\t')}\n'
        '\nActual: \n\t${actualSorted.map(formatChangedProperty).join('\n\t')}');
  }

  for (var i = 0; i < expectedSorted.length; i++) {
    final exp = expectedSorted[i];
    final act = actualSorted[i];

    // Build a detailed context message for this property change comparison
    String context() => '\n'
        '\nExpected:\n\t${formatChangedProperty(exp)}\n'
        '\nActual:\n\t${formatChangedProperty(act)}';

    if (act.resourceIri != exp.resourceIri) {
      fail('Property change #$i: resource IRI mismatch${context()}');
    }
    if (act.propertyIri != exp.propertyIri) {
      fail('Property change #$i: property IRI mismatch${context()}');
    }
    if (act.changeLogicalClock != exp.changeLogicalClock) {
      fail('Property change #$i: logical clock mismatch${context()}');
    }
    if (act.changedAtMs != exp.changedAtMs) {
      fail('Property change #$i: timestamp mismatch${context()}');
    }
  }
}

String formatChangedProperty(PropertyChange exp) =>
    'resource=${exp.resourceIri.debug}, property=${(exp.propertyIri as IriTerm).value}, clock=${exp.changeLogicalClock}, timestamp=${exp.changedAtMs}';

/// Verify documents using unified format.
///
/// Each document spec can provide:
/// - `iri`: Direct tag IRI (complete document IRI without fragment)
/// - OR `type_iri` + `id`: Components to build IRI via LocalResourceLocator
/// - `path`: Path to expected graph file
Future<void> _verifyDocuments(
  String testId,
  int stepIndex,
  List<dynamic> expectedDocuments,
  Directory testAssetsDir,
  InMemoryStorage storage,
) async {
  final resourceLocator =
      LocalResourceLocator(iriTermFactory: IriTerm.validated);

  for (final docJson in expectedDocuments) {
    final docMap = docJson as Map<String, dynamic>;
    final path = docMap['path'] as String;

    // Determine document IRI - either direct or constructed
    final documentIri = _resolveDocumentIri(docMap, resourceLocator);

    // Load actual document from storage
    final storedDoc = await storage.getDocument(documentIri);
    if (storedDoc == null) {
      fail('No document found in storage for IRI: ${documentIri.value}\n'
          'Expected: ${documentIri.debug}');
    }

    if (_recordMode) {
      // Record mode: Write actual result as expected file
      await writeGraphToFile(testAssetsDir, path, storedDoc.document);
      print('📝 Recorded: $path');
    } else {
      // Normal mode: Compare with expected
      final expectedGraph = _readGraphFromPath(testAssetsDir, path)!;
      _expectEqualGraphs(
        "$testId [step $stepIndex] - document $path",
        storedDoc.document,
        expectedGraph,
      );
    }
  }
}

Future<void> _verifyRemoteDocuments({
  required String testId,
  required int stepIndex,
  required List<dynamic> expectedDocuments,
  required Directory testAssetsDir,
  required InMemoryBackend sharedBackend,
}) async {
  final resourceLocator =
      LocalResourceLocator(iriTermFactory: IriTerm.validated);
  final remote = sharedBackend.remotes.first;

  for (final docJson in expectedDocuments) {
    final docMap = docJson as Map<String, dynamic>;
    final documentIri = _resolveDocumentIri(docMap, resourceLocator);

    final path = docMap['path'] as String;
    final isDataset = path.toLowerCase().endsWith('.trig');
    if (isDataset) {
      final dataset = remote.getStoredDataset(documentIri);
      if (dataset == null) {
        fail('No dataset found in remote for IRI: ${documentIri.value}\n'
            'Expected: ${documentIri.debug}');
      }

      if (_recordMode) {
        await writeDatasetToFile(testAssetsDir, path, dataset);
        print('📝 Recorded: $path');
      } else {
        final expectedDataset = readDatasetFromFile(testAssetsDir, path);
        expectEqualDatasets(
          "$testId [step $stepIndex] - remote dataset $path",
          dataset,
          expectedDataset,
        );
      }
      continue;
    }

    final storedGraph = remote.getStoredGraph(documentIri);
    if (storedGraph == null) {
      fail('No document found in remote for IRI: ${documentIri.value}\n'
          'Expected: ${documentIri.debug}');
    }

    if (_recordMode) {
      await writeGraphToFile(testAssetsDir, path, storedGraph);
      print('📝 Recorded: $path');
    } else {
      final expectedGraph = _readGraphFromPath(testAssetsDir, path)!;
      _expectEqualGraphs(
        "$testId [step $stepIndex] - remote document $path",
        storedGraph,
        expectedGraph,
      );
    }
  }
}

List<_ActualDocument> _getLocalDocumentsForTesting(InMemoryStorage storage) {
  return storage
      .getAllDocumentsForTesting()
      .entries
      .map((entry) => _ActualDocument(
            documentIri: entry.key,
            data: entry.value.document,
          ))
      .toList();
}

List<_ActualDocument> _getRemoteDocumentsForTesting(
    InMemoryBackend sharedBackend, IriTranslator backendIriTranslator) {
  final remote = sharedBackend.remotes.first;
  return remote
      .getStoredDocumentsForTesting()
      .map((doc) => _ActualDocument(
          documentIri: backendIriTranslator.externalToInternal(doc.documentIri),
          data: doc.data))
      .toList();
}

Future<void> _verifyDocumentsDirectory({
  required String testId,
  required int stepIndex,
  required Directory testAssetsDir,
  required String relativeDir,
  required List<_ActualDocument> actualDocuments,
  required bool allowDatasets,
  required IriTranslator backendIriTranslator,
}) async {
  final expectedDocuments = _loadExpectedDocumentsDirectory(
      testAssetsDir: testAssetsDir,
      relativeDir: relativeDir,
      allowDatasets: allowDatasets,
      // relevant is what is inside the directory, not if the directory itself is missing - we want to allow missing directory for empty expectations
      allowMissing: true,
      backendIriTranslator: backendIriTranslator);

  final actualByIri = {
    for (final doc in actualDocuments) doc.documentIri: doc,
  };

  _expectExactDocumentSet(expectedDocuments.keys, actualByIri.keys,
      context: '$testId [step $stepIndex] - $relativeDir');

  for (final expected in expectedDocuments.values) {
    final actual = actualByIri[expected.documentIri];
    if (actual == null) {
      fail('Missing document for IRI: ${expected.documentIri.debug}');
    }

    if (expected.isDataset) {
      if (!actual.isDataset) {
        fail('Expected dataset for ${expected.documentIri.debug}, '
            'but actual is graph.');
      }
      final expectedDataset = readDatasetFromFile(testAssetsDir, expected.path);
      expectEqualDatasets(
        "$testId [step $stepIndex] - dataset ${expected.path}",
        actual.dataset,
        expectedDataset,
      );
      continue;
    }

    if (!actual.isGraph) {
      fail('Expected graph for ${expected.documentIri.debug}, '
          'but actual is dataset.');
    }
    final expectedGraph = readGraphFromFile(testAssetsDir, expected.path);
    _expectEqualGraphs(
      "$testId [step $stepIndex] - document ${expected.path}",
      actual.graph,
      expectedGraph,
    );
  }
}

Future<void> _recordDocumentsDirectory({
  required Directory testAssetsDir,
  required String relativeDir,
  required List<_ActualDocument> actualDocuments,
  required bool allowDatasets,
  required IriTranslator backendIriTranslator,
}) async {
  final expectedDocuments = _loadExpectedDocumentsDirectory(
    testAssetsDir: testAssetsDir,
    relativeDir: relativeDir,
    allowDatasets: allowDatasets,
    allowMissing: true,
    backendIriTranslator: backendIriTranslator,
  );

  final dir = Directory('${testAssetsDir.path}/$relativeDir');
  await dir.create(recursive: true);

  final usedPaths = <String>{};
  for (final actual in actualDocuments) {
    if (actual.isDataset && !allowDatasets) {
      fail('Dataset encountered in record mode for $relativeDir: '
          '${actual.documentIri.debug}');
    }

    final existing = expectedDocuments[actual.documentIri];
    final extension = actual.isDataset ? '.trig' : '.ttl';
    final useExisting =
        existing != null && existing.path.toLowerCase().endsWith(extension);

    final path = useExisting
        ? existing.path
        : _buildExpectedPath(
            relativeDir: relativeDir,
            documentIri: actual.documentIri,
            extension: extension,
          );

    if (actual.isDataset) {
      await writeDatasetToFile(testAssetsDir, path, actual.dataset);
    } else {
      await writeGraphToFile(testAssetsDir, path, actual.graph);
    }
    usedPaths.add(path);
  }

  final existingFiles = _listExpectedFiles(dir);
  for (final file in existingFiles) {
    final relPath = _relativePath(testAssetsDir, file);
    if (!usedPaths.contains(relPath)) {
      await file.delete();
    }
  }
}

Map<IriTerm, _ExpectedDocumentFile> _loadExpectedDocumentsDirectory({
  required Directory testAssetsDir,
  required String relativeDir,
  required bool allowDatasets,
  required bool allowMissing,
  required IriTranslator backendIriTranslator,
}) {
  final dir = Directory('${testAssetsDir.path}/$relativeDir');
  if (!dir.existsSync()) {
    if (allowMissing) {
      return {};
    }
    fail('Expected directory not found: ${dir.path}');
  }

  final expected = <IriTerm, _ExpectedDocumentFile>{};
  for (final file in _listExpectedFiles(dir)) {
    final relPath = _relativePath(testAssetsDir, file);
    final lower = relPath.toLowerCase();
    final isDataset = lower.endsWith('.trig');
    if (isDataset && !allowDatasets) {
      fail('Found dataset file in $relativeDir, but datasets are not allowed: '
          '$relPath');
    }

    final externalDocumentIri = isDataset
        ? extractDocumentIriFromDataset(
            readDatasetFromFile(testAssetsDir, relPath))
        : extractDocumentIriFromGraph(
            readGraphFromFile(testAssetsDir, relPath));
    final documentIri =
        backendIriTranslator.externalToInternal(externalDocumentIri);
    if (expected.containsKey(documentIri)) {
      fail('Duplicate document IRI in $relativeDir: ${documentIri.debug}');
    }

    expected[documentIri] = _ExpectedDocumentFile(
      documentIri: documentIri,
      path: relPath,
      isDataset: isDataset,
    );
  }

  return expected;
}

void _expectExactDocumentSet(
  Iterable<IriTerm> expected,
  Iterable<IriTerm> actual, {
  required String context,
}) {
  final expectedSet = expected.toSet();
  final actualSet = actual.toSet();

  final missing = expectedSet.difference(actualSet).toList();
  final extra = actualSet.difference(expectedSet).toList();

  if (missing.isNotEmpty || extra.isNotEmpty) {
    final missingText = missing.isEmpty
        ? ''
        : '\nMissing:\n\t${missing.map((i) => i.debug).join("\n\t")}';
    final extraText = extra.isEmpty
        ? ''
        : '\nExtra:\n\t${extra.map((i) => i.debug).join("\n\t")}';
    fail('Document set mismatch for $context.$missingText$extraText');
  }
}

List<File> _listExpectedFiles(Directory dir) {
  return dir.listSync(recursive: true).whereType<File>().where((file) {
    final lower = file.path.toLowerCase();
    return lower.endsWith('.ttl') || lower.endsWith('.trig');
  }).toList();
}

String _relativePath(Directory testAssetsDir, File file) {
  final root = testAssetsDir.path;
  final fullPath = file.path;
  if (!fullPath.startsWith(root)) {
    fail('File is outside test assets directory: $fullPath');
  }
  final rel = fullPath.substring(root.length);
  return rel.startsWith('/') ? rel.substring(1) : rel;
}

String _safeFileNameForIri(IriTerm iri) {
  final locator = LocalResourceLocator(iriTermFactory: IriTerm.validated);
  try {
    final identifier = locator.fromIri(iri);
    final typeName = _sanitizePathSegment(identifier.typeIri.localName);
    final id = _sanitizePathSegment(identifier.id);
    final fragment = identifier.fragment == null
        ? ''
        : '__${_sanitizePathSegment(identifier.fragment!)}';
    return '$typeName/$id$fragment';
  } catch (_) {
    final encoded = base64Url.encode(utf8.encode(iri.value));
    return 'unknown/$encoded';
  }
}

String _buildExpectedPath({
  required String relativeDir,
  required IriTerm documentIri,
  required String extension,
}) {
  final base = _safeFileNameForIri(documentIri);
  return '$relativeDir/$base$extension';
}

String _sanitizePathSegment(String value) {
  final trimmed = value.trim();
  final sanitized = trimmed.replaceAll(RegExp(r'[^a-zA-Z0-9._-]+'), '_');
  return sanitized.isEmpty ? 'unnamed' : sanitized;
}

/// Execute a save error test - expects an exception to be thrown
Future<void> _executeSaveErrorTest(
    Map<String, dynamic> testJson,
    Directory testAssetsDir,
    TestFetcher fetcher,
    DateTime baseTimestamp,
    String? baseInstallationId) async {
  // Load configuration
  final config = _loadConfig(testAssetsDir, testJson['config'] as String);

  // Get type IRI
  final typeIri = IriTerm(testJson['typeIri'] as String);

  // Load input resource
  final inputResource =
      _readGraphFromPath(testAssetsDir, testJson['input_resource'] as String)!;

  // Get expected error details
  final expectedJson = testJson['expected'] as Map<String, dynamic>;
  final expectedErrorType = expectedJson['error_type'] as String;
  final expectedErrorMessagePattern =
      expectedJson['error_message_pattern'] as String?;

  // Load action timestamps if provided
  final actionTs = testJson['action_ts'] as Map<String, dynamic>?;

  final storage = InMemoryStorage();

  try {
    // Execute save (should throw)
    final timestampFactory =
        TestPhysicalTimestampFactory(baseTimestamp: baseTimestamp);

    final installationIdFactory =
        baseInstallationId != null ? () => baseInstallationId : null;

    final sync = await SyncEngine.create(
      config: config,
      engineParams: EngineParams(
        backends: [InMemoryBackend()],
        storage: storage,
        fetcher: fetcher,
        physicalTimestampFactory: timestampFactory,
        installationIdFactory: installationIdFactory,
      ),
    );

    // Set timestamp for save action if specified
    setTime(actionTs?['save'], timestampFactory);

    await sync.save(typeIri, inputResource);

    fail('Expected $expectedErrorType to be thrown, but save succeeded');
  } catch (e) {
    // Verify error type
    final actualErrorType = e.runtimeType.toString();
    expect(actualErrorType, equals(expectedErrorType),
        reason:
            'Expected error type $expectedErrorType but got $actualErrorType');

    // Verify error message pattern if specified
    if (expectedErrorMessagePattern != null) {
      final errorMessage = e.toString();
      expect(errorMessage, contains(expectedErrorMessagePattern),
          reason:
              'Error message "$errorMessage" does not contain expected pattern "$expectedErrorMessagePattern"');
    }
  }
}
