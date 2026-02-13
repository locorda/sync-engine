# Concept: Simplified Annotations & Automatic Vocabulary Generation

**Date:** 2026-02-13  
**Status:** Draft Concept  
**Author:** Klas Kalaß & AI Analysis (copilot/claude)  
**Related:** [020-crdt-mapping-generation.md](020-crdt-mapping-generation.md), [019_locorda_config_generation.md](019_locorda_config_generation.md)

## Status

---
> **Most of the document not yet reviewed.** In general I came to the conclusion that we do have to integrate the idea
of custom RDF schemas into the rdf mapper library - this is nothing to be done in the sync engine libraries.
> 
> And we have to find a way to work with classes where only the class is annotated (as @RdfLocalResource, @RdfGlobalResource or any of the specific subclasses like @LcrdRootResource, @LcrdSubresource etc.). 
>
> So we will need a constructor for those annotations where the base iri is given (the user has to come up with something... no way around) but then we append `#<class_name>` etc. for the actual type IRI and use the property names (maybe transformed by convention to lower snake case or  whatever). And we need an empty RdfProperty constructor which is the default if no annotation is given (if in custom mode), but we have to handle RdfIriPart without RdfProperty - this should usually not be considered a RdfProperty. Plus we need to be able to provide the superclass for custom mode, defaulting to e.g. rdf:Resource or such
---

## Problem Statement

Locorda requires RDF vocabulary IRIs for every class and every custom property. For developers who use only standard vocabularies (schema.org etc.), this works well. But for developers who don't care about RDF semantics and just want CRDT sync, the current annotation burden is significant:

### Current Pain Points

**1. Manual Vocabulary Class**  
Developers must hand-write a `PersonalNotesVocab` class with `IriTerm` constants for every custom class and property:

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

**2. Boilerplate RDF Knowledge Required**  
Developers must understand:
- What an IRI is and what `IriTerm` means
- Why class IRIs and predicate IRIs are different
- How `appBaseUrl` + fragment pattern works
- When to use schema.org vs custom predicates

**3. The Turtle File is Hand-Written**  
The `personal-notes.ttl` OWL ontology is authored manually and must be kept in sync with the Dart vocabulary class — a violation of DRY.

**4. Verbose Annotations Even for Simple Models**  
Compare the minimal `Task` model that embeds raw `IriTerm()` strings inline:

```dart
@LcrdRootResource(
  IriTerm('$appBaseUrl/vocabulary/task#Task'),
  LcrdCrdt('$appBaseUrl/mappings/task-v1#'),
)
class Task {
  @RdfProperty(IriTerm('$appBaseUrl/vocabulary/task#completed'))
  final bool completed;
}
```

Neither approach is good: the vocab class approach is DRY but requires upfront work; the inline approach is quick but noisy with raw IRI strings.

### Goal

Make it **dead simple** for developers who don't care about RDF to annotate their models and still get correct RDF vocabulary files generated automatically. More advanced users who *do* care about RDF should still have full control.

---

## Proposed Solution: Convention-Based Defaults + Vocabulary Generation

The solution has two parts:

1. **Convention-Based Annotation Defaults** — eliminate the need for explicit `IriTerm` predicates for custom properties by deriving them from Dart field names and class names
2. **Vocabulary TTL Generator** — a new build step that generates a proper OWL vocabulary `.ttl` file from annotations, eliminating the hand-written vocabulary and Dart vocab class

### Design Principles

- **Zero-RDF-Knowledge**: A developer who knows nothing about RDF should be able to use Locorda with only CRDT annotations
- **Convention over Configuration**: Sensible defaults derived from Dart naming conventions
- **Progressive Disclosure**: Simple cases are simple; full RDF control is available when needed
- **No Magic**: Conventions are predictable; developers can inspect generated files
- **Backwards Compatible**: Existing explicit `@RdfProperty(IriTerm(...))` continues to work unchanged

---

## Part 1: Convention-Based Annotation Defaults

### Concept A: Implicit Predicate IRIs from Field Names (Recommended)

Within a `@LcrdRootResource` class, all public fields without an explicit `@RdfProperty` get their predicate IRI derived automatically from the Dart field name. The CRDT strategy defaults to LWW-Register (no annotation needed); non-default strategies (`@CrdtOrSet()`, `@CrdtImmutable()`) still require explicit annotations.

#### Convention Rules

| Dart Name | Generated IRI Fragment |
|-----------|----------------------|
| Field `categoryColor` | `{vocabBaseIri}categoryColor` |
| Field `isArchived` | `{vocabBaseIri}isArchived` |
| Class `PersonalNote` | `{vocabBaseIri}PersonalNote` |

