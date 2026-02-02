import 'package:locorda_core/src/config/sync_engine_config.dart';
import 'package:locorda_core/src/mapping/resource_locator.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:logging/logging.dart';

final _log = Logger('IriTranslator');

/// Translates between external (user-friendly) and internal (canonical) IRIs
///
/// External IRIs follow custom templates (e.g., https://example.com/categories/work)
/// Internal IRIs use the LocalResourceLocator format (tag:locorda.org,2025:l:...)
///
/// This enables applications to work with friendly URIs while the framework
/// uses stable, structured identifiers internally.
abstract interface class IriTranslator {
  bool get canTranslate;

  /// Translates an external IRI to internal IRI
  ///
  /// If the IRI matches a documentIriTemplate, extracts the ID and converts to internal format.
  /// If no template matches, returns the IRI unchanged (already internal or unmanaged).
  ///
  /// Example:
  /// - Input: https://example.com/categories/work#it
  /// - Output: tag:locorda.org,2025:l:aHR0...#it
  IriTerm externalToInternal(IriTerm externalIri);

  /// Translates an internal IRI to external IRI
  ///
  /// If the IRI is a LocalResourceLocator IRI and has a documentIriTemplate configured,
  /// converts to the external format. Otherwise returns unchanged.
  ///
  /// Example:
  /// - Input: tag:locorda.org,2025:l:aHR0...#it
  /// - Output: https://example.com/categories/work#it
  IriTerm internalToExternal(IriTerm internalIri);

  /// Translates all IRIs in a graph from external to internal format
  ///
  /// Converts all subject, predicate, and object IRIs that match configured templates
  RdfGraph translateGraphToInternal(RdfGraph externalGraph);
  RdfDataset translateDatasetToInternal(RdfDataset externalDataset);

  /// Translates all IRIs in a graph from internal to external format
  ///
  /// Converts all subject, predicate, and object IRIs that have templates configured
  RdfGraph translateGraphToExternal(RdfGraph internalGraph);
  RdfDataset translateDatasetToExternal(RdfDataset internalDataset);

  static IriTranslator forConfig(
      {required ResourceLocator resourceLocator,
      required List<ResourceConfigData> resourceConfigs}) {
    final configByType = {
      for (final config in resourceConfigs) config.typeIri: config
    };
    final Map<String, IriTerm> prefixToType = {};
    for (final config in resourceConfigs) {
      final template = config.documentIriTemplate;
      if (template != null) {
        prefixToType[template.prefix] = config.typeIri;
      }
    }
    if (prefixToType.isEmpty) {
      return const NoOpIriTranslator();
    }
    return BaseIriTranslator(
      internalResourceLocator: resourceLocator,
      externalResourceLocator: AppResourceLocator._(
          configByType: configByType, prefixToType: prefixToType),
    );
  }
}

class NoOpIriTranslator implements IriTranslator {
  const NoOpIriTranslator();
  @override
  bool get canTranslate => false;

  @override
  IriTerm externalToInternal(IriTerm externalIri) => externalIri;

  @override
  IriTerm internalToExternal(IriTerm internalIri) => internalIri;

  @override
  RdfGraph translateGraphToExternal(RdfGraph internalGraph) => internalGraph;

  @override
  RdfGraph translateGraphToInternal(RdfGraph externalGraph) => externalGraph;

  @override
  RdfDataset translateDatasetToExternal(RdfDataset internalDataset) =>
      internalDataset;

  @override
  RdfDataset translateDatasetToInternal(RdfDataset externalDataset) =>
      externalDataset;
}

class BaseIriTranslator implements IriTranslator {
  final ResourceLocator _internalResourceLocator;
  final ResourceLocator _externalResourceLocator;

  BaseIriTranslator(
      {required ResourceLocator internalResourceLocator,
      required ResourceLocator externalResourceLocator})
      : _internalResourceLocator = internalResourceLocator,
        _externalResourceLocator = externalResourceLocator;

  bool get canTranslate => _internalResourceLocator != _externalResourceLocator;

  /// Translates an external IRI to internal IRI
  ///
  /// If the IRI matches a documentIriTemplate, extracts the ID and converts to internal format.
  /// If no template matches, returns the IRI unchanged (already internal or unmanaged).
  ///
  /// Example:
  /// - Input: https://example.com/categories/work#it
  /// - Output: tag:locorda.org,2025:l:aHR0...#it
  IriTerm externalToInternal(IriTerm externalIri) => _convert(
      externalIri,
      _externalResourceLocator,
      "external",
      _internalResourceLocator,
      "internal");

  /// Translates an internal IRI to external IRI
  ///
  /// If the IRI is a LocalResourceLocator IRI and has a documentIriTemplate configured,
  /// converts to the external format. Otherwise returns unchanged.
  ///
  /// Example:
  /// - Input: tag:locorda.org,2025:l:aHR0...#it
  /// - Output: https://example.com/categories/work#it
  IriTerm internalToExternal(IriTerm internalIri) => _convert(
      internalIri,
      _internalResourceLocator,
      "internal",
      _externalResourceLocator,
      "external");

  IriTerm _convert(IriTerm iri, ResourceLocator fromLocator, String fromName,
      ResourceLocator toLocator, String toName) {
    if (!canTranslate) {
      return iri;
    }
    if (!fromLocator.isIdentifiableIri(iri)) {
      // IRI not identifiable by fromLocator - return unchanged
      return iri;
    }
    final ResourceIdentifier resourceIdentifier;
    try {
      resourceIdentifier = fromLocator.fromIri(iri);
    } on UnsupportedIriException catch (e) {
      _log.warning(
          'Failed to extract ResourceIdentifier from $fromName IRI ${iri.debug}: $e');
      return iri;
    }
    try {
      return toLocator.toIri(resourceIdentifier);
    } on UnsupportedIriException catch (e) {
      _log.warning(
          'Failed to convert ResourceIdentifier to $toName IRI for $fromName IRI ${iri.debug}: $e');
      return iri;
    }
  }

