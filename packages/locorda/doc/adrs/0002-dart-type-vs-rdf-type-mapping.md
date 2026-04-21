# ADR-0002: Dart Type vs RDF Type Mapping Strategy

## Status
ACCEPTED

*Implemented in commit 0683c20 with comprehensive validation system.*

## Context

The locorda library organizes configuration around Dart types (Note, Category, etc.) but the underlying Solid ecosystem operates on RDF type IRIs (schema:NoteDigitalDocument, schema:CreativeWork, etc.). This creates a potential impedance mismatch with several architectural implications.

### The Problem

Our current resource-focused configuration associates storage paths, indices, and CRDT mappings with Dart types:

```dart
ResourceConfig(
  type: Note,                    // Dart type
  defaultResourcePath: '/data/notes',
  crdtMapping: Uri.parse('...'),
  indices: [...],
),
ResourceConfig(
  type: Category,                // Different Dart type
  defaultResourcePath: '/data/categories', 
  crdtMapping: Uri.parse('...'),
  indices: [...],
)
```

However, these Dart types are annotated with RDF type IRIs:

```dart
@PodResource(SchemaNoteDigitalDocument.classIri)  // schema:NoteDigitalDocument
class Note { ... }

@PodResource(SchemaCreativeWork.classIri)         // schema:CreativeWork  
class Category { ... }
```

**The conflict arises when multiple Dart types map to the same RDF type IRI.**

### Solid Type Registry Semantics

Solid's type registry associates storage locations with RDF types, not Dart types:
- `schema:CreativeWork` → `/data/creative-works/`
- `schema:NoteDigitalDocument` → `/data/notes/`

If we had two Dart types both using `schema:CreativeWork`:

```dart
@PodResource(SchemaCreativeWork.classIri)
class Category { ... }

@PodResource(SchemaCreativeWork.classIri) 
class BlogPost { ... }
```

Both would compete for the same type registry entry, leading to:
1. **Storage conflicts**: Both want different default paths (`/data/categories` vs `/data/posts`)
2. **Index conflicts**: Both want different index configurations but RDF sees them as the same type
3. **CRDT mapping conflicts**: Same RDF type IRI but potentially different merge strategies

### Index Configuration Implications

Indices operate on RDF type IRIs, not Dart types. A GroupIndex configured for "Category" would actually index ALL instances of `schema:CreativeWork`, including any BlogPost instances, which violates the Dart-level separation we're trying to maintain.

## Decision

**Require unique RDF type IRIs per Dart resource type.**

We will enforce a 1:1 mapping between Dart types and RDF type IRIs in the locorda system.

## Rationale

### Why This Approach

1. **Clear Semantics**: Eliminates ambiguity about which configuration applies to which resources
2. **Predictable Behavior**: Each Dart type gets its own storage path, indices, and CRDT mappings
3. **Type Safety**: Prevents accidental mixing of conceptually different resources
4. **Solid Compatibility**: Aligns with Solid's RDF-centric type registry semantics
5. **CRDT Clarity**: Each resource type has clearly defined merge strategies

### Handling Standard Vocabularies

Rather than discouraging standard vocabularies, we encourage:

1. **Specific standard types** when they fit exactly:
   ```dart
   @PodResource(SchemaNoteDigitalDocument.classIri)  // Perfect fit
   class Note { ... }
   ```

2. **Custom types that extend or specialize standard ones** when standard types are too broad:
   ```dart
   // Instead of using generic schema:CreativeWork
   @PodResource(IriTerm('https://myapp.example/vocab#NotesCategory'))
   class NotesCategory { ... }
   
   // Could still rdfs:subClassOf schema:CreativeWork in the vocabulary
   ```

3. **Application-specific vocabularies** for domain-specific concepts:
   ```dart
   @PodResource(IriTerm('https://personal-notes.example/vocab#QuickNote'))
   class QuickNote { ... }
   ```

## Implementation

### Validation at Setup Time

Comprehensive validation is implemented using a validation context pattern in the `locorda_core` package:

- **ValidationResult**: Collects errors and warnings with structured context
- **SyncConfig.validate()**: Validates all aspects of the configuration
- **SyncConfigValidationException**: Thrown when validation fails with comprehensive error details

Key validation rules implemented:

1. **Resource Uniqueness**: No duplicate Dart types in configuration
2. **Path Validation**: Default paths must be absolute and well-formed
3. **CRDT Mapping URIs**: Must be absolute URIs (preferably HTTPS)
4. **Index Configuration**: Local names must be unique per index item type across all resources, GroupIndex must have grouping properties
5. **RDF Type Collision Detection**: Validates that each Dart type maps to a unique RDF type IRI using the RDF mapper

The validation is automatically called in `Locorda.setup()` and will throw a detailed exception if any issues are found, allowing developers to fix all configuration problems in a single iteration.

See `packages/locorda_core/lib/src/config/validation.dart` for implementation details.

### Documentation Guidelines

Update documentation to encourage:
1. Using specific standard types when available and appropriate
2. Creating custom types that specialize standard ones when needed
3. Linking custom types to standard vocabularies via `rdfs:subClassOf` when semantically appropriate

### Example Migrations

```dart
// BEFORE: Potential conflict
@PodResource(SchemaCreativeWork.classIri)  // Too generic
class Category { ... }

@PodResource(SchemaCreativeWork.classIri)  // Conflict!
class BlogPost { ... }

// AFTER: Unique types
@PodResource(IriTerm('https://personal-notes.example/vocab#NotesCategory'))
class NotesCategory { ... }

@PodResource(SchemaBlogPosting.classIri)  // More specific standard type
class BlogPost { ... }
```

## Consequences

### Positive
- **Clear architecture**: Each Dart type has unambiguous RDF identity
- **Predictable storage**: No conflicts in type registry entries
- **Clean indices**: Each index configuration applies to exactly one conceptual resource type
- **Better debugging**: Resource issues can be traced to specific Dart types

### Negative
- **More vocabulary work**: May need to define custom types instead of reusing generic ones
- **Vocabulary proliferation**: Could lead to many small, application-specific types
- **Learning curve**: Developers need to understand RDF type design implications

### Mitigations
- Provide vocabulary guidance and examples
- Create reusable vocabulary modules for common patterns
- Document best practices for extending standard vocabularies
- Consider tooling to help generate appropriate custom types

## Related Decisions
- Links to future ADRs about vocabulary design patterns
- Links to RDF mapping strategy decisions (ADR-0001)