The `vocabBaseIri` is derived from the `LcrdCrdt` mapping IRI's base or configured explicitly in a new `LcrdVocab` annotation (see below).

#### How It Works — Current vs Proposed

**Current (explicit):**
```dart
@LcrdRootResource(
  PersonalNotesVocab.PersonalNote,
  LcrdCrdt('$appBaseUrl/mappings/note-v1#'),
)
class Note {
  @RdfIriPart()
  final String id;

  @RdfProperty(SchemaNoteDigitalDocument.name)
  final String title;

  @RdfProperty(SchemaNoteDigitalDocument.text)
  final String content;

  @RdfProperty(SchemaNoteDigitalDocument.keywords)
  @CrdtOrSet()
  final Set<String> tags;

  @RdfProperty(PersonalNotesVocab.belongsToCategory)
  final String? categoryId;

  @RdfProperty(SchemaNoteDigitalDocument.dateCreated)
  @CrdtImmutable()
  final DateTime createdAt;
}
```

**Proposed (convention-based, zero RDF knowledge):**
```dart
@LcrdRootResource(
  LcrdCrdt('$appBaseUrl/mappings/note-v1#'),
)
class Note {
  @RdfIriPart()
  final String id;

  final String title;

  final String content;

  @CrdtOrSet()
  final Set<String> tags;

  final String? categoryId;

  @CrdtImmutable()
  final DateTime createdAt;
}
```

Nine annotations removed! The class IRI becomes `{vocabBaseIri}Note`, each property IRI becomes `{vocabBaseIri}{fieldName}`.

**Proposed (hybrid — use schema.org where it fits, auto-generate the rest):**
```dart
@LcrdRootResource(
  LcrdCrdt('$appBaseUrl/mappings/note-v1#'),
  classIri: SchemaNoteDigitalDocument.classIri, // optional: explicit class IRI
)
class Note {
  @RdfIriPart()
  final String id;

  @RdfProperty(SchemaNoteDigitalDocument.name) // explicit: use schema.org
  final String title;

  final String content;    // implicit: generates {vocab}#content

  @CrdtOrSet()             // implicit: generates {vocab}#tags
  final Set<String> tags;

  final String? categoryId; // implicit: generates {vocab}#categoryId

  @RdfProperty(SchemaNoteDigitalDocument.dateCreated) // explicit: use schema.org
  @CrdtImmutable()
  final DateTime createdAt;
}
```

### Concept B: Alternative — `@LcrdProperty` Shorthand

Instead of allowing bare CRDT annotations, introduce a combined annotation that wraps `@RdfProperty` + CRDT:

```dart
@LcrdRootResource(
  LcrdCrdt('$appBaseUrl/mappings/note-v1#'),
)
class Note {
  @RdfIriPart()
  final String id;

  @LcrdLww()   // = @RdfProperty(auto) + @CrdtLwwRegister()
  final String title;

  @LcrdLww()
  final String content;

  @LcrdSet()   // = @RdfProperty(auto) + @CrdtOrSet()
  final Set<String> tags;

  @LcrdLww(predicate: SchemaNoteDigitalDocument.dateCreated) // explicit predicate
  @LcrdImmutable()                                           // override CRDT strategy
  final DateTime createdAt;
}
```

**Assessment of Concept B:**  
- Pro: All-in-one annotation, fewer lines
- Con: Introduces a parallel annotation hierarchy (`@LcrdLww` vs `@CrdtLwwRegister`), makes it harder to mix with schema.org properties, breaks the clean separation between RDF mapping and CRDT strategy
- **Verdict: Not recommended.** The separation of `@RdfProperty` and `@CrdtXxx` is a good design. Making `@RdfProperty` optional is cleaner than replacing it.

### Recommended: Concept A

Concept A is preferred because:
1. It preserves the clean RDF/CRDT annotation separation
2. Existing code with explicit `@RdfProperty` works unchanged
3. Progressive: add `@RdfProperty` only where you want standard vocab
4. The convention (field name → predicate) is trivially predictable

---

## Part 2: Vocabulary Base IRI Configuration

The generator needs to know *where* generated predicates live. Two approaches:

### Option 1: Derive from `LcrdCrdt` mappingIri (Zero-Config)

Convention: The mapping IRI `https://example.com/mappings/note-v1#` implies a vocabulary namespace of `https://example.com/vocabulary/{package}#`.