  RdfDataset _convertDataset(
      RdfDataset dataset,
      RdfGraph Function(RdfGraph) graphConverter,
      IriTerm Function(IriTerm) iriConverter) {
    if (!canTranslate) {
      return dataset;
    }
    final defaultGraph = graphConverter(dataset.defaultGraph);
    final namedGraphs = <RdfGraphName, RdfGraph>{};
    for (final namedGraph in dataset.namedGraphs) {
      namedGraphs[switch (namedGraph.name) {
        IriTerm iri => iriConverter(iri),
        BlankNodeTerm b => b
      }] = graphConverter(namedGraph.graph);
    }
    return RdfDataset(
      defaultGraph: defaultGraph,
      namedGraphs: namedGraphs,
    );
  }

  @override
  RdfDataset translateDatasetToExternal(RdfDataset internalDataset) =>
      _convertDataset(
          internalDataset, translateGraphToExternal, internalToExternal);

  @override
  RdfDataset translateDatasetToInternal(RdfDataset externalDataset) =>
      _convertDataset(
          externalDataset, translateGraphToInternal, externalToInternal);

  /// Translates all IRIs in a graph from external to internal format
  ///
  /// Converts all subject, predicate, and object IRIs that match configured templates
  RdfGraph translateGraphToInternal(RdfGraph externalGraph) {
    if (!canTranslate) {
      return externalGraph;
    }
    final triples = externalGraph.triples.map((triple) {
      final subject = switch (triple.subject) {
        IriTerm iri => externalToInternal(iri),
        _ => triple.subject,
      };

      // Predicates are always IriTerms
      final predicate =
          externalToInternal(triple.predicate as IriTerm) as RdfPredicate;

      final object = switch (triple.object) {
        IriTerm iri => externalToInternal(iri),
        _ => triple.object,
      };

      return Triple(subject, predicate, object);
    });

    return RdfGraph.fromTriples(triples);
  }

  /// Translates all IRIs in a graph from internal to external format
  ///
  /// Converts all subject, predicate, and object IRIs that have templates configured
  RdfGraph translateGraphToExternal(RdfGraph internalGraph) {
    if (!canTranslate) {
      return internalGraph;
    }
    final triples = internalGraph.triples.map((triple) {
      final subject = switch (triple.subject) {
        IriTerm iri => internalToExternal(iri),
        _ => triple.subject,
      };

      // Predicates are always IriTerms
      final predicate =
          internalToExternal(triple.predicate as IriTerm) as RdfPredicate;

      final object = switch (triple.object) {
        IriTerm iri => internalToExternal(iri),
        _ => triple.object,
      };

      return Triple(subject, predicate, object);
    });

    return RdfGraph.fromTriples(triples);
  }
}

class AppResourceLocator extends ResourceLocator {
  final Map<IriTerm, ResourceConfigData> _configByType;

  /// Maps external IRI prefixes to their type IRIs for efficient lookup
  final Map<String, IriTerm> _prefixToType;

  AppResourceLocator._(
      {required Map<IriTerm, ResourceConfigData> configByType,
      required Map<String, IriTerm> prefixToType})
      : _configByType = configByType,
        _prefixToType = prefixToType;

  @override
  ResourceIdentifier fromIri(IriTerm externalIri, {IriTerm? expectedTypeIri}) {
    // Extract IRI value
    final iriValue = externalIri.value;

    // Extract fragment if present
    final fragmentIndex = iriValue.indexOf('#');
    final documentIriValue =
        fragmentIndex >= 0 ? iriValue.substring(0, fragmentIndex) : iriValue;
    final fragment =
        fragmentIndex >= 0 ? iriValue.substring(fragmentIndex + 1) : null;

    // Try to match against templates using prefix lookup
    for (final entry in _prefixToType.entries) {
      final prefix = entry.key;
      if (!documentIriValue.startsWith(prefix)) continue;

      final typeIri = entry.value;
      final config = _configByType[typeIri]!;
      final template = config.documentIriTemplate!;
      if (typeIri != expectedTypeIri && expectedTypeIri != null) {
        throw UnsupportedIriException(externalIri,
            'with type ${typeIri.value} does not match expected type IRI ${expectedTypeIri.value}.');
      }
      final id = template.extractId(documentIriValue);
      if (id != null) {
        // Found a match - convert to internal IRI
        return fragment != null
            ? ResourceIdentifier(typeIri, id, fragment)
            : ResourceIdentifier.document(typeIri, id);
      }
    }
    throw UnsupportedIriException(
        externalIri, 'is not identifiable by any configured template.');
  }

  @override
  IriTerm toIri(ResourceIdentifier identifier) {
    final typeIri = identifier.typeIri;
    final config = _configByType[typeIri];
    if (config?.documentIriTemplate != null) {
      // Successfully extracted - convert to external IRI
      final template = config!.documentIriTemplate!;
      final externalDocumentIri = template.toIri(identifier.id);
      final externalIriValue = identifier.fragment != null
          ? '$externalDocumentIri#${identifier.fragment}'
          : externalDocumentIri;

      return IriTerm(externalIriValue);
    }
    throw UnsupportedIriException.forResourceIdentifier(identifier,
        'Cannot convert to external IRI - no template configured for type ${typeIri.value}.');
  }
}
