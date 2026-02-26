/// Resource annotations for RDF classes with CRDT synchronization.
///
/// This library provides annotations for defining RDF resources that sync across
/// multiple storage backends (Solid Pods, Google Drive, local directories) using
/// state-based CRDTs for conflict-free collaboration.
library;

import 'package:locorda_annotations/locorda_annotations.dart';
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
///   fullIndex: FullIndex(policy: RootResourceFetchPolicy.onRequest),
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
  final MergeContract? contract;
  final bool generateContract;

  /// Configuration for the default FullIndex.
  ///
  /// Defaults to `FullIndex()` (enabled, localName='default', prefetch).
  /// Use `FullIndex.disabled()` when only GroupIndex indices apply.
  final FullIndex fullIndex;

  /// Generated vocabulary + generated merge contract.
  const RootResource(
    AppVocab vocab, {
    MergeContract mergeContract = const MergeContract(),
    RootIriStrategy iriStrategy = const RootIriStrategy(),
    this.fullIndex = const FullIndex(),
    super.comment,
    super.label,
    super.metadata,
    super.subClassOf,
  })  : generatorVocab = vocab,
        explicitClassIri = null,
        contractAppBaseUri = null,
        explicitContractIri = null,
        generateContract = true,
        contract = mergeContract,
        super.define(vocab, iriStrategy);

  /// External vocabulary + generated merge contract.
  const RootResource.externalVocab(
    IriTerm classIri,
    String mergeContractAppBaseUri, {
    MergeContract mergeContract = const MergeContract(),
    RootIriStrategy iriStrategy = const RootIriStrategy(),
    this.fullIndex = const FullIndex(),
  })  : generatorVocab = null,
        explicitClassIri = classIri,
        contractAppBaseUri = mergeContractAppBaseUri,
        explicitContractIri = null,
        contract = mergeContract,
        generateContract = true,
        super(classIri, iriStrategy);

  /// Generated vocabulary + external merge contract.
  const RootResource.externalContract(
    AppVocab vocab,
    String mergeContractIri, {
    RootIriStrategy iriStrategy = const RootIriStrategy(),
    this.fullIndex = const FullIndex(),
    super.comment,
    super.label,
    super.metadata,
    super.subClassOf,
  })  : generatorVocab = vocab,
        explicitClassIri = null,
        contractAppBaseUri = null,
        explicitContractIri = mergeContractIri,
        contract = null,
        generateContract = false,
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
        contract = null,
        generateContract = false,
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
  const SubResource(
    AppVocab appVocab,
    SubIriStrategy iriStrategy, {
    super.comment,
    super.label,
    super.metadata,
    super.subClassOf,
  }) : super.define(appVocab, iriStrategy, registerGlobally: false);
  const SubResource.externalVocab(IriTerm? classIri, SubIriStrategy iriStrategy)
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
  const LocalResource(
    AppVocab appVocab, {
    super.comment,
    super.label,
    super.metadata,
    super.subClassOf,
  }) : super.define(appVocab);
  const LocalResource.externalVocab([IriTerm? classIri]) : super(classIri);
}