- Heuristic: Replace `/mappings/...` with `/vocabulary/{packageName}#`  
- Fallback: `{scheme}://{host}/vocabulary/{packageName}#`

**Pro:** Zero additional config.  
**Con:** Fragile heuristic, couples vocabulary namespace to mapping namespace.

### Option 2: Explicit `LcrdVocab` Annotation (Recommended)

A single top-level constant or annotation per package defines the vocabulary namespace:

```dart
// In consts.dart or a dedicated vocab_config.dart
const appBaseUrl = 'https://locorda.dev/example/personal_notes_app';

// Option 2a: Annotation on a library directive
@LcrdVocab('$appBaseUrl/vocabulary/personal-notes#')
library;

// Option 2b: Top-level const (detected by the generator)
@LcrdVocab('$appBaseUrl/vocabulary/personal-notes#',
  label: 'Personal Notes Vocabulary',
  comment: 'Vocabulary for personal note-taking applications.',
)
const lcrdVocab = null; // marker

// Option 2c: Configured in build.yaml
// targets:
//   $default:
//     builders:
//       locorda_init_generator|vocab_generator:
//         options:
//           vocab_base_iri: 'https://locorda.dev/example/personal_notes_app/vocabulary/personal-notes#'
```

**Recommended: Option 2a/2b** — an annotation in Dart code, scannable by the builder, keeps everything in the source.

### Proposed `LcrdVocab` Annotation

```dart
/// Declares the base IRI namespace for auto-generated vocabulary terms.
///
/// Place this on a library directive in any file that's part of your package.
/// Only one [LcrdVocab] annotation should exist per package.
class LcrdVocab {
  /// The base IRI for auto-generated class and property IRIs.
  /// Should end with '#' (fragment) or '/' (slash namespace).
  /// 
  /// Example: `'https://myapp.example.com/vocabulary/myapp#'`
  final String baseIri;

  /// Human-readable label for the vocabulary (used in generated TTL).
  final String? label;

  /// Description of the vocabulary (used in generated TTL).
  final String? comment;

  /// Vocabulary version string (used in generated TTL).
  final String? version;

  const LcrdVocab(this.baseIri, {this.label, this.comment, this.version});
}
```

### Fallback When No `LcrdVocab` Exists

If no `@LcrdVocab` is found, the generator derives a vocabulary base IRI from `LcrdCrdt.mappingIri`:

```
  mappingIri: 'https://example.com/mappings/note-v1#'
  → vocabBaseIri: 'https://example.com/vocabulary/auto#'
```

This allows the minimal example to work with zero additional config, while more serious apps should declare `@LcrdVocab` for a clean namespace.

---

## Part 3: Simplifying `LcrdRootResource`

### Current Signature

```dart
@LcrdRootResource(
  PersonalNotesVocab.PersonalNote,           // 1st positional: classIri (IriTerm)
  LcrdCrdt('$appBaseUrl/mappings/note-v1#'), // 2nd positional: crdt config
)
```

The `classIri` is always the first positional parameter, inherited from `RdfGlobalResource`. For developers who don't care about RDF, this is just noise.

### Proposed: Make `classIri` Optional with Convention Default

```dart
// Current (stays valid):
@LcrdRootResource(
  PersonalNotesVocab.PersonalNote,
  LcrdCrdt('$appBaseUrl/mappings/note-v1#'),
)
class Note { ... }

// New (zero-RDF, class IRI derived from Dart class name):
@LcrdRootResource(
  LcrdCrdt('$appBaseUrl/mappings/note-v1#'),
)
class Note { ... }
// → classIri = '{vocabBaseIri}Note'
```

This requires a new constructor on `LcrdRootResource`:

```dart
class LcrdRootResource extends RdfGlobalResource {
  final LcrdCrdt crdt;
  final LcrdFullIndex fullIndex;

  // Existing: explicit classIri
  const LcrdRootResource(
    IriTerm classIri,
    this.crdt, {
    this.fullIndex = const LcrdFullIndex(),
    super.iri,
  }) : super(classIri, iri ?? const RootIriStrategy());

  // New: auto-derived classIri
  const LcrdRootResource.auto(
    this.crdt, {
    this.fullIndex = const LcrdFullIndex(),
    super.iri,
  }) : super(null, iri ?? const RootIriStrategy());
}
```

**Alternative: Single Constructor with Optional classIri**

Since Dart's type system allows distinguishing `IriTerm` from `LcrdCrdt`, we *could* use a single constructor:

