import 'package:logging/logging.dart';

import 'package:locorda_rdf_core/core.dart';

final _log = Logger("solid.profile");

class Solid {
  static const String namespace = "http://www.w3.org/ns/solid/terms#";
  static const IriTerm storage = IriTerm("${namespace}storage");
  static const IriTerm location = IriTerm("${namespace}location");
}

class Pim {
  static const String namespace = "http://www.w3.org/ns/pim/space#";
  static const IriTerm storage = IriTerm("${namespace}storage");
}

/// Implementation for parsing Solid profile documents
class SolidProfileParser {
  static const _knownWebIdSuffixes = ['/profile/card#me'];

  /// Find storage URLs in the parsed graph
  List<String> _findStorageUrls(RdfGraph graph) {
    try {
      // Note: this storage predicate actually is not part of the Solid spec,
      // it is a workaround for buggy implementations.
      final storageTriples = graph.findTriples(predicate: Solid.storage);
      // This is the correct location.
      final spaceStorageTriples = graph.findTriples(predicate: Pim.storage);

      final urls = <String>[];
      for (final triple in [...storageTriples, ...spaceStorageTriples]) {
        _addIri(triple, urls, graph);
      }

      return urls;
    } catch (e, stackTrace) {
      _log.severe('Failed to find storage URLs', e, stackTrace);
      rethrow;
    }
  }

  void _addIri(Triple triple, List<String> urls, RdfGraph graph) {
    switch (triple.object) {
      case final IriTerm iriTerm:
        // If the storage points to an IRI, add it directly
        urls.add(iriTerm.value);
        break;
      case final BlankNodeTerm blankNodeTerm:
        // If the storage points to a blank node, look for location triples
        final locationTriples = graph.findTriples(
          subject: blankNodeTerm,
          predicate: Solid.location,
        );
        for (final locationTriple in locationTriples) {
          _addIri(locationTriple, urls, graph);
        }
        break;
      case LiteralTerm _:
        _log.warning(
          'Storage points to a literal, ignoring it: ${triple.object}',
        );
        // If the storage points to a literal, ignore it
        break;
    }
  }

  Future<String?> parseStorageUrl(
    String webId,
    RdfGraph graph,
  ) async {
    try {
      try {
        final storageUrls = _findStorageUrls(graph);
        if (storageUrls.isNotEmpty) {
          _log.info('Found storage URL: ${storageUrls.first}');
          return storageUrls.first;
        }
        for (final ending in _knownWebIdSuffixes) {
          if (webId.endsWith(ending)) {
            final storageUrl =
                "${webId.substring(0, webId.length - ending.length)}/";
            _log.info(
              'Did not find predicate ${Pim.storage}. Using root of WebID as storage URL: $storageUrl',
            );
            return storageUrl;
          }
        }
        _log.warning('No storage URL found in profile document');
        return null;
      } catch (e, stackTrace) {
        _log.severe('RDF parsing failed', e, stackTrace);
        return null;
      }
    } catch (e, stackTrace) {
      _log.severe('Failed to parse profile', e, stackTrace);
      return null;
    }
  }
}
