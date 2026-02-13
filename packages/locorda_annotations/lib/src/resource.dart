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

/// Constants for standard mapping document IRIs.
class LcrdMappings {
  static const IriTerm coreV1 =
      IriTerm('https://w3id.org/solid-crdt-sync/mappings/core-v1');
  static const IriTerm indexV1 =
      IriTerm('https://w3id.org/solid-crdt-sync/mappings/index-v1');
  static const IriTerm shardV1 =
      IriTerm('https://w3id.org/solid-crdt-sync/mappings/shard-v1');
  static const IriTerm clientInstallationV1 = IriTerm(
      'https://w3id.org/solid-crdt-sync/mappings/client-installation-v1');

  const LcrdMappings._();
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
/// LcrdCrdt(
///   'https://myapp.example.com/mappings/note-v1#',
///   label: 'Note CRDT Mapping',
///   imports: [LcrdMappings.coreV1],
/// )
/// ```
/// The builder scans `@CrdtLwwRegister`, `@CrdtOrSet`, `@CrdtImmutable` annotations
/// on properties and generates a CRDT mapping document with merge rules.
///
/// **External CRDT mappings** (`.external()` constructor):
/// ```dart
/// LcrdCrdt.external('https://vocab.example.org/mappings/standard-note-v1#')
/// ```
/// References a manually authored or third-party CRDT mapping document. The builder
/// does not generate merge rules for this resource; the mapping must be provided separately.
class LcrdCrdt {
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
  /// Standard framework mappings like [LcrdMappings.coreV1] are imported by default.
  /// Add additional imports for shared vocabularies or extension mappings.
  final List<IriTerm> imports;

  /// Whether CRDT mapping should be generated from annotations.
  ///
  /// `true` for default constructor (builder generates merge rules from CRDT annotations).
  /// `false` for `.external()` constructor (CRDT mapping provided separately).
  final bool generate;

  const LcrdCrdt(
    this.mappingIri, {
    this.label,
    this.comment,
    this.imports = const [LcrdMappings.coreV1],
  }) : generate = true;

  const LcrdCrdt.external(this.mappingIri)
      : label = null,
        comment = null,
        imports = const [],
        generate = false;
}

/// Annotation for top-level RDF resources with CRDT synchronization.
///
/// Marks a Dart class as a root resource that will be synchronized across storage
/// backends (Solid Pods, Google Drive, local directories) using state-based CRDTs
/// for conflict-free collaboration.
///
/// ## Basic Example
///
/// ```dart
/// @LcrdRootResource(
///   IriTerm('https://schema.org/Note'),
///   LcrdCrdt('https://myapp.example.com/mappings/note-v1#'),
/// )
/// class Note {
///   @RdfProperty(Schema.name)
///   @CrdtLwwRegister()
///   String? title;
///
///   @RdfProperty(Schema.text)
///   @CrdtLwwRegister()
///   String? content;
///
///   @RdfProperty(Schema.dateCreated)
///   @CrdtImmutable()
///   DateTime? createdAt;
/// }
/// ```
///
/// ## Resource Identification
///
/// Each resource instance is identified by an IRI (Internationalized Resource
/// Identifier) using a configurable strategy:
///
/// - **Fragment-based IRIs** (default): Resources live as fragments within
///   framework-owned RDF documents (e.g., `https://pod.example/notes/xyz.ttl#it`).
/// - **Custom strategies**: Configure via [iriStrategy] parameter using
///   [RootIriStrategy] with [RootIriConfig] options.
///
/// ## CRDT Mapping Configuration
///
/// The [crdt] parameter controls property-level merge strategies:
///
/// **Automatic generation** (recommended):
/// ```dart
/// LcrdCrdt(
///   'https://myapp.example.com/mappings/note-v1#',
///   label: 'Note CRDT Mapping',  // Optional metadata
/// )
/// ```
/// The builder scans CRDT annotations on properties and generates merge rules.
///
/// **External CRDT mapping** (for shared/standard vocabularies):
/// ```dart
/// LcrdCrdt.external('https://vocab.example.org/mappings/standard-note-v1#')
/// ```
/// References a manually authored CRDT mapping document (must be provided via assets).
///
/// ## Property-Level CRDT Types
///
/// Properties must use CRDT annotations to define merge behavior:
///
/// - `@CrdtLwwRegister()` - Last-Write-Wins (single value, default)
/// - `@CrdtOrSet()` - Observed-Remove Set (multi-value, re-addable)
/// - `@CrdtImmutable()` - Write-once, never changes
///
/// Default is LWW if no annotation present.
///
/// ## Indexing
///
/// Configure default FullIndex via [fullIndex] parameter:
/// ```dart
/// @LcrdRootResource(
///   IriTerm('https://schema.org/Note'),
///   LcrdCrdt('https://myapp.example.com/mappings/note-v1#'),
///   fullIndex: LcrdFullIndex(policy: ItemFetchPolicy.onRequest),
/// )
/// ```
///
/// Use `LcrdFullIndex.disabled()` when only GroupIndex applies.
///
/// ## Code Generation
///
/// The generator processes this annotation to create:
/// - CRDT mapping documents with merge rules (if `crdt.generate == true`)
/// - Resource configuration entries for `LocordaConfig`
/// - RDF serialization/deserialization code (Dart ↔ RDF mapping)
/// - Type-safe access to indexed properties
///
/// ## See Also
///
/// - [LcrdCrdt] - CRDT mapping configuration
/// - [LcrdSubResource] - Nested resources within a root resource
/// - [RdfGlobalResource] - Base RDF resource annotation
/// - CRDT annotations: [CrdtLwwRegister], [CrdtOrSet], [CrdtImmutable]
class LcrdRootResource extends RdfGlobalResource {
  /// CRDT mapping configuration for this resource.
  final LcrdCrdt crdt;