```dart
// This won't work in Dart: two positional params of different types, first optional, is not ergonomic.
```

Better approach: **named constructor** `.auto()` or simply make `classIri` a named parameter:

```dart
class LcrdRootResource extends RdfGlobalResource {
  final LcrdCrdt crdt;
  final LcrdFullIndex fullIndex;

  // Expert: explicit classIri (positional, backwards compatible)
  const LcrdRootResource(
    IriTerm classIri,
    this.crdt, {
    this.fullIndex = const LcrdFullIndex(),
    super.iri,
  }) : super(classIri, iri ?? const RootIriStrategy());

  // Simple: classIri derived from Dart class name + vocabBaseIri
  const LcrdRootResource.withCrdt(
    this.crdt, {
    IriTerm? classIri,
    this.fullIndex = const LcrdFullIndex(),
    super.iri,
  }) : super(classIri, iri ?? const RootIriStrategy());
}
```

### Simplifying `LcrdCrdt` Too

The `LcrdCrdt` mapping IRI could also use a convention default:

```dart
// Current:
LcrdCrdt('$appBaseUrl/mappings/note-v1#',
  label: 'Personal Note CRDT Document Mapping v1',
  comment: 'Defines how personal notes should merge...',
)

// Simplified (derive from vocabBaseIri + class name):
LcrdCrdt()  // → mappingIri = '{baseUrl}/mappings/{className}-v1#'
```

But this goes too far for now — the mapping IRI is a versioned deployment artifact and should remain explicit. The `label` and `comment` are already optional.

**Minor simplification:** Default `mappingIri` from the `@LcrdVocab` base:

```dart
// If @LcrdVocab('https://myapp.example.com/vocabulary/myapp#') exists:
LcrdCrdt()  // → mappingIri derived as 'https://myapp.example.com/mappings/{ClassName}-v1#'
```

**Assessment:** Risky. Mapping IRIs are versioned identifiers. Auto-deriving them means changes to the class name silently change the mapping IRI, potentially breaking deployed sync. **Keep `mappingIri` explicit for now**, but allow omitting `label` and `comment` (already the case).

---

## Part 4: The Vocabulary TTL Generator

### What It Generates

A build step produces a `.ttl` file (OWL/RDFS vocabulary) from all `@LcrdRootResource`, `@LcrdSubResource`, `@RdfLocalResource`-annotated classes in the package. This replaces the hand-written `personal-notes.ttl`.

### Generator Pipeline

```
Source Files (.dart)
  ↓ scan @LcrdVocab, @LcrdRootResource, @RdfProperty, etc.
  ↓ collect: classes needing class IRIs, fields needing predicate IRIs
  ↓ filter: only include IRIs that belong to the package's vocab namespace
  ↓ generate
  ↓
Two outputs:
  1. {package}_vocab.g.dart    — Dart const class with IriTerm constants
  2. vocabulary/{name}.g.ttl   — OWL/RDFS vocabulary file
```

### What Goes Into the Generated Vocabulary

For each **class** with an auto-derived class IRI:
```turtle
:Note
    a owl:Class ;
    rdfs:label "Note" ;
    rdfs:comment "Auto-generated from Dart class Note." ;
    rdfs:isDefinedBy <https://myapp.example.com/vocabulary/myapp> .
```

For each **field** with an auto-derived predicate IRI:
```turtle
:content
    a owl:DatatypeProperty ;   # or owl:ObjectProperty for references
    rdfs:label "content" ;
    rdfs:comment "Auto-generated from field Note.content." ;
    rdfs:domain :Note ;
    rdfs:range xsd:string ;     # derived from Dart type
    rdfs:isDefinedBy <https://myapp.example.com/vocabulary/myapp> .
```

Properties that use explicit standard-vocabulary predicates (e.g., `@RdfProperty(Schema.name)`) are **not** included in the generated vocabulary — they already exist in their respective vocabularies.

### What Goes Into the Generated Dart Vocab Class

```dart
// AUTO GENERATED - DO NOT EDIT
// Generated by locorda vocab_generator
class PersonalNotesVocab {
  static const baseIri = 'https://locorda.dev/example/personal_notes_app/vocabulary/personal-notes#';
  
  // Classes
  static const Note = IriTerm('${baseIri}Note');
  static const Category = IriTerm('${baseIri}Category');
  static const Weblink = IriTerm('${baseIri}Weblink');
  
  // Properties
  static const content = IriTerm('${baseIri}content');
  static const categoryId = IriTerm('${baseIri}categoryId');
  static const archived = IriTerm('${baseIri}archived');
  // ... only auto-derived predicates, not schema.org ones
}
```

