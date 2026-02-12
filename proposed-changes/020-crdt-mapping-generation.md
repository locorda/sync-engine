# Concept: CRDT Mapping Generation from Annotations

**Date:** 2026-02-12  
**Status:** Draft Concept  
**Author:** Klas Kalaß & AI Analysis (copilot/claude)  
**Related:** [017-convenience-bootstrap.md](017-convenience-bootstrap.md), [019_locorda_config_generation.md](019_locorda_config_generation.md)

## Executive Summary

This document defines how CRDT mapping TTL files are automatically generated from `@LcrdRootResource` and related annotations. The generator produces deployable Turtle documents that define property-level merge strategies for conflict-free collaboration.

**Key Features:**
- Declarative configuration via `LcrdCrdt` class in `@LcrdRootResource` annotation
- Automatic generation for new mappings, `.external()` constructor for manual mappings
- Graph-based generation using `RdfGraph` and `turtle.encode()` (not string concatenation)
- Automatic field traversal to discover sub-resources and local resources
- Smart defaults: `CrdtLwwRegister` assumed when no CRDT annotation present
- Generated files ready for both offline bootstrap and online deployment
- Seamless integration with mapping bootstrap, worker generator, and LocordaConfig

## Trigger & Configuration

### LcrdRootResource Enhancement

The `@LcrdRootResource` annotation triggers CRDT mapping generation:

```dart
@LcrdRootResource(
  PersonalNotesVocab.PersonalNote,
  LcrdCrdt(
    'https://myapp.example.com/mappings/note-v1.ttl',
    label: 'Personal Note CRDT Document Mapping v1',
    comment: 'Defines how personal notes should merge when conflicts occur during sync.',
    imports: [LcrdMappings.coreV1],  // Using constant for full IRI
  ),
)
class Note extends RdfResource {
  @RdfProperty(SchemaNoteDigitalDocument.name)
  @CrdtLwwRegister()
  late String title;
  
  @RdfProperty(SchemaNoteDigitalDocument.text)
  @CrdtLwwRegister()
  late String content;
  
  @RdfProperty(Schema.keywords)
  @CrdtOrSet()
  late Set<String> tags;
  
  @RdfProperty(Schema.dateCreated)
  @CrdtImmutable()
  late DateTime createdAt;
}
```

### LcrdCrdt Class

Configuration class for CRDT mapping generation and referencing:

```dart
/// Constants for standard mapping document IRIs
class LcrdMappings {
  /// Core CRDT mechanics mapping (v1)
  static const coreV1 = IriTerm('https://w3id.org/solid-crdt-sync/mappings/core-v1');
  
  /// Index mechanics mapping (v1)
  static const indexV1 = IriTerm('https://w3id.org/solid-crdt-sync/mappings/index-v1');
  
  /// Shard mechanics mapping (v1)
  static const shardV1 = IriTerm('https://w3id.org/solid-crdt-sync/mappings/shard-v1');
  
  /// Client installation mapping (v1)
  static const clientInstallationV1 = IriTerm('https://w3id.org/solid-crdt-sync/mappings/client-installation-v1');
}

/// CRDT mapping configuration for automatic generation
class LcrdCrdt {
  /// The canonical IRI of the mapping document
  final String mappingIri;
  
  /// Human-readable label for the mapping document
  final String? label;
  
  /// Description of what this mapping defines
  final String? comment;
  
  /// List of mapping document IRIs to import
  /// Default: [LcrdMappings.coreV1]
  /// Example: [LcrdMappings.coreV1, LcrdMappings.indexV1]
  final List<IriTerm> imports;
  
  /// Whether this mapping should be generated (true) or is manually provided (false)
  final bool generate;
  
  /// Default constructor for generated mappings
  const LcrdCrdt(
    this.mappingIri, {
    this.label,
    this.comment,
    this.imports = const [LcrdMappings.coreV1],
  }) : generate = true;
  
  /// Named constructor for external/manually provided mappings
  const LcrdCrdt.external(this.mappingIri)
      : label = null,
        comment = null,
        imports = const [],
        generate = false;
}
```

**Usage Examples:**

**Generated mapping:**
```dart
@LcrdRootResource(
  PersonalNotesVocab.PersonalNote,
  LcrdCrdt(
    'https://myapp.example.com/mappings/note-v1.ttl',
    label: 'Personal Note CRDT Document Mapping v1',
    imports: [LcrdMappings.coreV1],  // IriTerm constant
  ),
)
class Note extends RdfResource { /* ... */ }
```

