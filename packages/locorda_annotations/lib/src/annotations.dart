/// Resource annotations for RDF classes with CRDT synchronization.
///
/// This library provides annotations for defining RDF resources that sync across
/// multiple storage backends (Solid Pods, Google Drive, local directories) using
/// state-based CRDTs for conflict-free collaboration.
library;

import 'package:locorda_annotations/src/parameters.dart';
import 'package:locorda_rdf_mapper_annotations/annotations.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:locorda_annotations/locorda_annotations.dart';
import 'package:locorda_core/locorda_core.dart' hide GroupingPropertyData;

const resourceIriFactoryKey = r'$resourceIriFactory';
const indexItemIriFactoryKey = r'$indexItemIriFactory';
const resourceIriVar = r'rootResourceIri';

/// Annotation for top-level RDF resources with CRDT synchronization.
///
/// Marks a Dart class as a root resource that will be synchronized across storage
/// backends (Solid Pods, Google Drive, local directories) using state-based CRDTs
/// for conflict-free collaboration.
///
/// ## Basic Example
///
/// ```dart
/// @RootResource(
///   IriTerm('https://schema.org/Note'),
///   MergeContract('https://myapp.example.com/mappings/note-v1#'),
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
/// MergeContract(
///   'https://myapp.example.com/mappings/note-v1#',
///   label: 'Note CRDT Mapping',  // Optional metadata
/// )
/// ```
/// The builder scans CRDT annotations on properties and generates merge rules.
///
/// **External CRDT mapping** (for shared/standard vocabularies):
/// ```dart
/// MergeContract.external('https://vocab.example.org/mappings/standard-note-v1#')
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
/// @RootResource(
///   IriTerm('https://schema.org/Note'),
///   MergeContract('https://myapp.example.com/mappings/note-v1#'),
///   fullIndex: FullIndex(policy: ItemFetchPolicy.onRequest),
/// )
/// ```
///
/// Use `FullIndex.disabled()` when only GroupIndex applies.
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
/// - [MergeContract] - CRDT mapping configuration
/// - [SubResource] - Nested resources within a root resource
/// - [RdfGlobalResource] - Base RDF resource annotation
/// - CRDT annotations: [CrdtLwwRegister], [CrdtOrSet], [CrdtImmutable]
class RootResource extends RdfGlobalResource {
  /// CRDT mapping configuration for this resource.
  final MergeContract crdt;

  /// Configuration for the default FullIndex.
  ///
  /// Defaults to `FullIndex()` (enabled, localName='default', prefetch).
  /// Use `FullIndex.disabled()` when only GroupIndex indices apply.
  final FullIndex fullIndex;

  const RootResource(
    IriTerm? classIri,
    this.crdt, {
    RootIriStrategy iriStrategy = const RootIriStrategy(),
    this.fullIndex = const FullIndex(),
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
/// @SubResource(
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
class SubResource extends RdfGlobalResource {
  const SubResource(IriTerm? classIri, SubIriStrategy iriStrategy)
      : super(classIri, iriStrategy, registerGlobally: false);
}

/// Annotation for index item (entry) classes.
///
/// Use [IndexItem.fullIndex] for FullIndex entries and
/// [IndexItem.groupIndex] for GroupIndex entries.
class IndexItem extends RdfGlobalResource {
  /// The GroupKey type this item belongs to, or `null` for FullIndex items.
  final Type? groupKeyType;

  /// Creates a FullIndex item entry.
  ///
  /// The [iriStrategy] links back to the root resource type.
  /// Due to Dart const-constructor limitations, `IndexItemIriStrategy`
  /// must be passed as a parameter rather than constructed inline.
  const IndexItem.fullIndex(IndexItemIriStrategy iriStrategy)
      : groupKeyType = null,
        super.deserializeOnly(null, iri: iriStrategy);

  /// Creates a GroupIndex item entry linked to a specific [groupKeyType].
  const IndexItem.groupIndex(
    this.groupKeyType,
    IndexItemIriStrategy iriStrategy,
  ) : super.deserializeOnly(null, iri: iriStrategy);
}

/// Annotation for GroupIndex key classes.
///
/// Links a group key to its parent resource type and configures
/// the GroupIndex with an optional local name and grouping properties.
class GroupKey extends RdfLocalResource {
  /// The resource type this group index is for.
  final Type resourceType;

  /// Local name for this group index (default: 'default').
  final String? localName;

  /// Grouping property definitions with optional transforms.
  final List<GroupingProperty> groupingProperties;

  const GroupKey(
    this.resourceType, {
    this.localName,
    this.groupingProperties = const [],
  });
}