This generated file replaces the hand-written one. The RDF mapper generator then uses these constants internally.

### Enrichment via Annotations (Progressive)

For developers who care about vocabulary quality, optional enrichment:

```dart
@LcrdRootResource.withCrdt(
  LcrdCrdt('$appBaseUrl/mappings/note-v1#'),
  classIri: SchemaNoteDigitalDocument.classIri,
)
@LcrdVocabClass(
  label: 'Personal Note',
  comment: 'A personal note or memo for note-taking applications.',
  subClassOf: SchemaNoteDigitalDocument.classIri,
)
class Note {
  @RdfProperty(SchemaNoteDigitalDocument.name,
    vocabLabel: 'note title',  // enriches generated TTL  
  )
  final String title;
  
  @LcrdVocabProperty(  // auto-derived predicate, enriched with vocab metadata:
    label: 'belongs to category',
    comment: 'Links a note to its organizing category.',
  )
  final String? categoryId;
}
```

The `@LcrdVocabClass` and `@LcrdVocabProperty` annotations are **purely optional** — they only add richer metadata to the generated TTL. The generator works fine without them.

---

## Part 5: Integration with Existing Generators

### Interaction with CrdtMappingBuilder

The `CrdtMappingBuilder` already extracts predicate IRIs via `_extractPropertyPredicate()`. With the proposed changes:

1. If `@RdfProperty` is present → use its predicate (existing behavior)
2. If `@RdfProperty` is absent → derive predicate from field name + `vocabBaseIri` (all public fields in a `@LcrdRootResource` class are mapped by default)
3. The `vocabBaseIri` is resolved from `@LcrdVocab` (or fallback)

This requires adding the vocab-base-IRI resolution to `CrdtMappingBuilder`'s scanning phase. Since it already does a BFS traversal of all fields via `_discoverReachableTypes()`, the extension is straightforward.

### Interaction with ConfigBuilder / AnnotationScanner

The `ConfigBuilder` scans `@LcrdRootResource` for `classIri`. When `classIri` is null (auto-derived), the config generator needs to resolve it the same way the vocab generator does. This is deterministic given the `vocabBaseIri` + Dart class name.

### Interaction with RDF Mapper Generator (External Package)

The RDF mapper generator (`locorda_rdf_mapper`) generates serialization/deserialization code. It currently requires an explicit `@RdfProperty` on every serialized field. Two approaches:

**Approach A: Generate `@RdfProperty` Annotations**  
The vocab generator could produce a `.g.dart` file that augments classes with synthetic `@RdfProperty` annotations. However, Dart's build system doesn't support augmenting annotations on existing classes.

**Approach B: Teach the RDF Mapper to Use CRDT Annotations as Fallback (Recommended)**  
The RDF mapper already supports `_matchesAnnotationInHierarchy()` for custom `RdfProperty` subclasses. We can:

1. Make CRDT annotations (`CrdtLwwRegister` etc.) extend or implement a marker interface
2. The RDF mapper, when it finds a field without `@RdfProperty` but with a CRDT annotation, uses the convention-derived predicate
3. This keeps the "single source of truth" in the CRDT annotation

**Implementation sketch for the RDF mapper:**
```dart
// In RDF mapper's field scanner:
IriTerm? resolveFieldPredicate(FieldElement field) {
  // 1. Explicit @RdfProperty → use it
  final explicit = findRdfPropertyAnnotation(field);
  if (explicit != null) return explicit.predicate;
  
  // 2. Field in @LcrdRootResource class? → derive from field name (LWW default)
  if (isInLcrdResourceClass(field.enclosingElement)) {
    final vocabBase = resolveVocabBaseIri(field.enclosingElement);
    return IriTerm('$vocabBase${field.name}');
  }
  
  // 3. Not in LcrdRootResource class → field is not mapped (existing behavior)
  return null;
}
```

**Approach C: Generated Intermediate Dart Code**
The vocab generator produces a `.vocab.g.dart` file that the CRDT and RDF mapper generators depend on. This file provides a `Map<String, IriTerm>` that both generators consult. This avoids duplicating the convention logic.

**Recommended: Approach B** — it's the simplest, avoids cross-generator dependencies, and the convention logic is trivial enough to duplicate (it's just `vocabBaseIri + fieldName`).

---

## Part 6: Full Before/After Comparison

### Before (Current State)

