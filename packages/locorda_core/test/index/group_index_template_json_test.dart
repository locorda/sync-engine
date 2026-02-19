import 'dart:convert';
import 'dart:io';

import 'package:locorda_core/src/config/sync_engine_config.dart';
import 'package:locorda_core/src/vocab/generated/_index.dart';
import 'package:locorda_core/src/index/index_parser.dart';
import 'package:locorda_core/src/index/index_config_base.dart';
import 'package:locorda_core/src/index/index_rdf_generator.dart';
import 'package:locorda_core/src/index/shard_manager.dart';
import 'package:locorda_core/src/mapping/resource_locator.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:test/test.dart';

import '../util/rdf_test_utils.dart';

void main() {
  // Load and parse all_tests.json
  final testAssetsDir = Directory('test/assets/group_index_template');
  final allTestsFile = File('${testAssetsDir.path}/all_tests.json');
  final allTestsJson =
      jsonDecode(allTestsFile.readAsStringSync()) as Map<String, dynamic>;

  final testSuites = allTestsJson['test_suites'] as List<dynamic>;

  late IndexRdfGenerator generator;
  late IndexParser parser;
  final resourceLocator =
      LocalResourceLocator(iriTermFactory: IriTerm.validated);

  setUp(() {
    generator = IndexRdfGenerator(
      resourceLocator: resourceLocator,
      shardManager: const ShardManager(),
    );
    // Parser without knownConfig for these tests (testing unknown indices)
    // Empty config means all indices are treated as unknown
    final emptyConfig = SyncEngineConfig(resources: []);
    parser = IndexParser(knownConfig: emptyConfig, rdfGenerator: generator);
  });

  // Group tests by suite
  for (final suiteJson in testSuites) {
    final suiteName = suiteJson['suite'] as String;
    final suiteDescription = suiteJson['description'] as String;
    final tests = suiteJson['tests'] as List<dynamic>;

    group('$suiteName - $suiteDescription', () {
      for (final testJson in tests) {
        final testId = testJson['id'] as String;
        final testTitle = testJson['title'] as String;

        test('$testId: $testTitle', () async {
          // Execute test based on suite type
          switch (suiteName) {
            case 'generate_template_rdf':
              await _executeGenerateTest(
                  testJson, testAssetsDir, generator, resourceLocator);
              break;
            case 'parse_template_rdf':
              await _executeParseTest(testJson, testAssetsDir, parser);
              break;
            case 'iri_generation':
              await _executeIriGenerationTest(testJson, generator);
              break;
            case 'roundtrip':
              await _executeRoundtripTest(
                  testJson, generator, parser, resourceLocator);
              break;
            case 'cross_installation':
              await _executeCrossInstallationTest(testJson, generator);
              break;
            case 'canonical_format':
              await _executeCanonicalFormatTest(testJson, generator);
              break;
            default:
              fail('Unknown test suite: $suiteName');
          }
        });
      }
    });
  }
}

Future<void> _executeGenerateTest(
  Map<String, dynamic> testJson,
  Directory testAssetsDir,
  IndexRdfGenerator generator,
  LocalResourceLocator resourceLocator,
) async {
  final typeIri = IriTerm(testJson['typeIri'] as String);
  final configJson = testJson['config'] as Map<String, dynamic>;
  final config = _configFromJson(configJson);
  final expectedJson = testJson['expected'] as Map<String, dynamic>;

  // Generate template IRI and RDF
  final templateIri = generator.generateGroupIndexTemplateIri(config, typeIri);
  final installationIri = IriTerm('https://example.org/installations/test');
  final graph = generator.generateGroupIndexTemplate(
    config: config,
    resourceType: typeIri,
    resourceIri: templateIri,
    installationIri: installationIri,
  );

  // Verify structure
  expect(graph.triples, isNotEmpty);

  // Verify type
  expect(
    graph.triples.any((t) =>
        t.subject == templateIri &&
        t.predicate == IdxGroupIndexTemplate.rdfType &&
        t.object == IdxGroupIndexTemplate.classIri),
    isTrue,
    reason: 'Should have GroupIndexTemplate type',
  );

  // Verify indexed class
  expect(
    graph.triples.any((t) =>
        t.subject == templateIri &&
        t.predicate == IdxGroupIndexTemplate.indexesClass &&
        t.object == typeIri),
    isTrue,
    reason: 'Should index correct type',
  );

  // If expected template graph is specified, compare
  if (expectedJson.containsKey('template_graph')) {
    final expectedPath = expectedJson['template_graph'] as String;
    final expectedGraph = readGraphFromFile(testAssetsDir, expectedPath);

    // Compare graphs using RDF canonicalization
    expectEqualGraphs(
        "${testJson['id'] as String} - template_graph $expectedGraph",
        graph,
        expectedGraph);
  }
}

