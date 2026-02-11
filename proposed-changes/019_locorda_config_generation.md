# Concept: LocordaConfig Generation from Annotations

**Date:** 2026-02-11  
**Status:** Draft Concept  
**Author:** Klas Kalaß & AI Analysis (copilot/claude)

## Executive Summary

This document defines how `LocordaConfig` is automatically generated from `@LcrdRootResource` and related annotations, eliminating the need for manual configuration in most cases.

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
            item: IndexItem(NoteIndexEntry, {
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
      indices: [FullIndex(itemFetchPolicy: ItemFetchPolicy.prefetch)],
    ),
  ],
)
```

### Current Annotations

```dart
@LcrdRootResource(PersonalNotesVocab.PersonalNote, RootIriStrategy(...))
class Note {
  @RdfProperty(...) @CrdtLwwRegister() final String title;
  @RdfProperty(...) @CrdtImmutable() final DateTime createdAt;
}

@LcrdIndexItem(IndexItemIriStrategy(Note))
class NoteIndexEntry {
  @RdfProperty(SchemaNoteDigitalDocument.name) final String name;
  @RdfProperty(SchemaNoteDigitalDocument.dateCreated) final DateTime dateCreated;
}

@LcrdGroupKey()
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

### LcrdFullIndex Configuration

```dart
class LcrdFullIndex {
  final bool isEnabled;
  final String localName;
  final ItemFetchPolicy policy;
  
  /// Creates a FullIndex configuration with defaults.
  /// Default localName: 'default'
  /// Default policy: ItemFetchPolicy.prefetch
  const LcrdFullIndex({
    this.localName = 'default',
    this.policy = ItemFetchPolicy.prefetch,
  }) : isEnabled = true;
  
  /// Disables FullIndex generation for this resource.
  /// Use when resource only has GroupIndex indices.
  const LcrdFullIndex.disabled()
      : isEnabled = false,
        localName = '',
        policy = ItemFetchPolicy.prefetch;
}
```

### Enhanced LcrdRootResource

```dart
class LcrdRootResource extends RdfGlobalResource {
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
  /// Default: LcrdFullIndex() (enabled with localName='default', policy=prefetch)
  /// Use LcrdFullIndex.disabled when resource only has GroupIndex indices.
  final LcrdFullIndex fullIndex;

  const LcrdRootResource(
    IriTerm? classIri,
    this.crdtMapping, {
    RootIriStrategy iriStrategy = const RootIriStrategy(),
    this.generateCrdtMapping = true,
    this.fullIndex = const LcrdFullIndex(),
  }) : super(classIri, iriStrategy);
}
```

### Enhanced LcrdGroupKey

```dart
class LcrdGroupKey extends RdfLocalResource {
  /// The resource type this group index is for
  final Type resourceType;
  
  /// Local name for this group index (default: "default")
  final String? localName;
  
  /// Properties to use for grouping with optional transforms
  final List<LcrdGroupingProperty> groupingProperties;
  
  const LcrdGroupKey(
    this.resourceType, {
    this.localName,
    this.groupingProperties = const [],
  });
}

class LcrdGroupingProperty {
  final IriTerm property;
  final List<LcrdRegexTransform> transforms;
  
  const LcrdGroupingProperty(this.property, {this.transforms = const []});
}

class LcrdRegexTransform {
  final String pattern;
  final String replacement;
  
  const LcrdRegexTransform(this.pattern, this.replacement);
}
```

### Enhanced LcrdIndexItem

```dart
class LcrdIndexItem extends RdfGlobalResource {
  /// The index type this item belongs to (GroupKey class or null for FullIndex)
  final Type? groupKeyType;
  
  /// Named constructor for FullIndex entries
  /// Usage: @LcrdIndexItem.fullIndex(IndexItemIriStrategy(Note))
  /// 
  /// Note: IndexItemIriStrategy must be passed as parameter (not resourceType)
  /// due to Dart const constructor limitations - cannot create new objects
  /// inside const constructors.
  const LcrdIndexItem.fullIndex(IndexItemIriStrategy iriStrategy)
      : groupKeyType = null,
        super.deserializeOnly(null, iri: iriStrategy);
  
  /// Named constructor for GroupIndex entries
  /// Usage: @LcrdIndexItem.groupIndex(NoteGroupKey, IndexItemIriStrategy(Note))
  const LcrdIndexItem.groupIndex(Type groupKeyType, IndexItemIriStrategy iriStrategy)
      : groupKeyType = groupKeyType,
        super.deserializeOnly(null, iri: iriStrategy);
}
```

