/// Manages group index subscriptions and group key generation.
library;

import 'package:locorda_rdf_core/core.dart';
import 'package:locorda_rdf_mapper/mapper.dart';

import '../config/locorda_config_util.dart';
import '../config/locorda_config.dart';

class GroupKeyConverterException implements Exception {
  final String message;
  final Object? context;

  const GroupKeyConverterException(this.message, {this.context});

  @override
  String toString() => 'GroupKeyConverterException: $message';
}

/// Manages subscriptions to group indices and converts group keys to group identifiers.
///
/// This class handles:
/// - Validation of group key types against configured GroupIndex
/// - Conversion of group key objects to RDF triples
/// - Generation of group identifiers using GroupKeyGenerator
/// - Validation that group key types are properly registered
class GroupKeyConverter {
  final LocordaConfig _config;
  final RdfMapper _mapper;

  const GroupKeyConverter({
    required LocordaConfig config,
    required RdfMapper mapper,
  })  : _config = config,
        _mapper = mapper;

  /// Returns the set of group identifiers generated from the group key.
  ({String indexName, RdfGraph groupKeyGraph}) convertGroupKey<G>(G groupKey,
      {String localName = defaultIndexLocalName}) {
    // Step 1: Find the GroupIndex configuration for type G and localName
    final indexName = getGroupIndexName<G>(_config, localName);
    if (indexName == null) {
      throw GroupKeyConverterException(
          'No GroupIndex found for group key type ${G.runtimeType} with localName "$localName". '
          'Ensure the type is configured in a GroupIndex with the specified localName.',
          context: {
            'groupKeyType': G.runtimeType,
            'localName': localName,
          });
    }

    // Step 2: Convert group key to RDF triples
    final groupKeyTriples = _convertGroupKeyToTriples(groupKey);
    return (
      indexName: indexName,
      groupKeyGraph: RdfGraph.fromTriples(groupKeyTriples)
    );
  }

  /// Convert a group key object to RDF triples using the mapper.
  List<Triple> _convertGroupKeyToTriples<G>(G groupKey) {
    try {
      // Encode the group key object to RDF
      final rdfGraph = _mapper.graph.encodeObject(groupKey);

      // Return all triples from the graph
      return rdfGraph.triples.toList();
    } catch (e) {
      throw GroupKeyConverterException(
          'Failed to convert group key to RDF triples. '
          'Ensure the group key type is properly annotated and registered in the mapper.',
          context: {
            'groupKey': groupKey,
            'groupKeyType': G.runtimeType,
            'mapperError': e,
          });
    }
  }
}