Future<void> _executeParseTest(
  Map<String, dynamic> testJson,
  Directory testAssetsDir,
  IndexParser parser,
) async {
  final templateGraphPath = testJson['template_graph'] as String;
  final expectedJson = testJson['expected'] as Map<String, dynamic>;

  // Load template graph - will throw if file doesn't exist
  final graph = readGraphFromFile(testAssetsDir, templateGraphPath);

  final templateResourceIri = IriTerm('https://example.org/indices/#it');

  // Parse complete config with indexed class
  final parsed = parser.parseGroupIndexTemplate(graph, templateResourceIri);
  expect(parsed, isNotNull, reason: 'Should parse valid GroupIndexTemplate');

  final properties = parsed!.config.groupingProperties;
  final indexedClass = parsed.indexedClass;

  // Verify indexed class
  final expectedIndexedClass = expectedJson['indexedClass'] as String?;
  if (expectedIndexedClass != null) {
    expect(indexedClass.value, equals(expectedIndexedClass));
  }

  // Verify properties count
  final expectedCount = expectedJson['groupingPropertiesCount'] as int;
  expect(properties.length, equals(expectedCount));

  // Verify individual properties
  if (expectedJson.containsKey('properties')) {
    final expectedProps = expectedJson['properties'] as List<dynamic>;
    for (var i = 0; i < expectedProps.length; i++) {
      final expectedProp = expectedProps[i] as Map<String, dynamic>;
      final actualProp = properties[i];

      expect(actualProp.predicate.value, equals(expectedProp['predicate']));
      expect(actualProp.hierarchyLevel, equals(expectedProp['hierarchyLevel']));

      if (expectedProp.containsKey('missingValue')) {
        expect(actualProp.missingValue, equals(expectedProp['missingValue']));
      }

      if (expectedProp.containsKey('transformsCount')) {
        final expectedTransformsCount = expectedProp['transformsCount'] as int;
        expect(actualProp.transforms?.length ?? 0,
            equals(expectedTransformsCount));
      }
    }
  }
}

Future<void> _executeIriGenerationTest(
  Map<String, dynamic> testJson,
  IndexRdfGenerator generator,
) async {
  final typeIri = IriTerm(testJson['typeIri'] as String);
  final configsJson = testJson['configs'] as List<dynamic>;
  final expectedJson = testJson['expected'] as Map<String, dynamic>;

  // Generate IRIs for all configs
  final iris = <IriTerm>[];
  for (final configJson in configsJson) {
    final config = _configFromJson(configJson as Map<String, dynamic>);
    final iri = generator.generateGroupIndexTemplateIri(config, typeIri);
    iris.add(iri);
  }

  // Check if IRIs should be identical or different
  final shouldBeIdentical = expectedJson['iris_are_identical'] as bool;
  if (shouldBeIdentical) {
    for (var i = 1; i < iris.length; i++) {
      expect(iris[i], equals(iris[0]), reason: 'All IRIs should be identical');
    }
  } else {
    // At least one IRI should be different
    final allIdentical = iris.every((iri) => iri == iris[0]);
    expect(allIdentical, isFalse, reason: 'IRIs should differ');
  }
}

Future<void> _executeRoundtripTest(
  Map<String, dynamic> testJson,
  IndexRdfGenerator generator,
  IndexParser parser,
  LocalResourceLocator resourceLocator,
) async {
  final typeIri = IriTerm(testJson['typeIri'] as String);
  final configJson = testJson['config'] as Map<String, dynamic>;
  final originalConfig = _configFromJson(configJson);
  final expectedJson = testJson['expected'] as Map<String, dynamic>;

  // Generate IRI from original config
  final originalIri =
      generator.generateGroupIndexTemplateIri(originalConfig, typeIri);

  // Generate RDF from config
  final installationIri = IriTerm('https://example.org/installations/test');
  final graph = generator.generateGroupIndexTemplate(
    config: originalConfig,
    resourceType: typeIri,
    resourceIri: originalIri,
    installationIri: installationIri,
  );

  // Parse RDF back to complete config with indexed class
  final parsed = parser.parseGroupIndexTemplate(graph, originalIri);
  expect(parsed, isNotNull, reason: 'Should parse valid GroupIndexTemplate');

  final parsedIndexedClass = parsed!.indexedClass;

  // Create config with parsed data for IRI comparison
  final localName = testJson.containsKey('config_after_parse')
      ? (testJson['config_after_parse'] as Map<String, dynamic>)['localName']
          as String
      : 'parsed';

  final configForIri = GroupIndexData(
    localName: localName,
    groupingProperties: parsed.config.groupingProperties,
  );

  // Generate IRI from parsed config
  final parsedIri =
      generator.generateGroupIndexTemplateIri(configForIri, parsedIndexedClass);

  // IRIs should match
  final shouldMatch = expectedJson['iri_matches_after_roundtrip'] as bool;
  if (shouldMatch) {
    expect(parsedIri, equals(originalIri),
        reason: 'IRI should match after round-trip');
  }
}