```dart
// consts.dart
const appBaseUrl = 'https://locorda.dev/example/personal_notes_app';

// vocabulary/personal_notes_vocab.dart  (hand-written, 15 lines)
class PersonalNotesVocab {
  static const baseIri = '$appBaseUrl/vocabulary/personal-notes#';
  static const NotesCategory = IriTerm('${baseIri}NotesCategory');
  static const PersonalNote = IriTerm('${baseIri}PersonalNote');
  static const Weblink = IriTerm('${baseIri}Weblink');
  static const belongsToCategory = IriTerm('${baseIri}belongsToCategory');
  static const categoryColor = IriTerm('${baseIri}categoryColor');
  static const categoryIcon = IriTerm('${baseIri}categoryIcon');
  static const archived = IriTerm('${baseIri}archived');
  static const displaySettings = IriTerm('${baseIri}displaySettings');
}

// assets/contracts/vocabulary/personal-notes.ttl  (hand-written, 55 lines)
// ... full OWL ontology ...

// models/category.dart
@LcrdRootResource(
  PersonalNotesVocab.NotesCategory,
  LcrdCrdt('$appBaseUrl/mappings/category-v1#', ...),
)
class Category {
  @RdfIriPart()
  final String id;

  @RdfProperty(SchemaCreativeWork.name)
  final String name;

  @RdfProperty(SchemaCreativeWork.description)
  final String? description;

  @RdfProperty(PersonalNotesVocab.displaySettings)
  final CategoryDisplaySettings? settings;

  @RdfProperty(SchemaCreativeWork.dateCreated)
  @CrdtImmutable()
  final DateTime createdAt;

  @RdfProperty(SchemaCreativeWork.dateModified)
  final DateTime modifiedAt;

  @RdfProperty(PersonalNotesVocab.archived)
  final bool archived;

  @RdfUnmappedTriples(globalUnmapped: true)
  final RdfGraph other;
}
```

### After (Proposed, Zero-RDF Developer)

```dart
// consts.dart
const appBaseUrl = 'https://locorda.dev/example/personal_notes_app';

// vocab_config.dart
@LcrdVocab('$appBaseUrl/vocabulary/personal-notes#',
  label: 'Personal Notes Vocabulary',
)
library;
import 'package:locorda_annotations/locorda_annotations.dart';
import 'consts.dart';

// vocabulary/personal_notes_vocab.g.dart  → GENERATED (replaces hand-written)
// assets/contracts/vocabulary/personal-notes.g.ttl → GENERATED (replaces hand-written)

// models/category.dart
@LcrdRootResource.withCrdt(
  LcrdCrdt('$appBaseUrl/mappings/category-v1#'),
)
class Category {
  @RdfIriPart()
  final String id;

  final String name;

  final String? description;

  final CategoryDisplaySettings? settings;

  @CrdtImmutable()
  final DateTime createdAt;

  final DateTime modifiedAt;

  final bool archived;

  @RdfUnmappedTriples(globalUnmapped: true)
  final RdfGraph other;
}
```

**Eliminated:**
- ❌ Hand-written `PersonalNotesVocab` class (generated)
- ❌ Hand-written `personal-notes.ttl` (generated)
- ❌ 7× `@RdfProperty(...)` annotations on Category alone
- ❌ 5× `@CrdtLwwRegister()` annotations (LWW is already the default)
- ❌ `IriTerm` import
- ❌ Understanding of RDF predicates

**Kept:**
- ✅ `@RdfIriPart()` — still needed for IRI construction
- ✅ `@CrdtOrSet()` / `@CrdtImmutable()` — only where non-default merge strategy needed
- ✅ `@RdfUnmappedTriples()` — still needed for round-tripping
- ✅ `LcrdCrdt(mappingIri)` — still needed (versioned identifier)

### After (Proposed, RDF-Savvy Developer)

```dart
// Same developer can still use explicit vocab where it adds semantic value:
@LcrdRootResource(
  PersonalNotesVocab.NotesCategory,  // explicit: custom class IRI
  LcrdCrdt('$appBaseUrl/mappings/category-v1#'),
)
class Category {
  @RdfIriPart()
  final String id;

  @RdfProperty(SchemaCreativeWork.name)  // explicit: use schema.org
  final String name;

  @RdfProperty(SchemaCreativeWork.description) // explicit: use schema.org
  final String? description;

  final CategoryDisplaySettings? settings;  // auto-derived: {vocab}#settings

  @RdfProperty(SchemaCreativeWork.dateCreated) // explicit: use schema.org
  @CrdtImmutable()
  final DateTime createdAt;

  final DateTime modifiedAt;  // auto-derived: {vocab}#modifiedAt

  final bool archived;  // auto-derived: {vocab}#archived

  @RdfUnmappedTriples(globalUnmapped: true)
  final RdfGraph other;
}
```

