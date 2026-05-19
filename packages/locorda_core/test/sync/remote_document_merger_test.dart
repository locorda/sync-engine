// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:locorda_core/src/crdt/crdt_types.dart';
import 'package:locorda_core/src/hlc_service.dart';
import 'package:locorda_core/src/mapping/framework_iri_generator.dart';
import 'package:locorda_core/src/mapping/merge_contract_loader.dart';
import 'package:locorda_core/src/mapping/recursive_rdf_loader.dart';
import 'package:locorda_core/src/sync/remote_document_merger.dart';
import 'package:logging/logging.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:test/test.dart';

import '../util/rdf_test_utils.dart';
import '../util/setup_logging.dart';
import 'package:locorda_core/src/storage/in_memory_storage.dart';
import 'test_fetcher.dart';
import 'test_physical_timestamp_factory.dart';

/// Record mode: When true, tests will write actual results as expected files
/// instead of comparing them. Use this to create/update test expectations.
///
/// Set via environment variable: RECORD_MODE=true dart test
final _recordMode = Platform.environment['RECORD_MODE'] == 'true';

void main() {
  if (_recordMode) {
    print('⚠️  Running in RECORD MODE - will overwrite expected files!');
  }

  // Load and parse all_tests.json
  final testAssetsDir = Directory('test/assets/remote_merge');
  final allTestsFile = File('${testAssetsDir.path}/all_tests.json');
  final allTestsJson =
      jsonDecode(allTestsFile.readAsStringSync()) as Map<String, dynamic>;

  // Parse base configuration
  final baseJson = allTestsJson['base'] as Map<String, dynamic>;
  final baseTimestamp = DateTime.parse(baseJson['timestamp'] as String);
  final baseInstallationId = baseJson['installation_id'] as String?;

  final iriFactory = IriTerm.validated;
  final mergeContractLoader =
      CachingMergeContractLoader(StandardMergeContractLoader(
          RecursiveRdfLoader(
              fetcher: StandardRdfGraphFetcher(
                  fetcher: TestFetcher.fromTestJson(
                    allTestsJson,
                    testAssetsDir,
                  ),
                  rdfCore: rdf),
              iriFactory: iriFactory),
          CrdtTypeRegistry.forStandardTypes()));
  final testSuites = allTestsJson['test_suites'] as List<dynamic>;

  // Group tests by suite
  for (final suiteJson in testSuites) {
    final suiteName = suiteJson['suite'] as String;
    final suiteDescription = suiteJson['description'] as String;
    final tests = suiteJson['tests'] as List<dynamic>;

    group('$suiteName - $suiteDescription', () {
      for (final testJson in tests.cast<Map<String, dynamic>>()) {
        final testId = testJson['id'] as String;
        final testDescription = testJson['description'] as String;
        final shouldSkip = testJson['skip'] as bool? ?? false;

        test('$testId: $testDescription', () async {
          setupTestLogging(Level.WARNING);
          await _executeMergeTest(testJson, testAssetsDir, mergeContractLoader,
              baseTimestamp: baseTimestamp,
              baseInstallationId: baseInstallationId);
        }, skip: shouldSkip);
      }
    });
  }
}

/// Executes a single merge test.
Future<void> _executeMergeTest(Map<String, dynamic> testJson,
    Directory testAssetsDir, MergeContractLoader mergeContractLoader,
    {DateTime? baseTimestamp, String? baseInstallationId}) async {
  baseTimestamp ??= DateTime.parse('2024-01-01T00:00:00Z');
  baseInstallationId ??= 'test-installation';

  final testId = testJson['id'] as String;

  // Load local graph (may be null)
  final localGraphPath = testJson['local_graph'] as String?;
  final localGraph = localGraphPath != null
      ? readGraphFromFile(testAssetsDir, localGraphPath)
      : null;

  // Load remote graph (may be null)
  final remoteGraphPath = testJson['remote_graph'] as String?;
  final remoteGraph = remoteGraphPath != null
      ? readGraphFromFile(testAssetsDir, remoteGraphPath)
      : null;

  // Get document IRI
  final documentIriStr = testJson['document_iri'] as String;
  final documentIri = IriTerm(documentIriStr);

  // Load merge contract
  final isGovernedBy = mergeContractLoader.getMergedGovernanceIris([
    if (localGraph != null) localGraph,
    if (remoteGraph != null) remoteGraph
  ], documentIri);
  final mergeContract = await mergeContractLoader.load(isGovernedBy);

  // Set up merger
  final storage = InMemoryStorage();

  final timestampFactory =
      TestPhysicalTimestampFactory(baseTimestamp: baseTimestamp);
  final hlcService = HlcService(
    installationLocalId: 'test-installation',
    physicalTimestampFactory: timestampFactory.call,
  );
  final crdtTypeRegistry = CrdtTypeRegistry.forStandardTypes();
  final frameworkIriGenerator = FrameworkIriGenerator();

  final merger = RemoteDocumentMerger(
    storage: storage,
    hlcService: hlcService,
    crdtTypeRegistry: crdtTypeRegistry,
    frameworkIriGenerator: frameworkIriGenerator,
  );

  // Perform merge
  final result = merger.merge(
    mergeContract: mergeContract,
    documentIri: documentIri,
    localGraph: localGraph,
    remoteGraph: remoteGraph,
  );

  // Verify result
  final expectedGraphPath = testJson['expected_merged_graph'] as String;

  if (_recordMode) {
    // Record mode: Write actual result as expected file
    await writeGraphToFile(
        testAssetsDir, expectedGraphPath, result.mergedGraph);
    print('📝 Recorded: $expectedGraphPath');
  } else {
    // Normal mode: Compare with expected
    final expectedGraph = readGraphFromFile(testAssetsDir, expectedGraphPath);
    expectEqualGraphs(
        '$testId - expected_merged_graph', result.mergedGraph, expectedGraph);
  }
}
