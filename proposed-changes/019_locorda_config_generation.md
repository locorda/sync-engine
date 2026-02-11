# Concept: LocordaConfig Generation from Annotations

**Date:** 2026-02-11  
**Status:** Draft Concept  
**Author:** AI Analysis

## Executive Summary

This document analyzes the feasibility of automatically generating the `LocordaConfig` structure from existing Locorda annotations. The analysis shows that **partial generation is feasible**, with some configuration requiring explicit developer input.

## Current State Analysis

### Example Configuration (main.dart)

```dart
LocordaConfig(
  resources: [
    // Note resource with GroupIndex
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
                    RegexTransform(r'^([0-9]{4})-([0-9]{2})-([0-9]{2}).*',
                        r'${1}-${2}')
                  ])
            ]),
      ],
    ),

    // Category resource with FullIndex
    ResourceConfig(
      type: Category,
      crdtMapping: Uri.parse('$appBaseUrl/mappings/category-v1.ttl'),
      indices: [FullIndex(itemFetchPolicy: ItemFetchPolicy.prefetch)],
    ),
  ],
)
```

### Annotation Structure

#### Root Resource (Note)
```dart
@LcrdRootResource(
    PersonalNotesVocab.PersonalNote,
    RootIriStrategy(RootIriConfig('note')))
class Note {
  @RdfIriPart()
  final String id;

  @RdfProperty(SchemaNoteDigitalDocument.name)
  @CrdtLwwRegister()
  final String title;

  @NoteCategoryProperty()  // = PersonalNotesVocab.belongsToCategory
  @CrdtLwwRegister()
  final String? categoryId;

  @RdfProperty(SchemaNoteDigitalDocument.dateCreated)
  @CrdtImmutable()
  final DateTime createdAt;
  
  // ... more properties
}
```

#### Index Entry for Note
```dart
@LcrdIndexItem(IndexItemIriStrategy(Note))
class NoteIndexEntry {
  @RdfIriPart()
  final String id;

  @RdfProperty(SchemaNoteDigitalDocument.name)
  final String name;

  @RdfProperty(SchemaNoteDigitalDocument.dateCreated)
  final DateTime dateCreated;

  @RdfProperty(SchemaNoteDigitalDocument.dateModified)
  final DateTime dateModified;

  @RdfProperty(SchemaNoteDigitalDocument.keywords)
  final Set<String> keywords;

  @NoteCategoryProperty()
  final String? categoryId;
}
```

#### Group Key for Note
```dart
@LcrdGroupKey()
class NoteGroupKey {
  @RdfProperty(SchemaNoteDigitalDocument.dateCreated)
  final DateTime createdMonth;
  
  // ... constructors and methods
}
```

#### Root Resource (Category)
```dart
@LcrdRootResource(PersonalNotesVocab.NotesCategory)
class Category {
  @RdfIriPart()
  final String id;

  @RdfProperty(SchemaCreativeWork.name)
  @CrdtLwwRegister()
  final String name;
  
  // ... more properties
}
```

## Feasibility Analysis

### ✅ Fully Inferrable Information

1. **Resource Type**: Available from `@LcrdRootResource` class name
2. **Index Type (Full vs Group)**: Inferrable by checking if an `@LcrdIndexItem` references an `@LcrdGroupKey`
3. **Index Entry Type**: Available from `@LcrdIndexItem(IndexItemIriStrategy(Note))` annotation
4. **Index Entry Properties**: Extractable from `@RdfProperty` annotations in the index entry class
5. **Resource-to-IndexEntry Connection**: Via `@LcrdIndexItem(IndexItemIriStrategy(ResourceType))`

### ⚠️ Partially Inferrable Information

1. **Index localName**: Could default to `"default"` or be derived from index entry class name
2. **ItemFetchPolicy**: Could have a sensible default (e.g., `prefetch` for FullIndex, `onRequest` for GroupIndex)

### ❌ Not Inferrable - Requires Explicit Input

1. **GroupingProperties**: 
   - Which properties to group by
   - Transform logic (regex patterns)
   - Cannot be inferred from `@LcrdGroupKey` alone
2. **Custom ItemFetchPolicy**: If not using defaults

**Note:** The `crdtMapping` URI will be provided via `@CrdtRootResource` annotation (to be generated in future phases, currently holds static URI).

## Proposed Solution

### Annotation Extensions

Add new annotations to provide missing information:

```dart
/// Specifies CRDT mapping for a root resource.
///
/// This annotation declares the CRDT merge contract for a resource type.
/// In future phases, the mapping file itself will be generated from CRDT
/// annotations on the class properties. For now, it references a static
/// mapping file URI.
class CrdtRootResource {
  /// URI to CRDT mapping file (relative or absolute)
  /// Example: '$appBaseUrl/mappings/note-v1.ttl'
  final String mappingUri;
  
  const CrdtRootResource(this.mappingUri);
}

/// Specifies index configuration for a resource
class LcrdResourceConfig {
  /// Optional: override default localName for the index
  final String? indexLocalName;
  
  /// Optional: override default localName for the index
  final String? indexLocalName;
  
  /// Optional: specify item fetch policy
  final ItemFetchPolicy? itemFetchPolicy;
  
  const LcrdResourceConfig({
    this.indexLocalName,
    this.itemFetchPolicy,
  });
}

/// Specifies grouping configuration for GroupIndex
class LcrdGroupingConfig {
  /// Properties to use for grouping with their transforms
  final List<LcrdGroupingProperty> properties;
  
  const LcrdGroupingConfig({required this.properties});
}

/// Defines a grouping property with optional transforms
class LcrdGroupingProperty {
  /// The RDF property to group by
  final IriTerm property;
  
  /// Optional regex transforms to apply
  final List<LcrdRegexTransform> transforms;
  
  const LcrdGroupingProperty(
    this.property, {
    this.transforms = const [],
  });
}

/// Defines a regex transform for grouping values
class LcrdRegexTransform {
  final String pattern;
  final String replacement;
  
  const LcrdRegexTransform(this.pattern, this.replacement);
}
```

### Updated Annotation Usage

```dart
@LcrdRootResource(
    PersonalNotesVocab.PersonalNote,
    RootIriStrategy(RootIriConfig('note')))
@CrdtRootResource('\$appBaseUrl/mappings/note-v1.ttl')
@LcrdResourceConfig(indexLocalName: 'notes_by_month')
class Note {
  // ... properties
}

@LcrdGroupKey()
@LcrdGroupingConfig(properties: [
  LcrdGroupingProperty(
    SchemaNoteDigitalDocument.dateCreated,
    transforms: [
      LcrdRegexTransform(
        r'^([0-9]{4})-([0-9]{2})-([0-9]{2}).*',
        r'${1}-${2}')
    ])
])
class NoteGroupKey {
  @RdfProperty(SchemaNoteDigitalDocument.dateCreated)
  final DateTime createdMonth;
  // ...
}

@LcrdIndexItem(IndexItemIriStrategy(Note))
class NoteIndexEntry {
  // Properties automatically collected from @RdfProperty annotations
  // ...
}

@LcrdRootResource(PersonalNotesVocab.NotesCategory)
@CrdtRootResource('\$appBaseUrl/mappings/category-v1.ttl')
@LcrdResourceConfig(itemFetchPolicy: ItemFetchPolicy.prefetch)
class Category {
  // Full index is default when no @LcrdGroupKey is found
  // ...
}
```

### Code Generation Algorithm

```
For each class C with @LcrdRootResource:
  1. Extract resource type: C
  
  2. Extract crdtMapping from @CrdtRootResource
     - REQUIRED: throw error if missing
  
  3. Find associated @LcrdIndexItem class I where:
     - I has @LcrdIndexItem(IndexItemIriStrategy(C))
  
  4. Determine index type:
     - If I references an @LcrdGroupKey class K: GroupIndex
     - Otherwise: FullIndex
  
  5. Extract index properties from I:
     - Collect all @RdfProperty annotations from I's fields
     - Build Set<IriTerm> of property IRIs
  
  6. For GroupIndex:
     a. Extract groupKeyType from K class name
     b. Extract groupingProperties from @LcrdGroupingConfig on K
        - If missing: use default (no transforms)
     c. Extract localName from @LcrdResourceConfig or default
  
  7. For FullIndex:
     a. Extract itemFetchPolicy from @LcrdResourceConfig
        - Default: ItemFetchPolicy.prefetch
     b. Extract localName from @LcrdResourceConfig or default
  
  8. Generate ResourceConfig:
     ResourceConfig(
       type: C,
       crdtMapping: Uri.parse(crdtMappingUri),
       indices: [generatedIndex],
     )

Generate LocordaConfig:
  LocordaConfig(
    resources: [all generated ResourceConfigs]
  )
```

## Generated Code Example