/// Annotation for index item (entry) classes that represent projections of
/// root resources within indices.
///
/// **Important**: IndexItem does **not define** a new RDF type. Index entries
/// are framework-internal metadata structures represented as untyped fragment
/// IRIs within shard documents. They have **no explicit `rdf:type` triple** and
/// use predicate-based CRDT mappings instead of class-based mappings.
///
/// This is fundamentally different from [RootResource], [SubResource], and
/// [LocalResource], which define new semantic types with explicit `rdf:type`
/// triples. IndexItem classes are framework projections for performance
/// optimization, not domain model entities.
///
/// ## Usage
///
/// Use [IndexItem.fullIndex] for FullIndex entries and [IndexItem.groupIndex]
/// for GroupIndex entries.
///
/// ## Example: FullIndex Entry
///
/// ```dart
/// @RootResource(PersonalNotesVocab.Note, ...)
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
///
/// // Index item with subset of Note properties
/// @IndexItem.fullIndex(IndexItemIriStrategy(Note))
/// class NoteIndexItem {
///   @RdfProperty(Schema.name)
///   String? title;
///
///   @RdfProperty(Schema.dateCreated)
///   DateTime? createdAt;
///
///   // Note: content field omitted for performance - full data fetched on demand
/// }
/// ```
///
/// ## Example: GroupIndex Entry
///
/// ```dart
/// @GroupKey(Note, localName: 'byMonth', ...)
/// class NoteMonthGroupKey { ... }
///
/// @IndexItem.groupIndex(NoteMonthGroupKey, IndexItemIriStrategy(Note))
/// class NoteMonthIndexItem {
///   @RdfProperty(Schema.name)
///   String? title;
///
///   @RdfProperty(Schema.dateCreated)
///   DateTime? createdAt;
/// }
/// ```
///
/// ## RDF Structure
///
/// Index entries are stored as framework-internal metadata without explicit
/// RDF typing. Each entry is a fragment IRI (e.g., `#entry-a1b2c3...`) with:
///
/// - `idx:resource` → IRI of the actual root resource (Immutable)
/// - `crdt:clockHash` → Clock hash for change detection (LWW-Register)
/// - Optional header properties extracted from root resource (LWW-Register)
///
/// No `rdf:type` triple is present. CRDT merging uses predicate-based rules.
///
/// ## IRI Strategy
///
/// [IndexItemIriStrategy] resolves to the same IRI as the root resource
/// instance, ensuring index items and full resources are semantically identical.
///
/// ## Properties
///
/// - Index item properties must be a **subset** of the root resource properties
/// - Property annotations (`@RdfProperty`, types) must match exactly
/// - CRDT annotations are inherited from root resource merge contract
///
/// ## Custom Vocabulary Properties
///
/// Index items can include properties from custom vocabularies defined for
/// your application:
///
/// ```dart
/// // Define custom vocabulary
/// const appVocab = AppVocab(
///   appBaseUri: 'https://myapp.example.com/',
///   vocabPath: 'vocabulary/myapp',
/// );
///
/// class MyAppProperties {
///   static const priority = IriTerm('https://myapp.example.com/vocabulary/myapp#priority');
///   static const categoryId = IriTerm('https://myapp.example.com/vocabulary/myapp#category');
/// }
///
/// // Root resource - generator creates vocabulary properties from fields
/// @RootResource(appVocab, ...)
/// class Task {
///   @RdfProperty(Schema.name)
///   String? title;
///
///   int? priority;  // @RdfProperty.define() is optional - auto-generated as myapp:priority
///
///   @RdfProperty.define(fragment: 'category')  // Explicit - generated as myapp:category
///   String? categoryId;
/// }
///
/// // Index item - references the generated vocabulary
/// @IndexItem.fullIndex(IndexItemIriStrategy(Task))
/// class TaskIndexItem {
///   @RdfProperty(Schema.name)
///   String? title;
///
///   @RdfProperty(MyAppProperties.priority)
///   int? priority;
///
///   @RdfProperty(MyAppProperties.categoryId)
///   String? categoryId;
/// }
/// ```
///
/// ## Code Generation
///
/// The generator creates deserialization-only mappers (no serialization needed)
/// and links index items to their root resource type for proper RDF type handling.
///
/// ## See Also
///
/// - [RootResource] - Defines new semantic types (contrasts with IndexItem)
/// - [GroupKey] - Organizes resources into groups for partitioned indices
/// - [IndexItemIriStrategy] - IRI resolution for index items
class IndexItem extends RdfGlobalResource implements LocordaAnnotation {
  /// The GroupKey type this item belongs to, or `null` for FullIndex items.
  final Type? groupKeyType;

  /// Creates a FullIndex item annotation.
  ///
  /// Use this for index entries in a FullIndex (monolithic index containing
  /// all resources of a type).
  ///
  /// The [iriStrategy] must resolve to the same IRI as the corresponding
  /// root resource instance to ensure proper linking.
  ///
  /// Example:
  /// ```dart
  /// @IndexItem.fullIndex(IndexItemIriStrategy(Note))
  /// class NoteIndexItem { ... }
  /// ```
  const IndexItem.fullIndex(IndexItemIriStrategy iriStrategy)
      : groupKeyType = null,
        super.deserializeOnly(null, iri: iriStrategy);

