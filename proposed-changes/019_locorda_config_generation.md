# Concept: LocordaConfig Generation from Annotations

**Date:** 2026-02-11  
**Status:** Draft Concept  
**Author:** Klas Kalaß & AI Analysis (copilot/claude)  
**Related:** [017-convenience-bootstrap.md](017-convenience-bootstrap.md), [020-crdt-mapping-generation.md](020-crdt-mapping-generation.md)

## Executive Summary

This document defines how `LocordaConfig` is automatically generated from `@RootResource` and related annotations, eliminating the need for manual configuration in most cases.

**Note:** CRDT mapping TTL files referenced in `crdtMapping` are automatically generated from annotations. See [020-crdt-mapping-generation.md](020-crdt-mapping-generation.md) for details on the CRDT mapping generation process.

## Current State Analysis

### Manual Configuration (main.dart)

```dart
LocordaConfig(
  resources: [
    ResourceConfig(
      type: Note,
      crdtMapping: Uri.parse('$appBaseUrl/mappings/note-v1.ttl'),
      indices: [
        GroupIndex(NoteGroupKey,
            item: IndexItemConfig(NoteIndexEntry, {
              SchemaNoteDigitalDocument.name,
              SchemaNoteDigitalDocument.dateCreated,
              SchemaNoteDigitalDocument.dateModified,
              SchemaNoteDigitalDocument.keywords,
              PersonalNotesVocab.belongsToCategory
            }),
            groupingProperties: [
              GroupingProperty(SchemaNoteDigitalDocument.dateCreated,
                  transforms: [
                    RegexTransform(r'^([0-9]{4})-([0-9]{2})-([0-9]{2}).*', r'${1}-${2}')
                  ])
            ]),
      ],
    ),
    ResourceConfig(
      type: Category,
      crdtMapping: Uri.parse('$appBaseUrl/mappings/category-v1.ttl'),
      indices: [FullIndex(rootResourceFetchPolicy: RootResourceFetchPolicy.prefetch)],
    ),
  ],
)
```

### Current Annotations

```dart
@RootResource(PersonalNotesVocab.PersonalNote, RootIriStrategy(...))
class Note {
  @RdfProperty(...) @CrdtLwwRegister() final String title;
  @RdfProperty(...) @CrdtImmutable() final DateTime createdAt;
}

@IndexItem(IndexItemIriStrategy(Note))
class NoteIndexEntry {
  @RdfProperty(SchemaNoteDigitalDocument.name) final String name;
  @RdfProperty(SchemaNoteDigitalDocument.dateCreated) final DateTime dateCreated;
}

@GroupKey()
class NoteGroupKey {
  @RdfProperty(SchemaNoteDigitalDocument.dateCreated) final DateTime createdMonth;
}
```

**Missing:**
- CRDT mapping IRI specification
- Connection between GroupKey and resource type
- Distinction between FullIndex and GroupIndex items
- Way to disable default FullIndex

## Proposed Solution: Consolidated Annotations

### FullIndex Configuration

```dart
class FullIndex {
  final bool isEnabled;
  final String localName;
  final RootResourceFetchPolicy policy;
  
  /// Creates a FullIndex configuration with defaults.
  /// Default localName: 'default'
  /// Default policy: RootResourceFetchPolicy.prefetch
  const FullIndex({
    this.localName = 'default',
    this.policy = RootResourceFetchPolicy.prefetch,
  }) : isEnabled = true;
  
  /// Disables FullIndex generation for this resource.
  /// Use when resource only has GroupIndex indices.
  const FullIndex.disabled()
      : isEnabled = false,
        localName = '',
        policy = RootResourceFetchPolicy.prefetch;
}
```

### Enhanced RootResource

```dart
class RootResource extends RdfGlobalResource {
  /// Full absolute IRI identifying the CRDT mapping document.
  ///
  /// This is a static, app-owned IRI — fully known at compile time,
  /// not dependent on any user or Pod URL. Use Dart const string
  /// interpolation with a shared base constant to avoid repetition.
  ///
  /// Generation is controlled by [generateCrdtMapping] flag (default: true).
  ///
  /// Example: `'$appBaseUrl/mappings/note-v1.ttl'`
  /// where `const appBaseUrl = 'https://myapp.example.com';`
  final String crdtMapping;
  
  /// Whether to generate the CRDT mapping file from property annotations.
  /// Default: true (generate from @CrdtLwwRegister, @CrdtOrSet, etc.)
  /// Set to false for manually created mapping files.
  final bool generateCrdtMapping;
  
  /// Configuration for the default FullIndex.
  /// Default: FullIndex() (enabled with localName='default', policy=prefetch)
  /// Use FullIndex.disabled when resource only has GroupIndex indices.
  final FullIndex fullIndex;

  const RootResource(
    IriTerm? classIri,
    this.crdtMapping, {
    RootIriStrategy iriStrategy = const RootIriStrategy(),
    this.generateCrdtMapping = true,
    this.fullIndex = const FullIndex(),
  }) : super(classIri, iriStrategy);
}
```