  /// Configuration for the default FullIndex.
  ///
  /// Defaults to `LcrdFullIndex()` (enabled, localName='default', prefetch).
  /// Use `LcrdFullIndex.disabled()` when only GroupIndex indices apply.
  final LcrdFullIndex fullIndex;

  const LcrdRootResource(
    IriTerm? classIri,
    this.crdt, {
    RootIriStrategy iriStrategy = const RootIriStrategy(),
    this.fullIndex = const LcrdFullIndex(),
  }) : super(classIri, iriStrategy);
}

/// Annotation for nested RDF resources within a root resource.
///
/// Sub-resources are identified using fragment IRIs derived from their parent
/// resource. They inherit CRDT merge strategies from the parent's mapping and
/// are not registered globally in the type index.
///
/// Example:
/// ```dart
/// @LcrdSubResource(
///   IriTerm('https://schema.org/Comment'),
///   SubIriStrategy('#comment-{id}'),
/// )
/// class Comment {
///   @RdfProperty(Schema.text)
///   @CrdtLwwRegister()
///   String? content;
///
///   @RdfProperty(Schema.dateCreated)
///   @CrdtImmutable()
///   DateTime? createdAt;
///
///   @RdfIriPart()
///   String? id;  // Used in fragment template
/// }
/// ```
///
/// The [SubIriStrategy] automatically uses the parent resource's IRI as base,
/// removing any existing fragment before appending the new one.
class LcrdSubResource extends RdfGlobalResource {
  const LcrdSubResource(IriTerm? classIri, SubIriStrategy iriStrategy)
      : super(classIri, iriStrategy, registerGlobally: false);
}

/// Configuration for the default FullIndex of a root resource.
///
/// Controls whether a FullIndex is generated and its parameters.
/// Used as parameter in [LcrdRootResource.fullIndex].
class LcrdFullIndex {
  /// Whether FullIndex generation is enabled.
  final bool isEnabled;

  /// Local name for the FullIndex (default: 'default').
  final String localName;

  /// Item fetch policy for the FullIndex.
  final ItemFetchPolicy policy;

  /// Creates a FullIndex configuration with defaults.
  const LcrdFullIndex({
    this.localName = 'default',
    this.policy = ItemFetchPolicy.prefetch,
  }) : isEnabled = true;

  /// Disables FullIndex generation for this resource.
  /// Use when a resource only has GroupIndex indices.
  const LcrdFullIndex.disabled()
      : isEnabled = false,
        localName = '',
        policy = ItemFetchPolicy.prefetch;
}

/// Defines a regex transformation applied to a grouping property value.
///
/// Used within [LcrdGroupingProperty] to transform raw RDF values
/// (e.g., extracting year-month from a full date string).
class LcrdRegexTransform {
  final String pattern;
  final String replacement;

  const LcrdRegexTransform(this.pattern, this.replacement);
}

/// Defines a property used for grouping in a GroupIndex, with optional transforms.
///
/// The [property] IRI identifies which RDF predicate to group by.
/// Optional [transforms] apply regex transformations before grouping.
class LcrdGroupingProperty {
  final IriTerm property;
  final List<LcrdRegexTransform> transforms;

  const LcrdGroupingProperty(this.property, {this.transforms = const []});
}

class IndexItemIriStrategy extends IriStrategy {
  const IndexItemIriStrategy(Type resourceType)
      : super.namedFactory(indexItemIriFactoryKey, resourceType);
}

/// Annotation for index item (entry) classes.
///
/// Use [LcrdIndexItem.fullIndex] for FullIndex entries and
/// [LcrdIndexItem.groupIndex] for GroupIndex entries.
class LcrdIndexItem extends RdfGlobalResource {
  /// The GroupKey type this item belongs to, or `null` for FullIndex items.
  final Type? groupKeyType;

  /// Creates a FullIndex item entry.
  ///
  /// The [iriStrategy] links back to the root resource type.
  /// Due to Dart const-constructor limitations, `IndexItemIriStrategy`
  /// must be passed as a parameter rather than constructed inline.
  const LcrdIndexItem.fullIndex(IndexItemIriStrategy iriStrategy)
      : groupKeyType = null,
        super.deserializeOnly(null, iri: iriStrategy);

  /// Creates a GroupIndex item entry linked to a specific [groupKeyType].
  const LcrdIndexItem.groupIndex(
    this.groupKeyType,
    IndexItemIriStrategy iriStrategy,
  ) : super.deserializeOnly(null, iri: iriStrategy);
}

/// Annotation for GroupIndex key classes.
///
/// Links a group key to its parent resource type and configures
/// the GroupIndex with an optional local name and grouping properties.
class LcrdGroupKey extends RdfLocalResource {
  /// The resource type this group index is for.
  final Type resourceType;

  /// Local name for this group index (default: 'default').
  final String? localName;

  /// Grouping property definitions with optional transforms.
  final List<LcrdGroupingProperty> groupingProperties;

  const LcrdGroupKey(
    this.resourceType, {
    this.localName,
    this.groupingProperties = const [],
  });
}