**External/manual mapping:**
```dart
@LcrdRootResource(
  PersonalNotesVocab.CustomResource,
  LcrdCrdt.external('https://myapp.example.com/mappings/custom-v1.ttl'),
)
class CustomResource extends RdfResource { /* ... */ }
```

### Updated LcrdRootResource Signature

```dart
class LcrdRootResource extends RdfGlobalResource {
  final LcrdCrdt crdt;
  final LcrdFullIndex fullIndex;

  const LcrdRootResource(
    super.classIri,
    this.crdt, {
    super.iriStrategy = const RootIriStrategy(),
    this.fullIndex = const LcrdFullIndex(),
  }) : super(iriStrategy);
}
```

## File Generation

### Output Location

- **Directory:** `assets/contracts/mappings/`
- **Filename:** Extracted from the last path segment of `crdt.mappingIri` URL
- **Example:** `'https://myapp.example.com/mappings/note-v1.ttl'` → `assets/contracts/mappings/note-v1.ttl`
- **Generation:** Only occurs when `crdt.generate == true`

### URL-to-Filename Mapping

```dart
String extractFilename(LcrdCrdt crdt) {
  final uri = Uri.parse(crdt.mappingIri);
  return uri.pathSegments.last;  // 'note-v1.ttl'
}
```

### Dual Purpose

The same TTL file serves two purposes:

1. **Bootstrap:** Embedded as Dart const via `locorda_mapping_bootstrap_generator`, available offline in the worker
2. **Deployment:** Published to the mapping's canonical IRI on the web (user's deploy step)

### Build Integration

```yaml
# build.yaml (in locorda_dev)
builders:
  crdt_mapping_generator:
    import: "package:locorda_dev/src/crdt_mapping_generator_builder.dart"
    builder_factories: ["crdtMappingGeneratorBuilder"]
    build_extensions:
      $lib$: []  # Outputs determined dynamically at build time
    auto_apply: all_packages
    build_to: source
    applies_builders: []
```

**Key points:**
- Empty `build_extensions` because output files are determined dynamically by scanning annotations
- `build_to: source` allows writing to `assets/contracts/mappings/` (outside `lib/`)
- Builder scans all `.dart` files for `@LcrdRootResource` annotations
- Only generates files where `crdt.generate == true`

## Graph-Based Generation

**Approach:** Build `List<Triple>` using generated vocabulary classes, convert to `RdfGraph`, encode with `turtle.encode()`.

**Key principles:**
- Use generated vocabulary classes (`McDocumentMapping`, `AlgoVocab`) - never hardcode IRIs
- Build RDF lists manually with `Rdf.first`/`Rdf.rest`/`Rdf.nil` pattern
- `RdfGraph.fromTriples(triples)` → `turtle.encode(graph)` for output
- Never use string concatenation for Turtle generation

## Field Traversal

**Algorithm:** Start with `@LcrdRootResource` class, recursively traverse fields:
- Unwrap container types (`List<T>`, `Set<T>`, `T?`)
- Include types with `@LcrdSubResource` or `@RdfLocalResource`
- Stop at primitives or external classes
- Deduplicate (each type once)

**Example:**
```dart
@LcrdRootResource(...)
class Note {
  @RdfProperty(...) @CrdtOrSet()
  late Set<Weblink> relatedLinks;  // ← Traverse into Weblink
}

@LcrdSubResource(...)
class Weblink {
  @RdfProperty(...) @CrdtImmutable()
  late String url;
}
// Result: Mapping includes both Note and Weblink
```

## Default Behavior

**CRDT Default:** Properties without CRDT annotation → `@CrdtLwwRegister()`

**Identifying Properties:** `@McIdentifying()` generates `McRule.isIdentifying true` triple (must be `@CrdtImmutable()`)

**Optional:** Build warning `[INFO] Note.title has no CRDT annotation, defaulting to LWW_Register`

## Integration with Ecosystem

**Generation Pipeline:**
1. **CRDT mapping generator** → `assets/contracts/mappings/*.ttl`
2. **Bootstrap generator** → `lib/mapping_bootstrap.g.dart`
3. **Worker generator** → imports bootstrap, includes in `WorkerSetup`
4. **Config generator** → reads `crdt.mappingIri` from annotations, creates `ResourceConfig`
5. **initLocorda** → wires all generated artifacts together