### Enhanced GroupKey

```dart
class GroupKey extends RdfLocalResource {
  /// The resource type this group index is for
  final Type resourceType;
  
  /// Local name for this group index (default: "default")
  final String? localName;
  
  /// Properties to use for grouping with optional transforms
  final List<GroupingProperty> groupingProperties;
  
  const GroupKey(
    this.resourceType, {
    this.localName,
    this.groupingProperties = const [],
  });
}

class GroupingProperty {
  final IriTerm property;
  final List<RegexTransform> transforms;
  
  const GroupingProperty(this.property, {this.transforms = const []});
}

class RegexTransform {
  final String pattern;
  final String replacement;
  
  const RegexTransform(this.pattern, this.replacement);
}
```

### Enhanced IndexItem

```dart
class IndexItem extends RdfGlobalResource {
  /// The index type this item belongs to (GroupKey class or null for FullIndex)
  final Type? groupKeyType;
  
  /// Named constructor for FullIndex entries
  /// Usage: @IndexItem.fullIndex(IndexItemIriStrategy(Note))
  /// 
  /// Note: IndexItemIriStrategy must be passed as parameter (not resourceType)
  /// due to Dart const constructor limitations - cannot create new objects
  /// inside const constructors.
  const IndexItem.fullIndex(IndexItemIriStrategy iriStrategy)
      : groupKeyType = null,
        super.deserializeOnly(null, iri: iriStrategy);
  
  /// Named constructor for GroupIndex entries
  /// Usage: @IndexItem.groupIndex(NoteGroupKey, IndexItemIriStrategy(Note))
  const IndexItem.groupIndex(Type groupKeyType, IndexItemIriStrategy iriStrategy)
      : groupKeyType = groupKeyType,
        super.deserializeOnly(null, iri: iriStrategy);
}
```

### Usage Examples

**Note with GroupIndex (no FullIndex):**
```dart
@RootResource(
  PersonalNotesVocab.PersonalNote,
  'https://app.example.com/mappings/note-v1.ttl',
  iriStrategy: RootIriStrategy(RootIriConfig('note')),
  fullIndex: FullIndex.disabled,
)
class Note {
  @RdfProperty(SchemaNoteDigitalDocument.name)
  @CrdtLwwRegister()
  final String title;

  @RdfProperty(SchemaNoteDigitalDocument.dateCreated)
  @CrdtImmutable()
  final DateTime createdAt;
}

@IndexItem.groupIndex(NoteGroupKey, IndexItemIriStrategy(Note))
class NoteIndexEntry {
  @RdfProperty(SchemaNoteDigitalDocument.name) final String name;
  @RdfProperty(SchemaNoteDigitalDocument.dateCreated) final DateTime dateCreated;
  @RdfProperty(SchemaNoteDigitalDocument.dateModified) final DateTime dateModified;
  @RdfProperty(SchemaNoteDigitalDocument.keywords) final Set<String> keywords;
  @NoteCategoryProperty() final String? categoryId;
}

@GroupKey(
  Note,
  localName: 'notes_by_month',
  groupingProperties: [
    GroupingProperty(
      SchemaNoteDigitalDocument.dateCreated,
      transforms: [RegexTransform(r'^([0-9]{4})-([0-9]{2})-([0-9]{2}).*', r'${1}-${2}')]
    )
  ],
)
class NoteGroupKey {
  @RdfProperty(SchemaNoteDigitalDocument.dateCreated) final DateTime createdMonth;
}
```

**Category with default FullIndex:**
```dart
@RootResource(
  PersonalNotesVocab.NotesCategory,
  'https://app.example.com/mappings/category-v1.ttl',
)
class Category {
  @RdfProperty(SchemaCreativeWork.name)
  @CrdtLwwRegister()
  final String name;
}

// Optional: Define IndexItemConfig for FullIndex
@IndexItem.fullIndex(IndexItemIriStrategy(Category))
class CategoryIndexEntry {
  @RdfProperty(SchemaCreativeWork.name) final String name;
}
```

