/// Solid Pod resource annotation for RDF classes stored in Solid Pods.
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

/// Annotation for RDF classes that represent resources stored in Solid Pods.
///
/// This annotation extends [RdfGlobalResource] to provide Solid-specific
/// functionality for managing RDF resources within a Solid Pod ecosystem.
/// It handles the mapping between Dart objects and RDF resources that will
/// be synchronized across Solid Pods using CRDT merge strategies.
///
/// ## What is a Solid Pod?
///
/// A Solid Pod is a personal data store that gives users complete control
/// over their data. Each Pod acts as a secure, decentralized storage space
/// where users can store any kind of information while maintaining full
/// ownership and control over who can access it.
///
/// ## IRI Strategy and Resource Identification
///
/// In Solid, every resource is identified by an IRI (Internationalized
/// Resource Identifier). This annotation works with the locorda
/// framework to automatically generate appropriate IRIs for your resources
/// based on configurable strategies:
///
/// - **Fragment-based IRIs**: Resources are always identified using fragment
///   identifiers (e.g., `https://example.pod/notes/note1.ttl#it`). The
///   framework owns the RDF documents while your application resources
///   live as fragments within those documents.
/// - **Type Index integration**: Resources can be automatically registered
///   in the user's type index for discoverability
///
/// ## Usage Example
///
/// ```dart
/// @LcrdRootResource(
///   const IriTerm('https://example.org/Note'),
///   'https://myapp.example.com/mappings/note-v1.ttl',
/// )
/// class Note extends RdfResource {
///   @LwwRegister()
///   late String title;
///
///   @LwwRegister()
///   late String content;
///
///   @Immutable()
///   late DateTime createdAt;
///
///   Note();
/// }
/// ```
///
/// ## CRDT Integration
///
/// Resources annotated with `@LcrdRootResource` automatically participate
/// in CRDT-based conflict resolution when synchronized across multiple
/// devices or users. Properties within the class should use appropriate
/// CRDT annotations ([CrdtLwwRegister], [CrdtFwwRegister], [CrdtOrSet], [CrdtImmutable])
/// to define their merge behavior.
///
/// ## Code Generation
///
/// The locorda generator will process this annotation to create:
/// - Proper IRI mapping based on the configured strategy
/// - CRDT merge logic for conflict resolution
/// - Integration with Solid authentication and type indices
/// - Serialization/deserialization methods for RDF storage
/// - LocordaConfig generation for automatic sync configuration
///
/// See also:
/// - [RdfGlobalResource] - The base annotation this extends
/// - CRDT annotations: [CrdtLwwRegister], [CrdtFwwRegister], [CrdtOrSet], [CrdtImmutable]
/// - [SyncEngine] - The main synchronization engine
class LcrdRootResource extends RdfGlobalResource {
  /// Full absolute IRI identifying the CRDT mapping document.
  ///
  /// This is a static, app-owned IRI — fully known at compile time,
  /// not dependent on any user or Pod URL. Use Dart const string
  /// interpolation with a shared base constant to avoid repetition.
  ///
  /// Example: `'$appBaseUrl/mappings/note-v1.ttl'`
  /// where `const appBaseUrl = 'https://myapp.example.com';`
  final String crdtMapping;

  /// Whether to auto-generate the CRDT mapping file from property annotations.
  ///
  /// When `true` (default), the build system generates a `.ttl` file from
  /// `@CrdtLwwRegister`, `@CrdtOrSet`, `@CrdtImmutable` annotations.
  /// Set to `false` for manually authored mapping files.
  final bool generateCrdtMapping;

  /// Configuration for the default FullIndex.
  ///
  /// Defaults to `LcrdFullIndex()` (enabled, localName='default', prefetch).
  /// Use `LcrdFullIndex.disabled()` when only GroupIndex indices apply.
  final LcrdFullIndex fullIndex;

  const LcrdRootResource(
    IriTerm? classIri,
    this.crdtMapping, {
    RootIriStrategy iriStrategy = const RootIriStrategy(),
    this.generateCrdtMapping = true,
    this.fullIndex = const LcrdFullIndex(),
  }) : super(classIri, iriStrategy);
}

class LcrdSubResource extends RdfGlobalResource {
  /// Creates a Solid Pod sub-resource annotation.
  ///
  /// This annotation is used for RDF classes that represent sub-resources
  /// within a Solid Pod. Sub-resources are identified using a combination
  /// of the parent resource's IRI and a fragment identifier specific to
  /// the sub-resource.
  ///
  /// The [classIri] parameter defines the RDF type for this sub-resource class.
  /// The [iriStrategy] parameter specifies how to construct the IRI for
  /// instances of this sub-resource, automatically using the parent resource's
  /// IRI as a base.
  ///
  /// Example:
  /// ```dart
  /// @PodSubResource(
  ///   const IriTerm('https://example.org/Comment'),
  ///   PodSubResourceIriStrategy('#comment-{id}')
  /// )
  /// class Comment extends RdfResource {
  ///   @LwwRegister()
  ///   late String content;
  ///
  ///   @Immutable()
  ///   late DateTime createdAt;
  ///
  ///   @RdfIriPart()
  ///   late String id; // Unique fragment identifier for this comment
  /// }
  /// ```
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
