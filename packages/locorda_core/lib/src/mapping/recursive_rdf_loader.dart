import 'package:locorda_core/src/generated/mapping_bootstrap.g.dart';
import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_core/src/vocab/generated/rdf.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

abstract interface class Fetcher {
  Future<String> fetch(String url, {String? contentType});
}

class HttpFetcher implements Fetcher {
  final http.Client httpClient;
  HttpFetcher({
    required this.httpClient,
  });

  /// Checks if the server supports content negotiation for the given URL.
  ///
  /// Returns true if the HEAD response indicates the content type matches
  /// the requested type, false otherwise.
  Future<bool> _supportsContentNegotiation(
      String url, String? contentType) async {
    if (contentType == null) return true;

    final headers = <String, String>{'Accept': contentType};
    try {
      final response = await httpClient.head(Uri.parse(url), headers: headers);
      if (response.statusCode != 200) return false;

      final responseContentType = response.headers['content-type'];
      if (responseContentType == null) return false;

      // Check if response content type matches requested type
      // Handle cases like "text/turtle; charset=utf-8"
      return responseContentType
          .toLowerCase()
          .contains(contentType.toLowerCase());
    } catch (e) {
      // If HEAD fails, assume no content negotiation support
      return false;
    }
  }

  @override
  Future<String> fetch(String url, {String? contentType}) async {
    final headers = <String, String>{};
    if (contentType != null) {
      headers['Accept'] = contentType;
    }

    // Check if server supports content negotiation
    final supportsNegotiation =
        await _supportsContentNegotiation(url, contentType);

    // If no content negotiation support and URL doesn't end with .ttl, try appending it
    var fetchUrl = url;
    if (!supportsNegotiation &&
        contentType == 'text/turtle' &&
        !url.endsWith('.ttl')) {
      fetchUrl = '$url.ttl';
    }

    final response =
        await httpClient.get(Uri.parse(fetchUrl), headers: headers);
    if (response.statusCode == 200) {
      return response.body;
    } else {
      throw Exception(
          'Failed to load RDF graph at $fetchUrl: ${response.statusCode}');
    }
  }
}

class StandardRdfGraphFetcher implements RdfGraphFetcher {
  final Fetcher fetcher;
  final RdfCore rdfCore;
  StandardRdfGraphFetcher({
    required this.fetcher,
    required this.rdfCore,
  });
  @override
  Future<RdfGraph> fetch(IriTerm iri) async {
    // Parse the RDF graph from the response body
    return rdfCore.decode(
        await fetcher.fetch(iri.value, contentType: turtle.primaryMimeType),
        // Lets not assume turtle, maybe the fetcher returns some other content type - but we can still try to decode it as RDF
        // contentType: turtle.primaryMimeType,
        documentUrl: iri.value);
  }
}

class BootstrapRdfGraphFetcher implements RdfGraphFetcher {
  static final _log = Logger('BootstrapOnlyRdfGraphFetcher');
  final RdfCore rdfCore;
  final IriTermFactory iriFactory;
  final Iterable<String>? _bootstrapSources;

  // Lazy-initialized map of document IRI to decoded RdfGraph for bootstrap sources
  // only if we actually need to do bootstrap - to avoid unnecessary decoding at startup for
  // subsequent startups after the first one
  late final Map<IriTerm, RdfGraph> _bootstrapSourcesMap =
      _buildBootstrapMap(_bootstrapSources);
  final RdfGraphFetcher? onlineFetcher;

  BootstrapRdfGraphFetcher({
    required this.rdfCore,
    required this.iriFactory,
    required Iterable<String>? bootstrapSources,
    this.onlineFetcher,
  }) : _bootstrapSources = bootstrapSources;

  Map<IriTerm, RdfGraph> _buildBootstrapMap(
      Iterable<String>? bootstrapSources) {
    final allSources = [...bootstrapMappings, ...?bootstrapSources];
    final graphEntries =
        allSources.expand<MapEntry<IriTerm, RdfGraph>>((source) {
      final dataset = rdfCore.decodeDataset(source);
      final graph = dataset.defaultGraph;

      return [
        if (graph.isNotEmpty)
          MapEntry(_extractDocumentIri(graph, iriFactory), graph),
        for (final e in dataset.namedGraphs)
          MapEntry((e.name as IriTerm).getDocumentIri(iriFactory), e.graph)
      ];
    });
    return Map.fromEntries(graphEntries);
  }

  static IriTerm _extractDocumentIri(
          RdfGraph graph, IriTermFactory iriFactory) =>
      graph.getIdentifier(Mc.DocumentMapping).getDocumentIri(iriFactory);

