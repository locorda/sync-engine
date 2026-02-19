# Simplified Annotations & Automatic Vocabulary Generation

**Date:** 2026-02-13 (Updated: 2026-02-19)  
**Status:** Implementation Complete (in rdf mapper library)  
**Author:** Klas Kalaß & AI Analysis (copilot/claude)  
**Related:** [020-crdt-mapping-generation.md](020-crdt-mapping-generation.md), [019_locorda_config_generation.md](019_locorda_config_generation.md), [022-annotation-api-cleanup.md](022-annotation-api-cleanup.md)

## Status

✅ **Implemented in `locorda_rdf_mapper_annotations` v0.11.8+**

The vocabulary generation feature has been implemented in the RDF mapper library (`locorda_rdf_mapper_annotations` and `locorda_rdf_mapper_generator`). This document now serves as:

1. **Problem statement** - Why vocabulary generation was needed
2. **Implementation reference** - How to use the `.define()` API in sync-engine
3. **Integration guide** - How sync-engine annotations should leverage this feature

For complete implementation details, see:
- [RDF Mapper Annotations README](https://github.com/locorda/rdf/blob/main/packages/locorda_rdf_mapper_annotations/README.md)
- [Vocabulary Generation Guide](https://github.com/locorda/rdf/blob/main/packages/locorda_rdf_mapper_annotations/doc/vocab_generating.md)

---

## Problem Statement

Locorda requires RDF vocabulary IRIs for every class and every custom property. For developers who use only standard vocabularies (schema.org etc.), this works well. But for developers who don't care about RDF semantics and just want CRDT sync, the annotation burden was significant:

### Previous Pain Points

**1. Manual Vocabulary Class**  
Developers had to hand-write vocabulary classes with `IriTerm` constants:

```dart
class PersonalNotesVocab {
  static const baseIri = '$appBaseUrl/vocabulary/personal-notes#';
  static const NotesCategory = IriTerm('${baseIri}NotesCategory');
  static const PersonalNote = IriTerm('${baseIri}PersonalNote');
  static const belongsToCategory = IriTerm('${baseIri}belongsToCategory');
  static const categoryColor = IriTerm('${baseIri}categoryColor');
  // ... every single custom predicate ...
}
```

**2. Extensive RDF Knowledge Required**  
Developers needed to understand:
- What an IRI is and what `IriTerm` means
- Fragment identifiers and namespace patterns
- When to use standard vocabularies vs custom predicates
- How to structure OWL ontologies

**3. Manual TTL File Maintenance**  
The OWL vocabulary file had to be hand-written and kept in sync with the Dart code — violation of DRY.

**4. Annotation Verbosity**  
Even simple models required extensive annotations:

```dart
@RootResource.external(
  IriTerm('$appBaseUrl/vocabulary/task#Task'),
  '$appBaseUrl/contracts/task-v1#',
)
class Task {
  @RdfProperty(IriTerm('$appBaseUrl/vocabulary/task#completed'))
  final bool completed;
}
```

**5. Manual CRDT Merge Contract Files**  
Developers had to manually create TTL files defining property-level CRDT merge strategies.

---

## Solution: Automatic Vocabulary + Merge Contract Generation

The RDF mapper library provides automatic vocabulary generation via `AppVocab` (see [vocabulary generation guide](https://github.com/locorda/rdf/blob/main/packages/locorda_rdf_mapper_annotations/doc/vocab_generating.md)).

The sync-engine integrates this and adds **automatic CRDT merge contract generation** with a unified, type-safe API.

### Key Insight: Two Independent Dimensions

Vocabulary and CRDT merge contracts are **independent concerns** that can each be generated or external:

| Vocabulary | Merge Contract | Use Case |
|------------|---------------|----------|
| 🔧 Generated | 🔧 Generated | Default: custom app models |
| 📦 External | 🔧 Generated | Schema.org vocab + custom CRDT rules (common!) |
| 🔧 Generated | 📦 External | Custom vocab + shared CRDT contracts |
| 📦 External | 📦 External | Full interop with external standards |

### 1. New Type-Safe API with Named Constructors

Four named constructors prevent invalid combinations and make intent explicit:

**RootResource API:**
```dart
class RootResource extends RdfGlobalResource {
  // Primitive fields for const compatibility (read by generator)
  final AppVocab? _vocab;
  final IriTerm? _explicitClassIri;
  final String? _contractAppBaseUri;
  final String? _explicitContractIri;
  final String _contractVersion;
  final String? _contractPath;
  final bool _generateContract;
  final String? _contractLabel;
  final String? _contractComment;
  final List<IriTerm> _contractImports;
  final FullIndex fullIndex;
  
  // DEFAULT: Vocabulary + Merge Contract both generated (90% of cases)
  const RootResource(
    AppVocab vocab, {
    String mergeContractVersion = 'v1',
    String? mergeContractPath,      // Override: '/contracts/my-note-v2'
    String? mergeContractLabel,
    String? mergeContractComment,
    List<IriTerm> mergeContractImports = const [MergeContracts.coreV1],
    this.fullIndex = const FullIndex(),
    RootIriStrategy iriStrategy = const RootIriStrategy(),
  }) : _vocab = vocab,
       _explicitClassIri = null,
       _contractAppBaseUri = vocab.appBaseUri,
       _explicitContractIri = null,
       _contractVersion = mergeContractVersion,
       _contractPath = mergeContractPath,
       _generateContract = true,
       _contractLabel = mergeContractLabel,
       _contractComment = mergeContractComment,
       _contractImports = mergeContractImports,
       super.define(vocab, iriStrategy: iriStrategy);
  
  // External Vocabulary + Generated Merge Contract (second most common!)
  const RootResource.externalVocab(
    IriTerm classIri,
    String mergeContractAppBaseUri, {
    String mergeContractVersion = 'v1',
    String? mergeContractPath,
    String? mergeContractLabel,
    String? mergeContractComment,
    List<IriTerm> mergeContractImports = const [MergeContracts.coreV1],
    this.fullIndex = const FullIndex(),
    RootIriStrategy iriStrategy = const RootIriStrategy(),
  }) : _vocab = null,
       _explicitClassIri = classIri,
       _contractAppBaseUri = mergeContractAppBaseUri,
       _explicitContractIri = null,
       _contractVersion = mergeContractVersion,
       _contractPath = mergeContractPath,
       _generateContract = true,
       _contractLabel = mergeContractLabel,
       _contractComment = mergeContractComment,
       _contractImports = mergeContractImports,
       super(classIri, iri: iriStrategy);
  
  // Generated Vocabulary + External Merge Contract
  const RootResource.externalContract(
    AppVocab vocab,
    String mergeContractIri, {
    this.fullIndex = const FullIndex(),
    RootIriStrategy iriStrategy = const RootIriStrategy(),
  }) : _vocab = vocab,
       _explicitClassIri = null,
       _contractAppBaseUri = null,
       _explicitContractIri = mergeContractIri,
       _contractVersion = 'v1',
       _contractPath = null,
       _generateContract = false,
       _contractLabel = null,
       _contractComment = null,
       _contractImports = const [],
       super.define(vocab, iriStrategy: iriStrategy);
  
  // Both External (full interop with standards)
  const RootResource.external(
    IriTerm classIri,
    String mergeContractIri, {
    this.fullIndex = const FullIndex(),
    RootIriStrategy iriStrategy = const RootIriStrategy(),
  }) : _vocab = null,
       _explicitClassIri = classIri,
       _contractAppBaseUri = null,
       _explicitContractIri = mergeContractIri,
       _contractVersion = 'v1',
       _contractPath = null,
       _generateContract = false,
       _contractLabel = null,
       _contractComment = null,
       _contractImports = const [],
       super(classIri, iri: iriStrategy);
}
```

**MergeContracts** (standard imports):
```dart
class MergeContracts {
  static const IriTerm coreV1 =
      IriTerm('https://w3id.org/solid-crdt-sync/contracts/core-v1');
  static const IriTerm indexV1 =
      IriTerm('https://w3id.org/solid-crdt-sync/contracts/index-v1');
  static const IriTerm shardV1 =
      IriTerm('https://w3id.org/solid-crdt-sync/contracts/shard-v1');
  static const IriTerm clientInstallationV1 = IriTerm(
      'https://w3id.org/solid-crdt-sync/contracts/client-installation-v1');
}
```

**FullIndex** (parameter class):
```dart
class FullIndex {
  final bool isEnabled;
  final String localName;
  final ItemFetchPolicy policy;

  const FullIndex({
    this.localName = 'default',
    this.policy = ItemFetchPolicy.prefetch,
  }) : isEnabled = true;

  const FullIndex.disabled()
      : isEnabled = false,
        localName = '',
        policy = ItemFetchPolicy.prefetch;
}
```

**Note:** These are **annotation parameter classes** in `locorda_annotations`. The builder generates corresponding **config classes** in `locorda_objects` with `Config` suffix (`FullIndexConfig`, etc.).

**Usage Examples:**

**1. Default: Both Generated (90% of cases)**
```dart
const appVocab = AppVocab(appBaseUri: appBaseUrl);

@RootResource(appVocab)
class Note {
  @RdfIriPart()
  final String id;

  final String title;       // Auto: dc:title or app:title
  final String content;     // Auto: app:content

  @OrSet()
  final Set<String> tags;   // Auto: app:tags
}
```
**Generated IRIs:**
- Vocabulary: `https://myapp.example.com/vocab#Note`
- Merge Contract: `https://myapp.example.com/contracts/note-v1#`

**2. External Vocab (Schema.org) + Generated Contract (Very Common!)**
```dart
@RootResource.externalVocab(
  Schema.Article,
  appBaseUrl,  // Base for contract generation
)
class BlogPost {
  @RdfProperty(Schema.headline)
  final String title;
  
  final String excerpt;  // Custom property, needs contract rule
}
```
**Generated IRIs:**
- Vocabulary: `schema:Article` (external)
- Merge Contract: `https://myapp.example.com/contracts/blogpost-v1#` (generated)

**3. Generated Vocab + External Contract**
```dart
@RootResource.externalContract(
  appVocab,
  'https://crdt-contracts.org/standard/note-v1#',
)
class StandardNote {
  final String title;
  final String content;
}
```
**Generated IRIs:**
- Vocabulary: `https://myapp.example.com/vocab#StandardNote` (generated)
- Merge Contract: `https://crdt-contracts.org/standard/note-v1#` (external)

**4. Both External (Full Interop)**
```dart
@RootResource.external(
  Schema.Recipe,
  'https://schema.org/contracts/recipe-v1#',
)
class Recipe {
  @RdfProperty(Schema.name)
  final String name;
}
```
**Generated IRIs:**
- Vocabulary: `schema:Recipe` (external)
- Merge Contract: `https://schema.org/contracts/recipe-v1#` (external)

### 2. Merge Contract IRI Generation in Builder

The generator constructs contract IRIs for cases where `_generateContract == true`:

```dart
// In locorda_builder/lib/src/merge_contract_builder.dart

String _resolveMergeContractIri(RootResource annotation, String className) {
  // Explicit IRI provided (external contract)
  if (annotation._explicitContractIri != null) {
    return annotation._explicitContractIri!;
  }
  
  // Generate from appBaseUri (default or .externalVocab)
  final baseUri = annotation._contractAppBaseUri!;
  final classNameLower = className.toLowerCase();
  
  // Use custom path or default: /contracts/{className}-v{version}
  final path = annotation._contractPath ?? 
               '/contracts/$classNameLower-v${annotation._contractVersion}';
  
  return '$baseUri$path#';
}
```

**Property IRI Resolution** (already handled by RDF mapper, same logic):
```dart
IriTerm? _extractPropertyPredicate(FieldElement field, ClassElement classElement) {
  // 1. Explicit @RdfProperty → use its predicate
  final rdfProp = findRdfPropertyAnnotation(field);
  if (rdfProp != null) return rdfProp.predicate;
  
  // 2. Generated vocab mode? → derive from field name + wellKnownProperties
  final annotation = findResourceAnnotation(classElement);
  if (annotation._vocab != null) {
    final vocabBase = '${annotation._vocab.appBaseUri}${annotation._vocab.vocabPath}#';
    
    // Check wellKnownProperties first
    final wellKnown = annotation._vocab.wellKnownProperties[field.name];
    if (wellKnown != null) return wellKnown;
    
    // Generate custom property
    return IriTerm('$vocabBase${field.name}');
  }
  
  // 3. External vocab → must have explicit @RdfProperty
  return null;  // Build error if missing
}
```

**Class IRI Resolution:**
```dart
IriTerm _resolveClassIri(ClassElement classElement) {
  final annotation = findResourceAnnotation(classElement);
  
  // Explicit classIri provided (external vocab)
  if (annotation._explicitClassIri != null) {
    return annotation._explicitClassIri!;
  }
  
  // Generated vocab
  final vocabBase = '${annotation._vocab!.appBaseUri}${annotation._vocab!.vocabPath}#';
  return IriTerm('$vocabBase${classElement.name}');
}
```

### 3. Migration Example: Personal Notes App

**Before (manual vocabulary + CRDT mapping):**

```dart
// lib/models/vocabulary/personal_notes_vocab.dart
class PersonalNotesVocab {
  static const baseIri = '$appBaseUrl/vocabulary/personal-notes#';
  static const NotesCategory = IriTerm('${baseIri}NotesCategory');
  static const PersonalNote = IriTerm('${baseIri}PersonalNote');
  static const belongsToCategory = IriTerm('${baseIri}belongsToCategory');
  static const categoryColor = IriTerm('${baseIri}categoryColor');
  static const categoryIcon = IriTerm('${baseIri}categoryIcon');
  static const archived = IriTerm('${baseIri}archived');
}

// lib/models/note.dart
@RootResource.external(
  PersonalNotesVocab.PersonalNote,
  '$appBaseUrl/contracts/personal-note-v1#',
)
class Note {
  @RdfIriPart()
  final String id;
  
  @RdfProperty(PersonalNotesVocab.title)
  final String title;
  
  @RdfProperty(PersonalNotesVocab.content)
  final String content;
  
  @RdfProperty(PersonalNotesVocab.belongsToCategory)
  final String? categoryId;
  
  @RdfProperty(PersonalNotesVocab.archived)
  final bool archived;
}
```

**After (.define() mode):**

```dart
// lib/config/vocab.dart
const appVocab = AppVocab(
  appBaseUri: appBaseUrl,
  wellKnownProperties: {
    'title': Dc.title,           // Use Dublin Core for title
    'description': Dc.description,
    'created': Dc.created,
    'modified': Dc.modified,
  },
);

// lib/models/note.dart
@RootResource.externalContract(
  appVocab,
  '$appBaseUrl/contracts/personal-note-v1#',
)
class Note {
  @RdfIriPart()
  final String id;
  
  @RdfProperty(PersonalNotesVocab.title)
  final String title;
  
  @RdfProperty(PersonalNotesVocab.content)
  final String content;
  
  @RdfProperty(PersonalNotesVocab.belongsToCategory)
  final String? categoryId;
  
  @RdfProperty(PersonalNotesVocab.archived)
  final bool archived;
}
```

**After (automatic generation):**

```dart
// lib/config/vocab.dart
const appVocab = AppVocab(
  appBaseUri: appBaseUrl,
  wellKnownProperties: {
    'title': Dc.title,           // Use Dublin Core for title
    'description': Dc.description,
    'created': Dc.created,
    'modified': Dc.modified,
  },
);

// lib/models/note.dart
@RootResource(appVocab)  // DEFAULT constructor - both generated!
class Note {
  @RdfIriPart()
  final String id;
  
  final String title;       // → dc:title (via wellKnownProperties)
  final String content;     // → app:content (auto-generated)
  final String? categoryId; // → app:categoryId (auto-generated)
  final bool archived;      // → app:archived (auto-generated)
}
```

**Generated artifacts:**
- ✅ Vocabulary: `lib/vocab.g.ttl` with `app:Note`, `app:content`, `app:categoryId`, `app:archived`
- ✅ Merge Contract: `lib/contracts/note-v1.g.ttl` with CRDT merge rules for each property
- ✅ No manual vocabulary class needed
- ✅ No manual CRDT mapping TTL file needed

---

## Implementation Checklist

### ✅ Completed (in RDF mapper library)
- [x] `AppVocab` configuration class
- [x] `.define()` constructor for `RdfGlobalResource`/`RdfLocalResource`
- [x] `RdfProperty.define()` for forcing custom property generation
- [x] Well-known property auto-matching
- [x] Vocabulary TTL file generation
- [x] Lock file protection (`.locorda_rdf_mapper.lock`)

### ⏳ To Do (sync-engine integration)
- [ ] Implement `RootResource(AppVocab)` default constructor
- [ ] Implement `RootResource.externalVocab(IriTerm, String)` constructor
- [ ] Implement `RootResource.externalContract(AppVocab, String)` constructor
- [ ] Implement `RootResource.external(IriTerm, String)` constructor
- [ ] Add `MergeContracts` constants class (replacing `MergeContracts`)
- [ ] Update `MergeContractBuilder` to resolve merge contract IRIs
- [ ] Update `MergeContractBuilder` to resolve vocabulary IRIs (use RDF mapper logic)
- [ ] Generate merge contract TTL files in `/contracts/` (not `/mappings/`)
- [ ] Migrate personal notes app to new API
- [ ] Update getting-started documentation
- [ ] Add integration tests for all 4 constructor variants
- [ ] Execute complete annotation API cleanup per [022-annotation-api-cleanup.md](022-annotation-api-cleanup.md)

---

## Recommendations

1. **Default Constructor for Common Case**  
   The `RootResource(AppVocab)` default constructor handles 90% of use cases (both generated).

2. **`.externalVocab()` for Schema.org Integration**  
   Second most common: use standard vocabularies but custom CRDT merge rules.

3. **Configure `wellKnownProperties` in AppVocab**  
   Map common field names (`title`, `description`, `created`) to standard vocabularies.

4. **Merge Contract Versioning**  
   Use `mergeContractVersion: 'v2'` when making breaking CRDT changes.

5. **Lock File Must Be Committed**  
   `.locorda_rdf_mapper.lock` prevents accidental breaking changes to RDF schema.

6. **Migration Path for Existing Apps**  
   - Keep manual `@RdfProperty(IriTerm(...))` initially (backwards compatible)
   - Migrate to new API incrementally
   - Plan data migration for contract URI changes

---

## Appendix: RDF Mapper Quick Reference

The RDF mapper library provides automatic vocabulary generation. Key features:

- **`AppVocab`** — Configure app vocabulary base URI and well-known properties
- **`.define()` constructor** — Auto-generate vocabulary from class/field names
- **Well-known properties** — Auto-match common fields to standard vocabularies (dc:title, etc.)
- **TTL generation** — Build process creates `lib/vocab.g.ttl`
- **Lock file** — `.locorda_rdf_mapper.lock` prevents breaking RDF schema changes

**Resources:**
- [RDF Mapper Annotations README](https://github.com/locorda/rdf/blob/main/packages/locorda_rdf_mapper_annotations/README.md)
- [Vocabulary Generation Guide](https://github.com/locorda/rdf/blob/main/packages/locorda_rdf_mapper_annotations/doc/vocab_generating.md)

**Minimal Example:**
```dart
const appVocab = AppVocab(appBaseUri: 'https://myapp.example.com');

@RdfGlobalResource.define(appVocab, IriStrategy('https://myapp.example.com/books/{id}'))
class Book {
  @RdfIriPart('id')
  final String id;
  
  final String title;  // → dc:title (auto-matched)
  final String isbn;   // → app:isbn (auto-generated)
}
```

Generated TTL includes `app:Book` class and `app:isbn` property definitions.
