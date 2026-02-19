/// Resource annotations for RDF classes with CRDT synchronization.
///
/// This library provides annotations for defining RDF resources that sync across
/// multiple storage backends (Solid Pods, Google Drive, local directories) using
/// state-based CRDTs for conflict-free collaboration.
library;

import 'package:locorda_rdf_mapper_annotations/annotations.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:locorda_annotations/locorda_annotations.dart';
import 'package:locorda_core/locorda_core.dart';

const resourceIriFactoryKey = r'$resourceIriFactory';
const indexItemIriFactoryKey = r'$indexItemIriFactory';
const resourceIriVar = r'rootResourceIri';

class RootIriStrategy extends IriStrategy {
  const RootIriStrategy([RootIriConfig? config])
      : super.namedFactory(
          resourceIriFactoryKey,
          config ?? const RootIriConfig(),
          // exposes the IRI of the Pod Resource as a potential provider to child resources
          resourceIriVar,
        );
}

class SubIriStrategy extends IriStrategy {
  const SubIriStrategy(String fragmentTemplate)
      : super.withFragment(
          // references the parent resource IRI via the variable we expose in PodIriStrategy
          // so that the subresource IRI can be constructed as {parentResourceIri}#fragment .
          // Note: any fragment will be removed from the parent resource IRI automatically,
          // so it is no problem at all if the parent resource IRI already has a fragment.
          '{+$resourceIriVar}',
          fragmentTemplate,
        );
}

class MergeContracts {
  static const IriTerm coreV1 =
      IriTerm('https://w3id.org/solid-crdt-sync/mappings/core-v1');
  static const IriTerm indexV1 =
      IriTerm('https://w3id.org/solid-crdt-sync/mappings/index-v1');
  static const IriTerm shardV1 =
      IriTerm('https://w3id.org/solid-crdt-sync/mappings/shard-v1');
  static const IriTerm clientInstallationV1 = IriTerm(
      'https://w3id.org/solid-crdt-sync/mappings/client-installation-v1');
}

/// CRDT mapping configuration for automatic generation or external references.
///
/// Defines how property-level CRDT merge strategies are specified for a root resource.
/// CRDT mappings are RDF documents that declare which merge algorithm (LWW, OR-Set, etc.)
/// should be used for each property when conflicts occur during synchronization.
///
/// Two modes are supported:
///
/// **Generated CRDT mappings** (default constructor):
/// ```dart
/// MergeContracts(
///   'https://myapp.example.com/mappings/note-v1#',
///   label: 'Note CRDT Mapping',
///   imports: [MergeContracts.coreV1],
/// )
/// ```
/// The builder scans `@CrdtLwwRegister`, `@CrdtOrSet`, `@CrdtImmutable` annotations
/// on properties and generates a CRDT mapping document with merge rules.
///
/// **External CRDT mappings** (`.external()` constructor):
/// ```dart
/// MergeContract.external('https://vocab.example.org/mappings/standard-note-v1#')
/// ```
/// References a manually authored or third-party CRDT mapping document. The builder
/// does not generate merge rules for this resource; the mapping must be provided separately.
class MergeContract {
  /// Canonical IRI of the CRDT mapping document.
  ///
  /// Must be a stable, app-owned IRI. Use `#` fragment for generated mappings
  /// (e.g., `https://myapp.example.com/mappings/note-v1#`).
  final String mappingIri;

  /// Optional human-readable label for generated CRDT mapping metadata.
  ///
  /// Appears as `rdfs:label` in generated merge rules. Ignored for external mappings.
  final String? label;

  /// Optional human-readable comment for generated CRDT mapping metadata.
  ///
  /// Appears as `rdfs:comment` in generated merge rules. Ignored for external mappings.
  final String? comment;

  /// Imported CRDT mapping documents for generated `mc:DocumentMapping`.
  ///
  /// Standard framework mappings like [MergeContracts.coreV1] are imported by default.
  /// Add additional imports for shared vocabularies or extension mappings.
  final List<IriTerm> imports;

  /// Whether CRDT mapping should be generated from annotations.
  ///
  /// `true` for default constructor (builder generates merge rules from CRDT annotations).
  /// `false` for `.external()` constructor (CRDT mapping provided separately).
  final bool generate;

  const MergeContract(
    this.mappingIri, {
    this.label,
    this.comment,
    this.imports = const [MergeContracts.coreV1],
  }) : generate = true;

  const MergeContract.external(this.mappingIri)
      : label = null,
        comment = null,
        imports = const [],
        generate = false;
}

/// Configuration for the default FullIndex of a root resource.
///
/// Controls whether a FullIndex is generated and its parameters.
/// Used as parameter in [RootResource.fullIndex].
class FullIndex {
  /// Whether FullIndex generation is enabled.
  final bool isEnabled;

  /// Local name for the FullIndex (default: 'default').
  final String localName;

  /// Item fetch policy for the FullIndex.
  final ItemFetchPolicy policy;

  /// Creates a FullIndex configuration with defaults.
  const FullIndex({
    this.localName = 'default',
    this.policy = ItemFetchPolicy.prefetch,
  }) : isEnabled = true;

  /// Disables FullIndex generation for this resource.
  /// Use when a resource only has GroupIndex indices.
  const FullIndex.disabled()
      : isEnabled = false,
        localName = '',
        policy = ItemFetchPolicy.prefetch;
}

/// Defines a regex transformation applied to a grouping property value.
///
/// Used within [GroupingProperty] to transform raw RDF values
/// (e.g., extracting year-month from a full date string).
class RegexTransform {
  final String pattern;
  final String replacement;

  const RegexTransform(this.pattern, this.replacement);
}

/// Defines a property used for grouping in a GroupIndex, with optional transforms.
///
/// The [property] IRI identifies which RDF predicate to group by.
/// Optional [transforms] apply regex transformations before grouping.
class GroupingProperty {
  final IriTerm property;
  final List<RegexTransform> transforms;

  const GroupingProperty(this.property, {this.transforms = const []});
}

class IndexItemIriStrategy extends IriStrategy {
  const IndexItemIriStrategy(Type resourceType)
      : super.namedFactory(indexItemIriFactoryKey, resourceType);
}