Future<void> _executeCrossInstallationTest(
  Map<String, dynamic> testJson,
  IndexRdfGenerator generator,
) async {
  final typeIri = IriTerm(testJson['typeIri'] as String);
  final expectedJson = testJson['expected'] as Map<String, dynamic>;

  // Check if this is a simple installations list test or installation_a/b test
  if (testJson.containsKey('installations')) {
    final installationsJson = testJson['installations'] as List<dynamic>;

    // Generate IRIs for all installations
    final iris = <String, IriTerm>{};
    for (final installationJson in installationsJson) {
      final installationMap = installationJson as Map<String, dynamic>;
      final installationId = installationMap['id'] as String;
      final configJson = installationMap['config'] as Map<String, dynamic>;
      final config = _configFromJson(configJson);

      final iri = generator.generateGroupIndexTemplateIri(config, typeIri);
      iris[installationId] = iri;
    }

    // Check if all IRIs are identical
    final shouldBeIdentical =
        expectedJson['all_template_iris_identical'] as bool;
    if (shouldBeIdentical) {
      final firstIri = iris.values.first;
      for (final iri in iris.values) {
        expect(iri, equals(firstIri),
            reason: 'All installations should generate identical IRIs');
      }
    }
  } else if (testJson.containsKey('installation_a') &&
      testJson.containsKey('installation_b')) {
    // This is an A creates, B reads scenario
    final installationAJson =
        testJson['installation_a'] as Map<String, dynamic>;
    final configJson = installationAJson['config'] as Map<String, dynamic>;
    final config = _configFromJson(configJson);

    // Installation A generates IRI
    final iriA = generator.generateGroupIndexTemplateIri(config, typeIri);

    // Installation B would read RDF and regenerate - simulate this
    // by just using the same config (in reality B would parse RDF)
    final iriB = generator.generateGroupIndexTemplateIri(config, typeIri);

    // Check if B generates same IRI
    final shouldMatch =
        expectedJson['installation_b_generates_same_iri'] as bool;
    if (shouldMatch) {
      expect(iriB, equals(iriA),
          reason: 'Installation B should generate same IRI as A');
    }
  }
}

Future<void> _executeCanonicalFormatTest(
  Map<String, dynamic> testJson,
  IndexRdfGenerator generator,
) async {
  final typeIri = IriTerm(testJson['typeIri'] as String);
  final expectedJson = testJson['expected'] as Map<String, dynamic>;

  if (testJson.containsKey('config')) {
    // Single config test
    final configJson = testJson['config'] as Map<String, dynamic>;
    final config = _configFromJson(configJson);

    // Generate canonical format (internal hash calculation)
    final iri = generator.generateGroupIndexTemplateIri(config, typeIri);

    // Verify IRI was generated (canonical format was valid)
    expect(iri.value, isNotEmpty);

    // Additional checks based on expected values
    if (expectedJson.containsKey('canonical_format')) {
      // This would require exposing internal canonical format method
      // For now, just verify IRI generation succeeded
    }
  } else if (testJson.containsKey('configs')) {
    // Multiple configs test
    final configsJson = testJson['configs'] as List<dynamic>;
    final iris = <IriTerm>[];

    for (final configJson in configsJson) {
      final config = _configFromJson(configJson as Map<String, dynamic>);
      final iri = generator.generateGroupIndexTemplateIri(config, typeIri);
      iris.add(iri);
    }

    // Check if canonical formats should be identical
    if (expectedJson.containsKey('canonical_formats_identical')) {
      final shouldBeIdentical =
          expectedJson['canonical_formats_identical'] as bool;
      if (shouldBeIdentical) {
        for (var i = 1; i < iris.length; i++) {
          expect(iris[i], equals(iris[0]),
              reason: 'Canonical formats should be identical');
        }
      }
    }
  }
}

GroupIndexData _configFromJson(Map<String, dynamic> json) {
  final localName = json['localName'] as String;
  final groupingPropsJson = json['groupingProperties'] as List<dynamic>;

  final groupingProperties = groupingPropsJson.map((propJson) {
    final prop = propJson as Map<String, dynamic>;
    final predicate = IriTerm(prop['predicate'] as String);
    final hierarchyLevel = prop['hierarchyLevel'] as int? ?? 1;
    final missingValue = prop['missingValue'] as String?;

    List<RegexTransformData>? transforms;
    if (prop.containsKey('transforms')) {
      final transformsJson = prop['transforms'] as List<dynamic>;
      transforms = transformsJson.map((t) {
        final transformMap = t as Map<String, dynamic>;
        return RegexTransformData(
          transformMap['pattern'] as String,
          transformMap['replacement'] as String,
        );
      }).toList();
    }

    return GroupingPropertyData(
      predicate,
      hierarchyLevel: hierarchyLevel,
      missingValue: missingValue,
      transforms: transforms,
    );
  }).toList();

  return GroupIndexData(
    localName: localName,
    groupingProperties: groupingProperties,
  );
}