**Resource with both FullIndex and GroupIndex:**
```dart
@RootResource(
  PersonalNotesVocab.Document,
  'https://app.example.com/mappings/document-v1.ttl',
  fullIndex: FullIndex(
    localName: 'all_documents',
    policy: RootResourceFetchPolicy.onRequest,
  ),
)
class Document { /* ... */ }

// IndexItemConfig for FullIndex
@IndexItem.fullIndex(IndexItemIriStrategy(Document))
class DocumentFullIndexEntry {
  @RdfProperty(SchemaCreativeWork.name) final String name;
}

// IndexItemConfig for GroupIndex
@IndexItem.groupIndex(DocumentGroupKey, IndexItemIriStrategy(Document))
class DocumentGroupIndexEntry {
  @RdfProperty(SchemaCreativeWork.name) final String name;
  @RdfProperty(SchemaNoteDigitalDocument.dateCreated) final DateTime dateCreated;
}

@GroupKey(
  Document,
  localName: 'documents_by_type',
  groupingProperties: [/* ... */],
)
class DocumentGroupKey { /* ... */ }
```

**Custom FullIndex configuration:**
```dart
@RootResource(
  PersonalNotesVocab.LargeDataset,
  'https://app.example.com/mappings/dataset-v1.ttl',
  fullIndex: FullIndex(
    localName: 'all_datasets',
    policy: RootResourceFetchPolicy.onRequest,  // Lazy loading for large datasets
  ),
)
class LargeDataset { /* ... */ }
```

**Manual CRDT Mapping:**
```dart
@RootResource(
  PersonalNotesVocab.CustomResource,
  'https://app.example.com/mappings/custom-v1.ttl',
  generateCrdtMapping: false,  // Use manual .ttl file
)
class CustomResource { /* ... */ }
```

## Code Generation Algorithm

```
For each class C with @RootResource:
  1. Extract: resource type (C), crdtMapping IRI, fullIndex configuration
  
  2. Find all @GroupKey classes K where K.resourceType == C:
     - For each K: create GroupIndex with:
       - groupKeyType: K
       - localName: K.localName (default: "default")
       - groupingProperties: K.groupingProperties
     - Find associated @IndexItem.groupIndex(K, IndexItemIriStrategy(C)) for IndexItemConfig
  
  3. If fullIndex.isEnabled == true:
     - Create FullIndex with:
       - localName: fullIndex.localName
       - rootResourceFetchPolicy: fullIndex.policy
     - Find associated @IndexItem.fullIndex(IndexItemIriStrategy(C)) for IndexItemConfig (optional)
  
  4. For each IndexItemConfig (full or group):
     - Extract index properties from @RdfProperty fields
     - Create IndexItemConfig(IndexEntryType, {properties})
  
  5. Generate ResourceConfig with:
     - type: C
     - crdtMapping: Uri.parse(crdtMappingUri)
     - indices: [all generated FullIndex and GroupIndex instances]

Generate LocordaConfig factory function with all ResourceConfigs
```

## Generated Code Example

### Input (Annotated Classes)

```dart
@RootResource(
  PersonalNotesVocab.PersonalNote,
  'https://app.example.com/mappings/note-v1.ttl',
  iriStrategy: RootIriStrategy(RootIriConfig('note')),
  fullIndex: FullIndex.disabled,
)
class Note {
  @RdfProperty(SchemaNoteDigitalDocument.name) @CrdtLwwRegister()
  final String title;
}

@IndexItem.groupIndex(NoteGroupKey, IndexItemIriStrategy(Note))
class NoteIndexEntry {
  @RdfProperty(SchemaNoteDigitalDocument.name) final String name;
  @RdfProperty(SchemaNoteDigitalDocument.dateCreated) final DateTime dateCreated;
}

@GroupKey(
  Note,
  localName: 'notes_by_month',
  groupingProperties: [
    GroupingProperty(
      SchemaNoteDigitalDocument.dateCreated,
      transforms: [RegexTransform(r'^([0-9]{4})-([0-9]{2})-([0-9]{2}).*', r'${1}-${2}')]
    )
  ],
)
class NoteGroupKey { /* ... */ }

@RootResource(
  PersonalNotesVocab.NotesCategory,
  'https://app.example.com/mappings/category-v1.ttl',
)
class Category {
  @RdfProperty(SchemaCreativeWork.name) @CrdtLwwRegister()
  final String name;
}

@IndexItem.fullIndex(IndexItemIriStrategy(Category))
class CategoryIndexEntry {
  @RdfProperty(SchemaCreativeWork.name) final String name;
}
```