  /// Creates a GroupIndex item annotation.
  ///
  /// Use this for index entries in a GroupIndex (partitioned index where
  /// resources are organized into groups).
  ///
  /// The [groupKeyType] links this item to a specific [GroupKey] class that
  /// defines the grouping strategy. The [iriStrategy] must resolve to the
  /// same IRI as the corresponding root resource instance.
  ///
  /// Example:
  /// ```dart
  /// @IndexItem.groupIndex(NoteMonthGroupKey, IndexItemIriStrategy(Note))
  /// class NoteMonthIndexItem { ... }
  /// ```
  const IndexItem.groupIndex(
    this.groupKeyType,
    IndexItemIriStrategy iriStrategy,
  ) : super.deserializeOnly(null, iri: iriStrategy);
}

/// Annotation for GroupIndex key classes that organize root resources into
/// logical groups for partitioned indexing.
///
/// **Important**: GroupKey does **not define** a new RDF type. It is a
/// **framework construct** used to organize resources into hierarchical groups
/// (e.g., by date, category, tag). Group keys are typically represented as
/// blank nodes or use the standard `idx:GroupKey` framework type.
///
/// This contrasts with [RootResource], [SubResource], and [LocalResource],
/// which define semantic domain types. GroupKey is purely organizational.
///
/// ## Concept
///
/// Group keys partition a large set of resources into smaller groups for
/// performance and selective synchronization. Each group has:
/// - A unique key value derived from resource properties (via [groupingProperties])
/// - A separate index containing only resources in that group
/// - Independent synchronization and caching
///
/// ## Basic Example
///
/// ```dart
/// @RootResource(PersonalNotesVocab.Note, ...)
/// class Note {
///   @RdfProperty(Schema.name)
///   String? title;
///
///   @RdfProperty(Schema.dateCreated)
///   DateTime? createdAt;
/// }
///
/// // Group notes by creation month (e.g., "2025-01", "2025-02")
/// @GroupKey(
///   Note,
///   localName: 'byMonth',
///   groupingProperties: [
///     GroupingProperty(
///       Schema.dateCreated,
///       transforms: [
///         RegexTransform(r'^(\d{4}-\d{2})', r'\1'),  // Extract YYYY-MM
///       ],
///     ),
///   ],
/// )
/// class NoteMonthGroupKey {
///   @RdfProperty(Schema.dateCreated)
///   String? month;  // "2025-01"
/// }
/// ```
///
/// ## Resource Type Reference
///
/// The [resourceType] parameter references the [RootResource] type this
/// group index organizes. The generator uses this to:
/// - Link the group index configuration to the correct resource type
/// - Generate type-safe query APIs
/// - Configure index synchronization
///
/// ## Local Name
///
/// The optional [localName] distinguishes multiple group indices for the
/// same resource type:
/// - `localName: 'byMonth'` → group by month
/// - `localName: 'byCategory'` → group by category
/// - Default: `'default'` if omitted
///
/// ## Grouping Properties
///
/// [groupingProperties] defines how group key values are derived from
/// resource properties:
///
/// ```dart
/// groupingProperties: [
///   // Extract year-month from DateTime (YYYY-MM)
///   GroupingProperty(
///     Schema.dateCreated,
///     transforms: [RegexTransform(r'^(\d{4}-\d{2})', r'\1')],
///   ),
///   // Use property as-is without transformation
///   GroupingProperty(PersonalNotesVocab.category),
/// ]
/// ```
///
/// Multiple properties create hierarchical group keys (e.g., "work/2025-01").
///
/// ## Custom Vocabulary Properties
///
/// Group keys can use properties from custom vocabularies:
///
/// ```dart
/// // Define custom vocabulary
/// const appVocab = AppVocab(
///   appBaseUri: 'https://myapp.example.com/',
///   vocabPath: 'vocabulary/myapp',
/// );
///
/// class MyAppProperties {
///   static const channelId = IriTerm('https://myapp.example.com/vocabulary/myapp#channelId');
///   static const timestamp = IriTerm('https://myapp.example.com/vocabulary/myapp#timestamp');
/// }
///
/// // Root resource - generator creates vocabulary properties
/// @RootResource(appVocab, ...)
/// class Message {
///   @RdfProperty(Schema.text)
///   String? content;
///
///   @RdfProperty.define()  // Generated: myapp:channelId
///   String? channelId;
///
///   // Generated: myapp:timestamp - @RdfProperty.define() is optional
///   DateTime? timestamp;
/// }
///
/// // Group by channel and month using custom properties
/// @GroupKey(
///   Message,
///   localName: 'byChannelAndMonth',
///   groupingProperties: [
///     GroupingProperty(MyAppProperties.channelId),
///     GroupingProperty(
///       MyAppProperties.timestamp,
///       transforms: [
///         RegexTransform(r'^(\d{4}-\d{2})', r'\1'),  // Extract YYYY-MM
///       ],
///     ),
///   ],
/// )
/// class MessageChannelMonthGroupKey {
///   @RdfProperty(MyAppProperties.channelId)
///   String? channelId;
///
///   @RdfProperty(MyAppProperties.timestamp)
///   DateTime? yearMonth;  // Normalized to first UTC instant of month
/// }
/// ```
///
/// ## Advanced: Multi-Level Grouping
///
/// ```dart
/// @GroupKey(
///   Note,
///   localName: 'byCategoryAndMonth',
///   groupingProperties: [
///     GroupingProperty(PersonalNotesVocab.category),  // First level
///     GroupingProperty(
///       Schema.dateCreated,
///       transforms: [RegexTransform(r'^(\d{4}-\d{2})', r'\1')],  // Extract YYYY-MM
///     ),
///   ],
/// )
/// class NoteCategoryMonthGroupKey {
///   @RdfProperty(PersonalNotesVocab.category)
///   String? category;
///
///   @RdfProperty(Schema.dateCreated)
///   String? month;
/// }
/// ```
///
/// This creates group keys like `"work/2025-01"`, `"personal/2025-02"`.
///
/// ## RDF Representation
///
/// Group keys do not create app-specific RDF types. They use framework
/// infrastructure (blank nodes or `idx:GroupKey`) for organization.
///
/// ## Code Generation
///
/// The generator creates:
/// - GroupIndex configuration in `LocordaConfig`
/// - Type-safe query APIs for accessing groups
/// - Index synchronization logic
///
/// ## See Also
///
/// - [IndexItem] - Entries within group indices
/// - [GroupingProperty] - Property extraction and transformation
/// - [RootResource] - Defines the resource type being grouped
class GroupKey extends RdfLocalResource implements LocordaAnnotation {
  /// The resource type this group index is for.
  final Type resourceType;

  /// Local name for this group index (default: 'default').
  final String? localName;

  /// Grouping property definitions with optional transforms.
  final List<GroupingProperty> groupingProperties;

  /// Creates a GroupKey annotation for organizing resources into groups.
  ///
  /// The [resourceType] specifies which [RootResource] type this group index
  /// organizes.
  ///
  /// The optional [localName] distinguishes multiple group indices for the
  /// same resource type (defaults to 'default' if omitted).
  ///
  /// The [groupingProperties] define how group key values are extracted and
  /// transformed from resource properties. Use [GroupingProperty] with optional
  /// [RegexTransform]s to normalize values (e.g., extract year-month from dates).
  ///
  /// Example:
  /// ```dart
  /// @GroupKey(
  ///   Note,
  ///   localName: 'byMonth',
  ///   groupingProperties: [
  ///     GroupingProperty(
  ///       Schema.dateCreated,
  ///       transforms: [
  ///         RegexTransform(r'^(\d{4}-\d{2})', r'\1'),  // Extract YYYY-MM
  ///       ],
  ///     ),
  ///   ],
  /// )
  /// class NoteMonthGroupKey { ... }
  /// ```
  const GroupKey(
    this.resourceType, {
    this.localName,
    this.groupingProperties = const [],
  });
}