**Key Integration Points:**
- Generated TTL files automatically available offline via bootstrap
- External mappings (`.external()`) must be provided manually
- Config builder extracts mapping IRI from `@LcrdRootResource.crdt`
- Worker automatically includes all bootstrapped mappings

## Example Transformation

**Input:** Dart classes with `@LcrdRootResource`, `@RdfProperty`, CRDT annotations

**Output:** Turtle document following `mc:DocumentMapping` pattern with:
- Document metadata (label, comment, imports list)
- Class mappings (one per discovered type)
- Property rules with CRDT algorithms
- RDF list structures for imports/classes/rules

**Sample Output:**
```turtle
<> a mc:DocumentMapping ;
    rdfs:label "Personal Note CRDT Document Mapping v1" ;
    mc:imports ( mappings:core-v1 ) ;
    mc:classMapping ( [
        a mc:ClassMapping ;
        mc:appliesToClass pnotes:PersonalNote ;
        mc:rule
            [ mc:predicate schema:name ; algo:mergeWith algo:LWW_Register ],
            [ mc:predicate schema:keywords ; algo:mergeWith algo:OR_Set ]
    ] [
        a mc:ClassMapping ;
        mc:appliesToClass pnotes:Weblink ;
        mc:rule
            [ mc:predicate schema:url ; mc:isIdentifying true ; algo:mergeWith algo:Immutable ]
    ] ) .
```

## Implementation Guidelines

### Generator Architecture

**Builder:** `LibraryBuilder` scans `@LcrdRootResource` annotations, discovers types via field traversal, builds `RdfGraph` from triples, emits `.ttl` file via `turtle.encode()`.

**Build Config:** Empty `build_extensions: {$lib$: []}` (outputs determined dynamically), `build_to: source`.

### RDF Graph Construction

**Pattern:** List mutation → `RdfGraph.fromTriples()` → `turtle.encode()`

**RDF Lists:** Implementation builds lists using `Rdf.first`/`Rdf.rest`/`Rdf.nil` pattern as needed.

```dart
final triples = <Triple>[];
triples.add(Triple(mappingIri, rdf.type, McDocumentMapping.iri));
// Build document metadata, imports list, class mappings with property rules
// Use McRule.predicate, AlgoVocab.mergeWith, McRule.isIdentifying
final graph = RdfGraph.fromTriples(triples);
return turtle.encode(graph);
```

### Type Discovery & Processing

**Entry Point:** `@LcrdRootResource` → recursive field traversal (field types, Set/List generics)

**Discovery Rules:**
- Must have `@LcrdSubResource` or `@LcrdRootResource`
- Track processed types to avoid cycles
- Process breadth-first (queue)

**Per-Class Processing:**
1. Discover all `@RdfProperty` fields
2. Look up CRDT annotation (default: `@CrdtLwwRegister()`)
3. Check `@McIdentifying()`
4. Generate rule triple using `McRule.predicate`, `AlgoVocab.mergeWith`, optional `McRule.isIdentifying`

### Error Handling

- Missing annotations → emit warning with context
- Invalid IRIs → fail fast with clear message
- Cycle detection → warn and skip

### Output Management

**Generated Files:** Write to `assets/contracts/mappings/`, named from mapping IRI's last path segment

**Collision Prevention:** Use distinct mapping IRIs per root class

### Testing Strategy

**Unit Tests:** Verify single class, default behaviors, type traversal  
**Golden File Tests:** Compare generated TTL against expected output  
**Integration Tests:** Validate Turtle encoding, merge contract loader compatibility

## Open Questions & Key Decisions

**Namespace Prefixes:** Use `IriTerm` everywhere, let `turtle.encode()` optimize prefixes. Define constants in `LcrdMappings`.

**Version Strategy:** Version in URL (`note-v1.ttl`), create new `@LcrdRootResource` for breaking changes.

**Validation:** Builder should validate CRDT semantics (e.g., identifying properties must be Immutable).

**External Types:** Only traverse types with `@LcrdSubResource`, treat others as primitives.

**Build Performance:** Incremental builder, only regenerate changed roots + dependents.

## Summary

Automatic CRDT mapping generation from annotations via graph-based RDF construction. Smart field traversal discovers all relevant types. Sensible defaults (LWW when no annotation). Seamless integration with bootstrap, worker, and config generators. Deployment flexibility (offline bootstrap + online updates). Migration support (opt-in, manual mappings still work via `.external()`).

