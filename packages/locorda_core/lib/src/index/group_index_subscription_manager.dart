/// Manages group index subscriptions and group key generation.
library;

import 'package:locorda_core/src/standard_sync_engine.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:locorda_core/src/index/group_key_generator.dart';

/// Exception thrown when group index subscription validation fails.
class GroupIndexGraphSubscriptionException implements Exception {
  final String message;
  final Object? context;

  const GroupIndexGraphSubscriptionException(this.message, {this.context});

  @override
  String toString() => 'GroupIndexGraphSubscriptionException: $message';
}

/// Manages subscriptions to group indices and converts group keys to group identifiers.
///
/// This class handles:
/// - Validation of group key types against configured GroupIndex
/// - Conversion of group key objects to RDF triples
/// - Generation of group identifiers using GroupKeyGenerator
/// - Validation that group key types are properly registered
class GroupIndexGraphSubscriptionManager {
  final ConfigService _configService;

  const GroupIndexGraphSubscriptionManager({
    required ConfigService configService,
  }) : _configService = configService;

  /// Returns the set of group identifiers generated from the group key.
  Future<Set<String>> getGroupIdentifiers(
      String indexName, RdfGraph groupKeyGraph) async {
    // Step 1: Find the GroupIndex configuration for indexName
    final groupIndexConfig =
        _configService.currentConfig.findGroupIndexConfig(indexName);
    if (groupIndexConfig == null) {
      throw GroupIndexGraphSubscriptionException(
          'No GroupIndex found with indexName "$indexName". '
          'Ensure the index is configured in a GroupIndex with the specified indexName.',
          context: {
            'indexName': indexName,
          });
    }

    final (resourceConfig, groupIndex) = groupIndexConfig;

    // Step 2: Generate group identifiers using GroupKeyGenerator
    final groupKeyGenerator = GroupKeyGenerator(groupIndex);
    final groupIdentifiers =
        groupKeyGenerator.generateGroupKeys(groupKeyGraph);

    if (groupIdentifiers.isEmpty) {
      throw GroupIndexGraphSubscriptionException(
          'No group identifiers generated from group key graph. '
          'This may indicate missing required properties or invalid transforms.',
          context: {
            'indexName': indexName,
            'tripleCount': groupKeyGraph.triples.length,
          });
    }

    return groupIdentifiers;
  }
}