Both styles can be mixed freely within a single class.

---

## Part 7: The Absolute Minimum — Task Model

### Current

```dart
@LcrdRootResource(
  IriTerm('$appBaseUrl/vocabulary/task#Task'),
  LcrdCrdt('$appBaseUrl/mappings/task-v1#'),
)
class Task {
  @RdfIriPart()
  final String id;

  @RdfProperty(SchemaCreativeWork.name)
  final String title;

  @RdfProperty(IriTerm('$appBaseUrl/vocabulary/task#completed'))
  final bool completed;

  @RdfProperty(SchemaCreativeWork.dateCreated)
  @CrdtImmutable()
  final DateTime createdAt;
}
```

### Proposed Minimal

```dart
@LcrdRootResource.withCrdt(
  LcrdCrdt('$appBaseUrl/mappings/task-v1#'),
)
class Task {
  @RdfIriPart()
  final String id;

  final String title;       // LWW is default, predicate auto-derived

  final bool completed;     // LWW is default, predicate auto-derived

  @CrdtImmutable()          // only needed because non-default CRDT
  final DateTime createdAt;
}
```

This works because LWW-Register is already the default CRDT strategy — bare fields need no `@CrdtLwwRegister()`.

### Decision: Include Unannotated Fields?

Since `@LcrdRootResource` (or `.withCrdt`) is already an explicit class-level opt-in, all public fields within such a class are mapped by default:

- **Mapped automatically:** All public fields (LWW-Register + auto-derived predicate)
- **Excluded automatically:** Private fields (`_cachedHash` etc.), `@RdfIriPart()` fields, `@RdfUnmappedTriples` fields
- **Opt-out:** `@RdfIgnore()` for the rare case where a public field shouldn't be synced
- **Override:** `@RdfProperty(...)` for explicit predicates, `@CrdtOrSet()` / `@CrdtImmutable()` for non-default CRDT strategies

This is safe because the class-level `@LcrdRootResource` annotation is the strong, intentional opt-in signal. Within that context, all public fields being mapped is the expected behavior — similar to how `json_serializable` with `@JsonSerializable()` maps all fields by default.

The result: no `IriTerm`, no `@RdfProperty`, no `@CrdtLwwRegister()`, no vocab class, no TTL file.

---

## Part 8: XSD Type Mapping for Generated Vocabulary

The TTL generator needs to infer XSD types from Dart types for `rdfs:range`:

| Dart Type | XSD Type | OWL Property Type |
|-----------|----------|-------------------|
| `String` | `xsd:string` | `DatatypeProperty` |
| `int` | `xsd:integer` | `DatatypeProperty` |
| `double` | `xsd:double` | `DatatypeProperty` |
| `bool` | `xsd:boolean` | `DatatypeProperty` |
| `DateTime` | `xsd:dateTime` | `DatatypeProperty` |
| `Uri` | `xsd:anyURI` | `DatatypeProperty` |
| `@LcrdRootResource` class | Class IRI | `ObjectProperty` |
| `@LcrdSubResource` class | Class IRI | `ObjectProperty` |
| `@RdfLocalResource` class | (blank node) | `ObjectProperty` |
| `Set<T>` / `List<T>` | Unwrap to `T` | (same as inner type) |

For reference fields like `categoryId` (typed `String?` but semantically referencing `Category`), the generator produces `owl:DatatypeProperty` by default. If the developer adds `@LcrdRootResourceRef(Category)`, it becomes `owl:ObjectProperty` with `rdfs:range :Category`.

---

## Part 9: Builder Configuration

### New Builder: `vocab_generator`

```yaml
# In locorda_init_generator/build.yaml
builders:
  vocab_generator:
    import: "package:locorda_init_generator/builders.dart"
    builder_factories: ["vocabBuilder"]
    build_extensions:
      "pubspec.yaml":
        - "lib/{{}}_vocab.g.dart"
        - "assets/contracts/vocabulary/{{}}.g.ttl"
    build_to: source
    auto_apply: dependents
    runs_before:
      - locorda_init_generator|crdt_mapping_generator
      - locorda_rdf_mapper|rdf_mapper_generator
    required_inputs:
      - ".dart"
```

The vocab generator must run **before** both the CRDT mapping generator and the RDF mapper generator, since they consume the resolved IRIs.