### Output (Generated Code)

```dart
// Generated: locorda_config.g.dart

LocordaConfig generateLocordaConfig() {
  return LocordaConfig(
    resources: [
      ResourceConfig(
        type: Note,
        crdtMapping: Uri.parse('https://app.example.com/mappings/note-v1.ttl'),
        indices: [
          GroupIndex(
            NoteGroupKey,
            localName: 'notes_by_month',
            item: IndexItemConfig(NoteIndexEntry, {
              SchemaNoteDigitalDocument.name,
              SchemaNoteDigitalDocument.dateCreated,
            }),
            groupingProperties: [
              GroupingProperty(
                SchemaNoteDigitalDocument.dateCreated,
                transforms: [RegexTransform(r'^([0-9]{4})-([0-9]{2})-([0-9]{2}).*', r'${1}-${2}')],
              ),
            ],
          ),
        ],
      ),
      ResourceConfig(
        type: Category,
        crdtMapping: Uri.parse('https://app.example.com/mappings/category-v1.ttl'),
        indices: [
          FullIndex(
            localName: 'default',
            rootResourceFetchPolicy: RootResourceFetchPolicy.prefetch,
            item: IndexItemConfig(CategoryIndexEntry, {
              SchemaCreativeWork.name,
            }),
          ),
        ],
      ),
    ],
  );
}
```

## Package Architecture

### Builder Location
- **Package**: `locorda_init_generator` (existing)
- **New Builder**: `locorda_config` (separate from `init_locorda` builder)
- **Rationale**: Requires `package:analyzer` dependency, already present in `locorda_init_generator`

### Build Configuration
```yaml
# packages/locorda_init_generator/build.yaml
builders:
  init_locorda:
    # Existing initLocorda generator
    import: "package:locorda_init_generator/builder.dart"
    builder_factories: ["buildInitLocorda"]
    # ...
  
  locorda_config:
    # NEW: Config generator
    import: "package:locorda_init_generator/builder.dart"
    builder_factories: ["buildConfigGenerator"]
    build_extensions: {".dart": ["locorda_config.g.dart"]}
    auto_apply: dependents
    build_to: source
```

### Package Dependencies
- **locorda_annotations**: Annotation definitions (`RootResource`, `FullIndex`, `GroupKey`, `IndexItem`) — NOT a dependency of the generator; resolved from consumer's transitive deps
- **locorda_core**: Runtime config classes (`LocordaConfig`, `ResourceConfig`, `FullIndex`, `GroupIndex`) — NOT a dependency of the generator
- **analyzer**: Resolved analysis for annotation detection + type hierarchy walking (supports custom `@RdfProperty` subclasses)
- **build**: Code generation infrastructure
- **glob**: File discovery for scanning `lib/` directory

## Implementation Phases

### Phase 1: LocordaConfig Generation
- Implement annotation classes: `FullIndex`, enhanced `RootResource`, `GroupKey`, `IndexItem` etc.
- Build annotation scanner using `package:analyzer`
- Generate `locorda_config.g.dart` with factory function
- Support FullIndex and GroupIndex with transforms
- **Integrate with initLocorda generator**: 
  - Detect presence of `locorda_config.g.dart`
  - Import and use generated `generateLocordaConfig()` in `initLocorda()` if available
  - Fall back to manual config passing if not generated (optional, like other init parts)

### Phase 2: CRDT Mapping Generation
- Scan CRDT property annotations (`@CrdtLwwRegister`, `@CrdtOrSet`, `@CrdtImmutable`, `@Crdt2PSet`, `@CrdtGRegister`)
- Map to RDF algorithms: `algo:lww-register`, `algo:or-set`, `algo:immutable`, `algo:2p-set`, `algo:g-register`
- Generate Turtle `.ttl` files in `assets/contracts/mappings/`
- Respect `generateCrdtMapping` flag and `build.yaml` configuration

---

**Related Documentation:**
- [CLAUDE.md](../../CLAUDE.md) - Development guidelines
- [main.dart](../../packages/locorda/example/personal_notes_app/lib/main.dart) - Current manual configuration
- [resource.dart](../../packages/locorda_annotations/lib/src/resource.dart) - Existing annotations