### Input (Annotated Classes)

```dart
@LcrdRootResource(PersonalNotesVocab.PersonalNote, /*...*/)
@CrdtRootResource('\$appBaseUrl/mappings/note-v1.ttl')
class Note { /* ... */ }

@LcrdIndexItem(IndexItemIriStrategy(Note))
class NoteIndexEntry {
  @RdfProperty(SchemaNoteDigitalDocument.name)
  final String name;
  @RdfProperty(SchemaNoteDigitalDocument.dateCreated)
  final DateTime dateCreated;
  // ... more @RdfProperty fields
}

@LcrdGroupKey()
@LcrdGroupingConfig(/*...*/)
class NoteGroupKey { /* ... */ }

@LcrdRootResource(PersonalNotesVocab.NotesCategory)
@CrdtRootResource('\$appBaseUrl/mappings/category-v1.ttl')
class Category { /* ... */ }

// No IndexEntry for Category -> FullIndex without IndexItem
```

### Output (Generated Code)

```dart
// Generated file: locorda_config.g.dart

LocordaConfig generateLocordaConfig(String appBaseUrl) {
  return LocordaConfig(
    resources: [
      ResourceConfig(
        type: Note,
        crdtMapping: Uri.parse('$appBaseUrl/mappings/note-v1.ttl'),
        indices: [
          GroupIndex(
            NoteGroupKey,
            item: IndexItem(
              NoteIndexEntry,
              {
                SchemaNoteDigitalDocument.name,
                SchemaNoteDigitalDocument.dateCreated,
                SchemaNoteDigitalDocument.dateModified,
                SchemaNoteDigitalDocument.keywords,
                PersonalNotesVocab.belongsToCategory,
              },
            ),
            groupingProperties: [
              GroupingProperty(
                SchemaNoteDigitalDocument.dateCreated,
                transforms: [
                  RegexTransform(
                    r'^([0-9]{4})-([0-9]{2})-([0-9]{2}).*',
                    r'${1}-${2}',
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
      ResourceConfig(
        type: Category,
        crdtMapping: Uri.parse('$appBaseUrl/mappings/category-v1.ttl'),
        indices: [
          FullIndex(
            itemFetchPolicy: ItemFetchPolicy.prefetch,
          ),
        ],
      ),
    ],
  );
}
```

## Advantages

### ✅ Benefits

1. **Single Source of Truth**: Configuration mirrors annotation structure
2. **Type Safety**: Compile-time verification of resource/index relationships
3. **DRY Principle**: No duplication of property lists
4. **Maintainability**: Changes to index properties automatically reflected
5. **Discoverability**: Annotations make indexing strategy explicit in model classes
6. **Reduced Boilerplate**: Developers only specify what's necessary

### ⚠️ Trade-offs

1. **Additional Annotations**: More code in model classes
2. **Complexity Transfer**: Configuration logic moves from runtime to compile-time
3. **Dynamic Configuration Limited**: Less flexible than manual configuration
4. **Learning Curve**: Developers must understand annotation system

## Alternative Approaches

### Option 1: Minimal Annotations + Convention over Configuration

```dart
@LcrdRootResource(PersonalNotesVocab.PersonalNote)
@CrdtRootResource('\$appBaseUrl/mappings/note-v1.ttl')
class Note { /* ... */ }

@LcrdIndexItem(IndexItemIriStrategy(Note))
class NoteIndexEntry { /* ... */ }

@LcrdGroupKey()
class NoteGroupKey { /* ... */ }
```

**Conventions:**
- GroupIndex if `@LcrdGroupKey` exists, otherwise FullIndex
- IndexItem properties: all `@RdfProperty` fields from index entry class
- GroupingProperties: inferred from `@RdfProperty` fields in group key class (no transforms)
- ItemFetchPolicy: prefetch for FullIndex, onRequest for GroupIndex
- localName: "default"

**Developer Override:** Provide manual config only when conventions don't fit.

### Option 2: Keep Manual Configuration

Don't generate at all - keep current manual `LocordaConfig` approach.

**Rationale:** Configuration is explicit, flexible, and clear. Only ~30 lines of code per resource.

### Option 3: Separate Configuration Files

Use YAML/JSON configuration files that reference annotated classes.

```yaml
# locorda_config.yaml
resources:
  - type: Note
    crdtMapping: $appBaseUrl/mappings/note-v1.ttl
    index:
      type: group
      groupKey: NoteGroupKey
      indexEntry: NoteIndexEntry
      groupingProperties:
        - property: schema:dateCreated
          transforms:
            - regex: '^([0-9]{4})-([0-9]{2})-([0-9]{2}).*'
              replacement: '${1}-${2}'
```