### Usage Examples

**Note with GroupIndex (no FullIndex):**
```dart
@LcrdRootResource(
  PersonalNotesVocab.PersonalNote,
  'https://app.example.com/mappings/note-v1.ttl',
  iriStrategy: RootIriStrategy(RootIriConfig('note')),
  fullIndex: LcrdFullIndex.disabled,
)
class Note {
  @RdfProperty(SchemaNoteDigitalDocument.name)
  @CrdtLwwRegister()
  final String title;

  @RdfProperty(SchemaNoteDigitalDocument.dateCreated)
  @CrdtImmutable()
  final DateTime createdAt;
}

@LcrdIndexItem.groupIndex(NoteGroupKey, IndexItemIriStrategy(Note))
class NoteIndexEntry {
  @RdfProperty(SchemaNoteDigitalDocument.name) final String name;
  @RdfProperty(SchemaNoteDigitalDocument.dateCreated) final DateTime dateCreated;
  @RdfProperty(SchemaNoteDigitalDocument.dateModified) final DateTime dateModified;
  @RdfProperty(SchemaNoteDigitalDocument.keywords) final Set<String> keywords;
  @NoteCategoryProperty() final String? categoryId;
}

@LcrdGroupKey(
  Note,
  localName: 'notes_by_month',
  groupingProperties: [
    LcrdGroupingProperty(
      SchemaNoteDigitalDocument.dateCreated,
      transforms: [LcrdRegexTransform(r'^([0-9]{4})-([0-9]{2})-([0-9]{2}).*', r'${1}-${2}')]
    )
  ],
)
class NoteGroupKey {
  @RdfProperty(SchemaNoteDigitalDocument.dateCreated) final DateTime createdMonth;
}
```

**Category with default FullIndex:**
```dart
@LcrdRootResource(
  PersonalNotesVocab.NotesCategory,
  'https://app.example.com/mappings/category-v1.ttl',
)
class Category {
  @RdfProperty(SchemaCreativeWork.name)
  @CrdtLwwRegister()
  final String name;
}

// Optional: Define IndexItem for FullIndex
@LcrdIndexItem.fullIndex(IndexItemIriStrategy(Category))
class CategoryIndexEntry {
  @RdfProperty(SchemaCreativeWork.name) final String name;
}
```

**Resource with both FullIndex and GroupIndex:**
```dart
@LcrdRootResource(
  PersonalNotesVocab.Document,
  'https://app.example.com/mappings/document-v1.ttl',
  fullIndex: LcrdFullIndex(
    localName: 'all_documents',
    policy: ItemFetchPolicy.onRequest,
  ),
)
class Document { /* ... */ }

// IndexItem for FullIndex
@LcrdIndexItem.fullIndex(IndexItemIriStrategy(Document))
class DocumentFullIndexEntry {
  @RdfProperty(SchemaCreativeWork.name) final String name;
}

// IndexItem for GroupIndex
@LcrdIndexItem.groupIndex(DocumentGroupKey, IndexItemIriStrategy(Document))
class DocumentGroupIndexEntry {
  @RdfProperty(SchemaCreativeWork.name) final String name;
  @RdfProperty(SchemaNoteDigitalDocument.dateCreated) final DateTime dateCreated;
}

@LcrdGroupKey(
  Document,
  localName: 'documents_by_type',
  groupingProperties: [/* ... */],
)
class DocumentGroupKey { /* ... */ }
```

**Custom FullIndex configuration:**
```dart
@LcrdRootResource(
  PersonalNotesVocab.LargeDataset,
  'https://app.example.com/mappings/dataset-v1.ttl',
  fullIndex: LcrdFullIndex(
    localName: 'all_datasets',
    policy: ItemFetchPolicy.onRequest,  // Lazy loading for large datasets
  ),
)
class LargeDataset { /* ... */ }
```

