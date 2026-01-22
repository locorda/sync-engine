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
            resourceIriVar);
}

class SubIriStrategy extends IriStrategy {
  const SubIriStrategy(String fragmentTemplate)
      : super.withFragment(
            // references the parent resource IRI via the variable we expose in PodIriStrategy
            // so that the subresource IRI can be constructed as {parentResourceIri}#fragment .
            // Note: any fragment will be removed from the parent resource IRI automatically,
            // so it is no problem at all if the parent resource IRI already has a fragment.
            '{+$resourceIriVar}',
            fragmentTemplate);
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
/// @SolidPodResource()
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
/// Resources annotated with `@SolidPodResource()` automatically participate
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
///
/// See also:
/// - [RdfGlobalResource] - The base annotation this extends
/// - CRDT annotations: [CrdtLwwRegister], [CrdtFwwRegister], [CrdtOrSet], [CrdtImmutable]
/// - [SyncEngine] - The main synchronization engine
class LcrdRootResource extends RdfGlobalResource {
  /// Creates a Solid Pod resource annotation.
  ///
  /// This annotation inherits all functionality from [RdfGlobalResource]
  /// and adds Solid-specific features for Pod-based resource management.
  ///
  /// The [classIri] parameter defines the RDF type for this resource class.
  /// The IRI strategy is configured globally when initializing the
  /// [SyncEngine] system rather than per-annotation, providing consistent
  /// IRI generation across all Solid Pod resources.
  ///
  /// Example:
  /// ```dart
  /// @PodResource(const IriTerm('https://example.org/Note'))
  /// class Note extends RdfResource {
  ///   @LwwRegister()
  ///   late String title;
  /// }
  /// ```
  const LcrdRootResource(IriTerm? classIri,
      [RootIriStrategy iriStrategy = const RootIriStrategy()])
      : super(classIri, iriStrategy);
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

class IndexItemIriStrategy extends IriStrategy {
  const IndexItemIriStrategy(Type resourceType)
      : super.namedFactory(indexItemIriFactoryKey, resourceType);
}

class LcrdIndexItem extends RdfGlobalResource {
  const LcrdIndexItem(IndexItemIriStrategy iriStrategy)
      // create (and register) only a Deserializer, because the IndexItem classes
      // are never serialized from dart to rdf - they are only deserialized.
      : super.deserializeOnly(
            // Save a bit of space and do not repeat the type of index entries over and over again
            // Plus: since the IndexItem uses the same type as the root resource, we would
            // risk messing up the rdf mapper if we used the same type here.
            null,
            iri: iriStrategy);
}

class LcrdGroupKey extends RdfLocalResource {
  const LcrdGroupKey();
}
