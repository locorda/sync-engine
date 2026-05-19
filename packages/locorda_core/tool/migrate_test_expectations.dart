/// Script to migrate test expectations from old format to new unified documents format.
///
/// Converts:
/// - stored_graph
/// - installation
/// - index_documents[].expected_graph
/// - group_index_documents[].expected_graph
/// - shard_documents[].expected_graph
///
/// To unified documents list with type_iri, id, and path.
library;
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import '../test/util/rdf_test_utils.dart';

void main() async {
  final testAssetsDir = Directory('test/assets/graph');
  final allTestsFile = File('${testAssetsDir.path}/all_tests.json');

  print('Reading all_tests.json...');
  final content = allTestsFile.readAsStringSync();
  final allTestsJson = jsonDecode(content) as Map<String, dynamic>;

  int totalStepsProcessed = 0;
  int totalDocumentsAdded = 0;

  // Process each test suite
  final testSuites = allTestsJson['test_suites'] as List<dynamic>;
  for (final suiteJson in testSuites) {
    final suiteName = suiteJson['suite'] as String;
    final tests = suiteJson['tests'] as List<dynamic>;

    print('\nProcessing suite: $suiteName');

    for (final testJson in tests) {
      final testId = testJson['id'] as String;
      final steps = testJson['steps'] as List<dynamic>?;

      if (steps == null) continue;

      for (final stepJson in steps) {
        final stepMap = stepJson as Map<String, dynamic>;
        final expectedJson = stepMap['expected'] as Map<String, dynamic>?;

        if (expectedJson == null) continue;

        totalStepsProcessed++;

        // Collect all document paths
        final documents = <Map<String, dynamic>>[];

        // Check if documents already exists - if yes, skip collection but still remove old fields
        final alreadyMigrated = expectedJson.containsKey('documents');

        // 1. stored_graph
        final storedGraphPath = expectedJson['stored_graph'] as String?;
        if (storedGraphPath != null && !alreadyMigrated) {
          try {
            final resId =
                extractTypeIdFromStoredPath(testAssetsDir, storedGraphPath);
            documents.add({
              'type_iri': resId.typeIri.value,
              'id': resId.id,
              'path': storedGraphPath,
            });
            print('  [$testId] Added stored_graph: ${resId.id}');
          } catch (e) {
            print(
                '  [$testId] WARNING: Could not extract from $storedGraphPath: $e');
          }
        }

        // 2. installation
        final installationPath = expectedJson['installation'] as String?;
        if (installationPath != null && !alreadyMigrated) {
          try {
            final resId =
                extractTypeIdFromStoredPath(testAssetsDir, installationPath);
            documents.add({
              'type_iri': resId.typeIri.value,
              'id': resId.id,
              'path': installationPath,
            });
            print('  [$testId] Added installation: ${resId.id}');
          } catch (e) {
            print(
                '  [$testId] WARNING: Could not extract from $installationPath: $e');
          }
        }

        // 3. index_documents
        final indexDocs = expectedJson['index_documents'] as List<dynamic>?;
        if (indexDocs != null && !alreadyMigrated) {
          for (final indexDocJson in indexDocs) {
            final indexMap = indexDocJson as Map<String, dynamic>;
            final path = indexMap['expected_graph'] as String;
            try {
              final resId = extractTypeIdFromStoredPath(testAssetsDir, path);
              documents.add({
                'type_iri': resId.typeIri.value,
                'id': resId.id,
                'path': path,
              });
              print('  [$testId] Added index: ${resId.id}');
            } catch (e) {
              print('  [$testId] WARNING: Could not extract from $path: $e');
            }
          }
        }

        // 4. group_index_documents
        final groupIndexDocs =
            expectedJson['group_index_documents'] as List<dynamic>?;
        if (groupIndexDocs != null && !alreadyMigrated) {
          for (final groupIndexDocJson in groupIndexDocs) {
            final groupIndexMap = groupIndexDocJson as Map<String, dynamic>;
            final path = groupIndexMap['expected_graph'] as String;
            try {
              final resId = extractTypeIdFromStoredPath(testAssetsDir, path);
              documents.add({
                'type_iri': resId.typeIri.value,
                'id': resId.id,
                'path': path,
              });
              print('  [$testId] Added group_index: ${resId.id}');
            } catch (e) {
              print('  [$testId] WARNING: Could not extract from $path: $e');
            }
          }
        }

        // 5. shard_documents
        final shardDocs = expectedJson['shard_documents'] as List<dynamic>?;
        if (shardDocs != null && !alreadyMigrated) {
          for (final shardDocJson in shardDocs) {
            final shardMap = shardDocJson as Map<String, dynamic>;
            final path = shardMap['expected_graph'] as String;
            try {
              final resId = extractTypeIdFromStoredPath(testAssetsDir, path);
              documents.add({
                'type_iri': resId.typeIri.value,
                'id': resId.id,
                'path': path,
              });
              print('  [$testId] Added shard: ${resId.id}');
            } catch (e) {
              print('  [$testId] WARNING: Could not extract from $path: $e');
            }
          }
        }

        // Add documents list if we found any (and not already migrated)
        if (documents.isNotEmpty && !alreadyMigrated) {
          expectedJson['documents'] = documents;
          totalDocumentsAdded += documents.length;
          print(
              '  [$testId] ✓ Added ${documents.length} documents to new format');
        }

        // Always remove old format fields if any exist
        var removedCount = 0;
        if (expectedJson.remove('stored_graph') != null) removedCount++;
        if (expectedJson.remove('installation') != null) removedCount++;
        if (expectedJson.remove('index_documents') != null) removedCount++;
        if (expectedJson.remove('group_index_documents') != null) {
          removedCount++;
        }
        if (expectedJson.remove('shard_documents') != null) removedCount++;

        if (removedCount > 0) {
          print('  [$testId] ✓ Removed $removedCount old format fields');
        }
      }
    }
  }

  // Write back to file
  print('\n\nWriting updated all_tests.json...');
  final encoder = JsonEncoder.withIndent('  ');
  final updatedContent = encoder.convert(allTestsJson);
  await allTestsFile.writeAsString(updatedContent);

  print('\n✅ Migration complete!');
  print('   Steps processed: $totalStepsProcessed');
  print('   Documents added: $totalDocumentsAdded');
  print('\n⚠️  Old format fields have been removed!');
}