**Manual CRDT Mapping:**
```dart
@LcrdRootResource(
  PersonalNotesVocab.CustomResource,
  'https://app.example.com/mappings/custom-v1.ttl',
  generateCrdtMapping: false,  // Use manual .ttl file
)
class CustomResource { /* ... */ }
```

## Code Generation Algorithm

```
For each class C with @LcrdRootResource:
  1. Extract: resource type (C), crdtMapping IRI, fullIndex configuration
  
  2. Find all @LcrdGroupKey classes K where K.resourceType == C:
     - For each K: create GroupIndex with:
       - groupKeyType: K
       - localName: K.localName (default: "default")
       - groupingProperties: K.groupingProperties
     - Find associated @LcrdIndexItem.groupIndex(K, IndexItemIriStrategy(C)) for IndexItem
  
  3. If fullIndex.isEnabled == true:
     - Create FullIndex with:
       - localName: fullIndex.localName
       - itemFetchPolicy: fullIndex.policy
     - Find associated @LcrdIndexItem.fullIndex(IndexItemIriStrategy(C)) for IndexItem (optional)
  
  4. For each IndexItem (full or group):
     - Extract index properties from @RdfProperty fields
     - Create IndexItem(IndexEntryType, {properties})
  
  5. Generate ResourceConfig with:
     - type: C
     - crdtMapping: Uri.parse(crdtMappingUri)
     - indices: [all generated FullIndex and GroupIndex instances]

Generate LocordaConfig factory function with all ResourceConfigs
```

## Generated Code Example

### Input (Annotated Classes)

```dart
@LcrdRootResource(
  PersonalNotesVocab.PersonalNote,
  'https://app.example.com/mappings/note-v1.ttl',
  iriStrategy: RootIriStrategy(RootIriConfig('note')),
  fullIndex: LcrdFullIndex.disabled,
)
class Note {
  @RdfProperty(SchemaNoteDigitalDocument.name) @CrdtLwwRegister()
  final String title;
}

@LcrdIndexItem.groupIndex(NoteGroupKey, IndexItemIriStrategy(Note))
class NoteIndexEntry {
  @RdfProperty(SchemaNoteDigitalDocument.name) final String name;
  @RdfProperty(SchemaNoteDigitalDocument.dateCreated) final DateTime dateCreated;
}

@LcrdGroupKey(
  Note,
  localName: 'notes_by_month',
  groupingProperties: [
    LcrdGroupingProperty(
      SchemaNoteDigitalDocument.dateCreated,
      transforms: [LcrdRegexTransform(r'^([0-9]{4})-([0-9]{2})-([0-9]{2}).*', r'${1}-${2}')]
    )
  ],
)
class NoteGroupKey { /* ... */ }

@LcrdRootResource(
  PersonalNotesVocab.NotesCategory,
  'https://app.example.com/mappings/category-v1.ttl',
)
class Category {
  @RdfProperty(SchemaCreativeWork.name) @CrdtLwwRegister()
  final String name;
}

@LcrdIndexItem.fullIndex(IndexItemIriStrategy(Category))
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
            item: IndexItem(NoteIndexEntry, {
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
            itemFetchPolicy: ItemFetchPolicy.prefetch,
            item: IndexItem(CategoryIndexEntry, {
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
- **locorda_annotations**: Annotation definitions (`LcrdRootResource`, `LcrdFullIndex`, `LcrdGroupKey`, `LcrdIndexItem`)
- **locorda_core**: Runtime config classes (`LocordaConfig`, `ResourceConfig`, `FullIndex`, `GroupIndex`)
- **analyzer**: AST traversal for annotation scanning
- **build**: Code generation infrastructure

## Implementation Phases

### Phase 1: LocordaConfig Generation
- Implement annotation classes: `LcrdFullIndex`, enhanced `LcrdRootResource`, `LcrdGroupKey`, `LcrdIndexItem` etc.
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