## Recommendations

### Recommended Approach: **Minimal Annotations + Convention (Option 1)**

**Reasoning:**
1. Balances explicit configuration with minimal boilerplate
2. Most configuration is inferrable from existing annotations
3. Developer override available for edge cases
4. Preserves flexibility while reducing repetition

### Implementation Phases

#### Phase 1: Basic Infrastructure (MVP)
- Define core annotations: `@CrdtRootResource`, `@LcrdResourceConfig`, `@LcrdGroupingConfig`
- Build annotation scanner using `package:analyzer`
- Generate basic ResourceConfig without grouping transforms
- Support FullIndex and GroupIndex (without transforms)
- Read static CRDT mapping URIs from `@CrdtRootResource`

#### Phase 2: Grouping Support
- Implement `@LcrdRegexTransform` annotations
- Generate GroupingProperty configurations
- Add validation for property consistency

#### Phase 3: Advanced Features
- Custom ItemFetchPolicy configurations
- Multi-index support per resource
- Validation and error reporting improvements

#### Phase 4: Developer Experience
- IDE support (code completion, navigation)
- Error messages and diagnostics
- Migration tools from manual config

#### Phase 5: CRDT Mapping Generation (Future)
- Generate CRDT mapping files from `@CrdtLwwRegister`, `@CrdtOrSet`, etc. annotations
- Replace static `@CrdtRootResource` URIs with generated mappings
- Full end-to-end annotation-driven configuration

## Open Questions

1. **Multiple Indices per Resource**: How to annotate when a resource has multiple indices?
   - Proposal: `@LcrdResourceConfig(indices: [...])`

2. **Conditional Configuration**: How to handle environment-specific URIs?
   - Proposal: Generate factory function with parameters (see generated code example)

3. **Validation Timing**: When to validate config consistency?
   - Proposal: Both at build time (generator) and runtime (first use)

4. **Index Entry Omissions**: What if an index entry class omits properties from the full resource?
   - Answer: Current behavior is correct - index entries explicitly list included properties

5. **Property Discovery**: Should we scan the resource class to validate index properties exist?
   - Proposal: Yes, with warnings for properties in index but not in resource

## Migration Strategy

### For Existing Apps

1. Keep manual configuration working (backward compatible)
2. Introduce annotations incrementally
3. Provide migration tool: analyze manual config → suggest annotations
4. Side-by-side: manual config with generated config validation

### Example Migration

**Before:**
```dart
LocordaConfig(
  resources: [
    ResourceConfig(type: Note, crdtMapping: /*...*/, indices: [/*...*/]),
  ],
)
```

**After:**
```dart
// Add annotations to model classes
@CrdtRootResource('...')
class Note { /* ... */ }

// Generated code
import 'locorda_config.g.dart';

// Use in main.dart
config: generateLocordaConfig(appBaseUrl),
```

## Conclusion

**Full generation of LocordaConfig from annotations is feasible** with the addition of:
1. `@CrdtRootResource` annotation (CRDT mapping URI, to be generated in future)
2. `@LcrdResourceConfig` annotation (optional index configuration overrides)
3. `@LcrdGroupingConfig` annotation (grouping properties + transforms)
4. Convention-based defaults for common cases

**Core Insight:** The existing `@LcrdIndexItem(IndexItemIriStrategy(Note))` already provides the critical connection between resources and their index entries. Combined with `@CrdtRootResource` for mapping URIs and property annotations, this gives us sufficient information to generate the full configuration automatically.

**Future Work:** The `@CrdtRootResource` annotation currently holds a static mapping URI. In future phases, the mapping file itself will be generated from CRDT annotations (`@CrdtLwwRegister`, `@CrdtOrSet`, etc.) on the resource properties, making the system fully annotation-driven.

**Next Steps:**
1. Prototype the annotation scanner
2. Implement basic code generator for MVP (Phase 1)
3. Test with personal_notes_app
4. Gather feedback and iterate

---

**Related Documentation:**
- [CLAUDE.md](../../CLAUDE.md) - Development guidelines
- [main.dart](../../packages/locorda/example/personal_notes_app/lib/main.dart) - Current configuration example
- [resource.dart](../../packages/locorda_annotations/lib/src/resource.dart) - Existing annotations