  @override
  Future<RdfGraph> fetch(IriTerm iri) async {
    final documentIri = iri.getDocumentIri(iriFactory);
    final bootstrapContent = _bootstrapSourcesMap[documentIri];
    if (bootstrapContent == null) {
      if (onlineFetcher != null) {
        try {
          _log.info(
              'No bootstrap mapping for ${documentIri.value} - got sources for ${_bootstrapSourcesMap.keys.map((k) => k.value).join(', ')}, attempting online fetch');
          return await onlineFetcher!.fetch(iri);
        } catch (e) {
          // ignore and fall back to error below
          throw Exception(
              'No bootstrap mapping for ${documentIri.value} and online fetch failed: $e');
        }
      }
      throw Exception('No bootstrap mapping for ${documentIri.value}');
    }
    return bootstrapContent;
  }
}

abstract interface class RdfGraphFetcher {
  Future<RdfGraph> fetch(IriTerm iri);
}

abstract interface class DependencyExtractor {
  IriTerm? forType();
  Iterable<IriTerm> extractDependencies(RdfSubject subj, RdfGraph graph);
}

class RecursiveRdfLoader {
  final IriTermFactory iriFactory;
  final RdfGraphFetcher fetcher;

  // Contracts usually do not change - so we can cache loaded graphs
  // across the lifetime of the application instance
  final Map<IriTerm, RdfGraph> _loadedContracts = {};
  final Map<IriTerm, Future<RdfGraph>> _inProgress = {};
  RecursiveRdfLoader({required this.fetcher, required this.iriFactory});

  Future<void> _loadRecursivelySingle(
      IriTerm inputIri,
      Map<IriTerm, RdfGraph> loadedContracts,
      Map<IriTerm, Future<RdfGraph>> inProgress,
      {List<DependencyExtractor> extractors = const []}) async {
    final iri = inputIri.getDocumentIri(iriFactory);
    // Check if already loaded
    if (loadedContracts.containsKey(iri)) return;

    // Check if currently being loaded, and wait for it
    if (inProgress.containsKey(iri)) {
      final graph = await inProgress[iri]!;
      loadedContracts[iri] = graph;
      return;
    }

    // Start loading and track the future
    final future = fetcher.fetch(iri);
    inProgress[iri] = future;

    final graph = await future;
    if (graph.findTriples(subject: inputIri, predicate: Rdf.type).isEmpty) {
      throw Exception(
          'Loaded graph from document $iri does not contain the requested IRI $inputIri as subject with rdf:type. '
          'Is this really a valid mapping document? '
          'Graph contains the subjects: ${graph.subjects.map((s) => s.toString()).join(', ')}');
    }
    loadedContracts[iri] = graph;
    inProgress.remove(iri);

    // Extract isGovernedBy IRIs from the graph.
    // Use inputIri (potentially with fragment) for the type lookup and dependency
    // extraction, because mapping sources may use explicit fragment subjects
    // (e.g. <note-v1#>) rather than resolving via <> relative to a base.
    final type = graph.findSingleObject<IriTerm>(inputIri, Rdf.type);
    final dependencies = <IriTerm>{};
    for (final extractor in extractors) {
      if (extractor.forType() == null || extractor.forType() == type) {
        final deps = extractor.extractDependencies(inputIri, graph);
        dependencies.addAll(deps.map((iri) => iri.getDocumentIri(iriFactory)));
      }
    }

    await _loadRecursivelyMulti(dependencies, loadedContracts, inProgress,
        extractors: extractors);
  }

  /// Returns a map of document IRI to loaded RdfGraph, loading dependencies determined by extractors recursively.
  Future<Map<IriTerm, RdfGraph>> loadRdfDocumentsRecursively(
          Iterable<IriTerm> iris,
          {List<DependencyExtractor> extractors = const []}) =>
      _loadRecursivelyMulti(iris, _loadedContracts, _inProgress,
          extractors: extractors);

  Future<Map<IriTerm, RdfGraph>> _loadRecursivelyMulti(
      Iterable<IriTerm> iris,
      Map<IriTerm, RdfGraph> loadedContracts,
      Map<IriTerm, Future<RdfGraph>> inProgress,
      {List<DependencyExtractor> extractors = const []}) async {
    if (iris.isNotEmpty) {
      // Process all IRIs concurrently for better performance
      await Future.wait(iris.map((iri) => _loadRecursivelySingle(
          iri, loadedContracts, inProgress,
          extractors: extractors)));
    }

    return loadedContracts;
  }
}
