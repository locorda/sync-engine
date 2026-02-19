/// Resource annotations for RDF classes with CRDT synchronization.
///
/// This library provides annotations for defining RDF resources that sync across
/// multiple storage backends (Solid Pods, Google Drive, local directories) using
/// state-based CRDTs for conflict-free collaboration.
library;

import 'package:locorda_annotations/locorda_annotations.dart';
import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:locorda_rdf_mapper_annotations/annotations.dart';

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
class RootResource extends RdfGlobalResource implements LocordaAnnotation {
  // TODO: can we make those private?
  final AppVocab? generatorVocab;
  final IriTerm? explicitClassIri;
  final String? contractAppBaseUri;
  final String? explicitContractIri;
  final String contractVersion;
  final String? contractPath;
  final bool generateContract;
  final String? contractLabel;
  final String? contractComment;
  final List<IriTerm> contractImports;

  /// Configuration for the default FullIndex.
  ///
  /// Defaults to `FullIndex()` (enabled, localName='default', prefetch).
  /// Use `FullIndex.disabled()` when only GroupIndex indices apply.
  final FullIndex fullIndex;

  /// Generated vocabulary + generated merge contract.
  const RootResource(
    AppVocab vocab, {
    String mergeContractVersion = 'v1',
    String? mergeContractPath,
    String? mergeContractLabel,
    String? mergeContractComment,
    List<IriTerm> mergeContractImports = const [MergeContracts.coreV1],
    RootIriStrategy iriStrategy = const RootIriStrategy(),
    this.fullIndex = const FullIndex(),
  })  : generatorVocab = vocab,
        explicitClassIri = null,
        contractAppBaseUri = null,
        explicitContractIri = null,
        contractVersion = mergeContractVersion,
        contractPath = mergeContractPath,
        generateContract = true,
        contractLabel = mergeContractLabel,
        contractComment = mergeContractComment,
        contractImports = mergeContractImports,
        super.define(vocab, iriStrategy);

  /// External vocabulary + generated merge contract.
  const RootResource.externalVocab(
    IriTerm classIri,
    String mergeContractAppBaseUri, {
    String mergeContractVersion = 'v1',
    String? mergeContractPath,
    String? mergeContractLabel,
    String? mergeContractComment,
    List<IriTerm> mergeContractImports = const [MergeContracts.coreV1],
    RootIriStrategy iriStrategy = const RootIriStrategy(),
    this.fullIndex = const FullIndex(),
  })  : generatorVocab = null,
        explicitClassIri = classIri,
        contractAppBaseUri = mergeContractAppBaseUri,
        explicitContractIri = null,
        contractVersion = mergeContractVersion,
        contractPath = mergeContractPath,
        generateContract = true,
        contractLabel = mergeContractLabel,
        contractComment = mergeContractComment,
        contractImports = mergeContractImports,
        super(classIri, iriStrategy);

  /// Generated vocabulary + external merge contract.
  const RootResource.externalContract(
    AppVocab vocab,
    String mergeContractIri, {
    RootIriStrategy iriStrategy = const RootIriStrategy(),
    this.fullIndex = const FullIndex(),
  })  : generatorVocab = vocab,
        explicitClassIri = null,
        contractAppBaseUri = null,
        explicitContractIri = mergeContractIri,
        contractVersion = 'v1',
        contractPath = null,
        generateContract = false,
        contractLabel = null,
        contractComment = null,
        contractImports = const [],
        super.define(vocab, iriStrategy);

  /// External vocabulary + external merge contract.
  const RootResource.external(
    IriTerm classIri,
    String mergeContractIri, {
    RootIriStrategy iriStrategy = const RootIriStrategy(),
    this.fullIndex = const FullIndex(),
  })  : generatorVocab = null,
        explicitClassIri = classIri,
        contractAppBaseUri = null,
        explicitContractIri = mergeContractIri,
        contractVersion = 'v1',
        contractPath = null,
        generateContract = false,
        contractLabel = null,
        contractComment = null,
        contractImports = const [],
        super(classIri, iriStrategy);
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
class SubResource extends RdfGlobalResource implements LocordaAnnotation {
  const SubResource(IriTerm? classIri, SubIriStrategy iriStrategy)
      : super(classIri, iriStrategy, registerGlobally: false);
}

/// Annotation for local RDF resources (blank nodes).
///
/// Marks a Dart class as a local resource (blank node) that exists only
/// within the context of a parent resource. Unlike global resources
/// ([RootResource], [SubResource]), local resources do not have globally
/// unique IRIs.
///
/// ## CRDT Merge Identification
///
/// For CRDT merging, blank nodes can be identified in two ways:
///
/// - **Single-path blank nodes**: Reachable via exactly one property path
///   from the parent resource (e.g., `Category → displaySettings`).
///   No [@MergeIdentifying()] annotation needed.
///
/// - **Property-identified blank nodes**: Multiple instances can exist and are
///   matched during CRDT merge operations by a unique property marked with
///   [@MergeIdentifying()] (e.g., Weblink instances matched by URL).
///
/// ## RDF Type (classIri)
///
/// Optionally specify an RDF type for the blank node via the [classIri] parameter.
/// This is independent of merge identification and purely affects RDF serialization.
///
/// ## Usage Examples
///
/// **Single-path blank node without RDF type**:
/// ```dart
/// @LocalResource()
/// class CategoryDisplaySettings {
///   @RdfProperty(PersonalNotesVocab.categoryColor)
///   @CrdtLwwRegister()
///   final String? color;
///
///   @RdfProperty(PersonalNotesVocab.categoryIcon)
///   @CrdtLwwRegister()
///   final String? icon;
/// }
/// ```
///
/// **Property-identified blank node with RDF type**:
/// ```dart
/// @LocalResource(PersonalNotesVocab.Weblink)
/// class Weblink {
///   @RdfProperty(Schema.url)
///   @MergeIdentifying()  // Identifies this blank node for CRDT merging
///   @CrdtImmutable()
///   final String url;
///
///   @RdfProperty(Schema.name)
///   @CrdtLwwRegister()
///   final String? title;
/// }
/// ```
///
/// ## CRDT Merge Strategies
///
/// Local resources inherit CRDT merge strategies from their parent
/// [RootResource]'s merge contract. Use standard CRDT property annotations:
///
/// - `@CrdtLwwRegister()` - Last-Write-Wins (single value)
/// - `@CrdtOrSet()` - Observed-Remove Set (multi-value, re-addable)
/// - `@CrdtImmutable()` - Write-once, never changes
///
/// ## See Also
///
/// - [RootResource] - Top-level resources with global IRIs
/// - [SubResource] - Nested global resources with fragment IRIs
/// - [@MergeIdentifying()] - Mark identifying properties for blank nodes
class LocalResource extends RdfLocalResource implements LocordaAnnotation {
  const LocalResource([IriTerm? classIri]) : super(classIri);
}

/// Annotation for index item (entry) classes.
///
/// Use [IndexItem.fullIndex] for FullIndex entries and
/// [IndexItem.groupIndex] for GroupIndex entries.
class IndexItem extends RdfGlobalResource implements LocordaAnnotation {
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
class GroupKey extends RdfLocalResource implements LocordaAnnotation {
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