### Execution Order

```
1. vocab_generator      → generates _vocab.g.dart + .g.ttl
2. crdt_mapping_generator → generates .crdt.cache.trig (uses resolved IRIs)
3. rdf_mapper_generator   → generates serialization code (uses resolved IRIs)
4. mapping_bootstrap     → aggregates .crdt.cache.trig files
5. config_generator      → generates LocordaConfig
6. init_locorda_generator → generates convenience wrapper
7. worker_generator      → generates worker entry point
```

---

## Part 10: `@LcrdSubResource` and `@RdfLocalResource` Handling

### Sub-Resources (IRI-identified)

```dart
// Current:
@LcrdSubResource(Schema.Comment, SubIriStrategy("comment-{id}"))
class Comment { ... }

// Proposed (auto class IRI):
@LcrdSubResource.withStrategy(SubIriStrategy("comment-{id}"))
class Comment { ... }
// → classIri = '{vocabBaseIri}Comment'
```

### Local Resources (Blank-node-identified)

```dart
// Current:
@RdfLocalResource(PersonalNotesVocab.Weblink)
class Weblink { ... }

// Proposed (auto class IRI):
@RdfLocalResource()  // Already valid! classIri is already optional.
class Weblink { ... }
// → classIri = '{vocabBaseIri}Weblink' (only for vocab generation, blank node identity unchanged)
```

Note: `@RdfLocalResource()` without a class IRI already works for RDF mapping (produces typeless blank nodes). The vocab generator would still create an `owl:Class` entry for it if the class is reachable from a root resource.

---

## Part 11: Migration Path

### Phase 1: Core Infrastructure
1. Add `LcrdVocab` annotation to `locorda_annotations`
2. Implement vocab base IRI resolution in generators  
3. Teach `CrdtMappingBuilder` to derive predicates from field names when `@RdfProperty` is absent
4. Add `LcrdRootResource.withCrdt()` constructor

### Phase 2: Vocabulary Generator
5. Implement `VocabBuilder` that produces `.g.dart` and `.g.ttl`
6. Integrate with builder pipeline (runs_before CRDT + RDF mapper)
7. Update RDF mapper to support convention-derived predicates

### Phase 3: Example Migration
8. Migrate minimal example to zero-RDF style
9. Migrate personal notes app (keeping schema.org where appropriate)
10. Update documentation and getting-started guides

### Phase 4: Optional Enrichment
11. Add `@LcrdVocabClass` / `@LcrdVocabProperty` annotations for TTL enrichment
12. Support `rdfs:subClassOf`, `rdfs:subPropertyOf` in enrichment annotations

---

## Summary of Changes Required

### `locorda_annotations` Package
- New: `LcrdVocab` annotation class
- New: `LcrdRootResource.withCrdt()` constructor (optional classIri)
- New: `LcrdSubResource.withStrategy()` constructor (optional classIri)
- Optional: `LcrdVocabClass`, `LcrdVocabProperty` enrichment annotations

### `locorda_init_generator` Package  
- New: `VocabBuilder` — generates `.g.dart` vocab class + `.g.ttl` vocabulary
- Modified: `CrdtMappingBuilder` — resolve predicates from field names when `@RdfProperty` absent
- Modified: `AnnotationScanner` — handle null `classIri` in `LcrdRootResource`
- Modified: `ConfigCodeGenerator` — resolve auto-derived class IRIs

### `locorda_rdf_mapper_annotations` Package (External, But Ours)
- Modified: `RdfProperty` or mapper field scanner — support convention-derived predicates when CRDT annotation present but `@RdfProperty` absent

### `locorda_rdf_mapper` Package (External, But Ours)
- Modified: Field scanning — fallback to convention-derived predicates

---

## Open Questions

1. **Should `@RdfUnmappedTriples` also be auto-included?** For zero-RDF developers, the concept of unmapped triples is alien. Could this be a default on `@LcrdRootResource`?

2. **Vocabulary naming convention:** should the generated vocab file name come from the `@LcrdVocab` annotation, the package name, or the base IRI?

3. **Multi-module support:** in a monorepo, each package might have its own `@LcrdVocab`. The generator should scope to one package — is `pubspec.yaml` trigger sufficient?

4. **Cross-package references:** if Package A references a class from Package B, whose vocab namespace should the class IRI use? Answer: the package that defines the class.

5. **Versioning:** when the vocabulary changes between app versions, how does this interact with deployed CRDT mappings? The mapping IRI is versioned, but the vocabulary IRI is not. Is this a problem?
