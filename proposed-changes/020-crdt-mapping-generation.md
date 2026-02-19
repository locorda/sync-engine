# Concept: CRDT Mapping Generation from Annotations

**Date:** 2026-02-12  
**Status:** Draft Concept  
**Author:** Klas Kalaß & AI Analysis (copilot/claude)  
**Related:** [017-convenience-bootstrap.md](017-convenience-bootstrap.md), [019_locorda_config_generation.md](019_locorda_config_generation.md)

## Executive Summary

This document defines how CRDT mapping TTL files are automatically generated from `@RootResource` and related annotations. The generator produces deployable Turtle documents that define property-level merge strategies for conflict-free collaboration.

**Key Features:**
- Declarative configuration via `MergeContract` class in `@RootResource` annotation
- Automatic generation for new mappings, `.external()` constructor for manual mappings
- Graph-based generation using `RdfGraph` and `turtle.encode()` (not string concatenation)
- Automatic field traversal to discover sub-resources and local resources
- Smart defaults: `CrdtLwwRegister` assumed when no CRDT annotation present
- Generated files ready for both offline bootstrap and online deployment
- Seamless integration with mapping bootstrap, worker generator, and LocordaConfig

## Trigger & Configuration

### RootResource Enhancement

The `@RootResource` annotation triggers CRDT mapping generation:

```dart
@RootResource(
  PersonalNotesVocab.PersonalNote,
  MergeContract(
    'https://myapp.example.com/mappings/note-v1.ttl',
    label: 'Personal Note CRDT Document Mapping v1',
    comment: 'Defines how personal notes should merge when conflicts occur during sync.',
    imports: [MergeContracts.coreV1],  // Using constant for full IRI
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

### MergeContract Class

Configuration class for CRDT mapping generation and referencing:

```dart
/// Constants for standard mapping document IRIs
class MergeContracts {
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
class MergeContract {
  /// The canonical IRI of the mapping document
  final String mappingIri;
  
  /// Human-readable label for the mapping document
  final String? label;
  
  /// Description of what this mapping defines
  final String? comment;
  
  /// List of mapping document IRIs to import
  /// Default: [MergeContracts.coreV1]
  /// Example: [MergeContracts.coreV1, MergeContracts.indexV1]
  final List<IriTerm> imports;
  
  /// Whether this mapping should be generated (true) or is manually provided (false)
  final bool generate;
  
  /// Default constructor for generated mappings
  const MergeContract(
    this.mappingIri, {
    this.label,
    this.comment,
    this.imports = const [MergeContracts.coreV1],
  }) : generate = true;
  
  /// Named constructor for external/manually provided mappings
  const MergeContract.external(this.mappingIri)
      : label = null,
        comment = null,
        imports = const [],
        generate = false;
}
```

**Usage Examples:**

**Generated mapping:**
```dart
@RootResource(
  PersonalNotesVocab.PersonalNote,
  MergeContract(
    'https://myapp.example.com/mappings/note-v1.ttl',
    label: 'Personal Note CRDT Document Mapping v1',
    imports: [MergeContracts.coreV1],  // IriTerm constant
  ),
)
class Note extends RdfResource { /* ... */ }
```

**External/manual mapping:**
```dart
@RootResource(
  PersonalNotesVocab.CustomResource,
  MergeContract.external('https://myapp.example.com/mappings/custom-v1.ttl'),
)
class CustomResource extends RdfResource { /* ... */ }
```

### Updated RootResource Signature

```dart
class RootResource extends RdfGlobalResource {
  final MergeContract crdt;
  final FullIndex fullIndex;

  const RootResource(
    super.classIri,
    this.crdt, {
    super.iriStrategy = const RootIriStrategy(),
    this.fullIndex = const FullIndex(),
  }) : super(iriStrategy);
}
```

## File Generation

### Output Location

- **Directory:** Build cache (`.dart_tool/build/...`)
- **Format:** TriG (`.crdt.cache.trig` extension)
- **Filename:** Derived from source file path with `.crdt.cache.trig` suffix
- **Example:** `lib/models/note.dart` → `.dart_tool/build/.../lib/models/note.crdt.cache.trig`
- **Generation:** Only occurs when at least one `@RootResource` with `crdt.generate == true` exists in the file
- **Future Extension:** `.vocab.cache.trig` reserved for vocabulary generation (Phase 2)

### Multiple Root Resources per File

A single Dart file can contain multiple `@RootResource` classes. Each is converted to a **named graph** within a single TriG dataset:

```dart
// lib/models/shared.dart
@RootResource(
  NotesVocab.Note,
  MergeContract('https://example.com/mappings/note-v1#'),
)
class Note { /* ... */ }

@RootResource(
  NotesVocab.Category,
  MergeContract('https://example.com/mappings/category-v1#'),
)
class Category { /* ... */ }
```

**Output (shared.crdt.cache.trig in cache):**
```trig
<https://example.com/mappings/note-v1#> {
  <https://example.com/mappings/note-v1#> a mc:DocumentMapping ;
    mc:classMapping ( [...] ) .
}

<https://example.com/mappings/category-v1#> {
  <https://example.com/mappings/category-v1#> a mc:DocumentMapping ;
    mc:classMapping ( [...] ) .
}
```

### Three-Phase Pipeline

**Phase 1: CRDT Mapping Builder** (per source file)
- Scans Dart file for `@RootResource(crdt.generate == true)`
- Generates RDF graph for each root resource (field traversal, CRDT rules)
- Wraps each graph as named graph (key = `crdt.mappingIri`)
- Combines to `RdfDataset` → `trig.encode()` → `.crdt.cache.trig` file

**Phase 2: Mapping Bootstrap Builder** (aggregation)
- **Location:** `locorda_init_generator` package (same as CRDT Mapping Builder)
- Finds all `.crdt.cache.trig` files in cache (via build step asset discovery)
- Reads configurable RDF files from `assets/` (for manual/external mappings)
- Collects each document as separate string in list
- Serializes as `List<String>` in `lib/src/generated/mapping_bootstrap.g.dart`
- Each string uses multi-line formatting for developer readability:

```dart
// Each list entry is a complete RDF document (Turtle, TriG, JSON-LD, etc.)
// Multi-line raw strings (r""") avoid escaping issues with RDF content
const List<String> bootstrapMappings = [
  // Generated mapping from note.dart (TriG with named graphs)
  r"""
<https://example.com/mappings/note-v1#> {
  <https://example.com/mappings/note-v1#> a mc:DocumentMapping ;
    mc:classMapping ( [...] ) .
}
""",
  
  // Generated mapping from category.dart (TriG with named graphs)
  r"""
<https://example.com/mappings/category-v1#> {
  <https://example.com/mappings/category-v1#> a mc:DocumentMapping ;
    mc:classMapping ( [...] ) .
}
""",
  
  // Manual mapping from assets/ (Turtle format)
  r"""
@prefix mc: <...> .
<> a mc:DocumentMapping ; [...] .
""",
];
```

**Phase 3: Deployment Tool** (user invokes separately)
- Reads `lib/src/generated/mapping_bootstrap.g.dart`
- Extracts `List<String>` using Dart AST parser (`analyzer` package)
- For each string in list:
  - Detects format (Turtle/TriG/JSON-LD) and decodes to RDF
  - If TriG with named graphs: splits into separate documents
  - Extracts Document IRI from content (`mc:DocumentMapping` subject)
  - Derives filename from IRI (e.g., `note-v1.ttl`)
  - Encodes as Turtle → writes to output directory

### Build Integration

```yaml
# build.yaml (in locorda_init_generator)
builders:
  crdt_mapping_generator:
    import: "package:locorda_init_generator/builder.dart"
    builder_factories: ["crdtMappingBuilder"]
    build_extensions:
      lib/**/*.dart:
        - lib/**/*.crdt.cache.trig  # Mirrors source structure in cache
    auto_apply: dependents
    build_to: cache  # Ephemeral, not committed
    applies_builders: []
  
  mapping_bootstrap:
    import: "package:locorda_init_generator/builder.dart"
    builder_factories: ["mappingBootstrapBuilder"]
    build_extensions:
      $lib$:  # Synthetic input
        - lib/src/generated/mapping_bootstrap.g.dart
    auto_apply: dependents
    build_to: source
    applies_builders: []
```

**Key points:**
- `build_to: cache` - outputs are intermediate artifacts
- Pattern mirrors source structure for traceability
- Builder skips `.g.dart` files and non-library files
- Only generates when `crdt.generate == true`

## Graph-Based Generation

**Approach:** Build `List<Triple>` per root resource using generated vocabulary classes, wrap as named graphs in `RdfDataset`, encode with `trig.encode()`.

**Key principles:**
- Use generated vocabulary classes (`McDocumentMapping`, `AlgoVocab`) - never hardcode IRIs
- Build RDF lists manually with `Rdf.first`/`Rdf.rest`/`Rdf.nil` pattern
- Per root resource: `RdfGraph.fromTriples(triples)`
- Aggregate graphs into `RdfDataset` with `crdt.mappingIri` as named graph IRI
- Output: `trig.encode(dataset)` - always TriG format (even for single graph)
- Never use string concatenation for RDF serialization

## Field Traversal

**Algorithm:** Start with `@RootResource` class, recursively traverse fields:
- Unwrap container types (`List<T>`, `Set<T>`, `T?`)
- Include types with `@SubResource` or `@RdfLocalResource`
- Stop at primitives or external classes
- Deduplicate (each type once)

**Example:**
```dart
@RootResource(...)
class Note {
  @RdfProperty(...) @CrdtOrSet()
  late Set<Weblink> relatedLinks;  // ← Traverse into Weblink
}

@SubResource(...)
class Weblink {
  @RdfProperty(...) @CrdtImmutable()
  late String url;
}
// Result: Mapping includes both Note and Weblink
```

## Default Behavior

**CRDT Default:** Properties without CRDT annotation → `@CrdtLwwRegister()`

**Identifying Properties:** `@MergeIdentifying()` generates `McRule.isIdentifying true` triple (must be `@CrdtImmutable()`)

**Optional:** Build warning `[INFO] Note.title has no CRDT annotation, defaulting to LWW_Register`

## Integration with Ecosystem

**Generation Pipeline:**
1. **CRDT mapping generator** (`locorda_init_generator`) → `.crdt.cache.trig` files in build cache (per source file)
2. **Bootstrap generator** (`locorda_init_generator`) → reads cache + manual assets, outputs `lib/src/generated/mapping_bootstrap.g.dart` with `List<String>`
3. **Worker generator** → imports bootstrap, passes `List<String>` to `WorkerSetup`
4. **Config generator** → reads `crdt.mappingIri` from annotations, creates `ResourceConfig`
5. **initLocorda** → wires all generated artifacts together
6. **Deployment tool** (user-invoked) → processes `List<String>`, splits into individual TTL files for server deployment

**Key Integration Points:**
- All mappings (generated + manual) unified in `List<String>` constant
- Each list entry is a complete RDF document (supports Turtle, TriG, JSON-LD, etc.)
- External mappings (`.external()`) must be provided as RDF files in assets/
- Bootstrap builder configuration allows multiple asset paths via `mapping_roots` option
- Worker receives complete list, framework parses each document at runtime
- Config builder extracts mapping IRI from `@RootResource.crdt`

**Manual Mapping Integration:**
Users can provide handwritten mappings alongside generated ones:

```yaml
# build.yaml (in app)
targets:
  $default:
    builders:
      locorda_init_generator:mapping_bootstrap:
        options:
          mapping_roots:
            - assets/contracts/mappings    # Handwritten RDF files
            - assets/external/third_party  # Third-party mappings
```

Bootstrap builder (in `locorda_init_generator`):
1. Finds all `.crdt.cache.trig` files in cache
2. Reads each file as string → adds to list
3. Finds all RDF files (`.ttl`, `.trig`, `.jsonld`) in configured `mapping_roots`
4. Reads each file as string → adds to list
5. Outputs `const List<String> bootstrapMappings = [...];

**Algorithm:**
```dart
Future<List<String>> collectMappings(BuildStep buildStep) async {
  final mappings = <String>[];
  
  // 1. All generated .crdt.cache.trig from cache
  await for (final asset in buildStep.findAssets(Glob('**/*.crdt.cache.trig'))) {
    mappings.add(await buildStep.readAsString(asset));
  }
  
  // 2. All configured assets (handwritten)
  final assetRoots = builderOptions['mapping_roots'] as List? ?? 
                    ['assets/contracts/mappings'];
  for (final root in assetRoots) {
    await for (final asset in buildStep.findAssets(Glob('$root/**/*.{ttl,trig,jsonld}'))) {
      mappings.add(await buildStep.readAsString(asset));
    }
  }
  
  return mappings;
}
```

## Example Transformation

**Input:** Dart classes with `@RootResource`, `@RdfProperty`, CRDT annotations

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

**Builder:** `LibraryBuilder` scans `@RootResource` annotations, discovers types via field traversal, builds `RdfGraph` from triples, emits `.ttl` file via `turtle.encode()`.

**Build Config:** Empty `build_extensions: {$lib$: []}` (outputs determined dynamically), `build_to: source`.

### RDF Graph Construction

**Pattern:** Per root resource: List mutation → `RdfGraph.fromTriples()` → aggregate to `RdfDataset` → `trig.encode()`

**RDF Lists:** Implementation builds lists using `Rdf.first`/`Rdf.rest`/`Rdf.nil` pattern as needed.

```dart
// Per source file
final dataset = RdfDataset();

for (final rootResource in rootResourcesInFile) {
  if (!rootResource.crdt.generate) continue;
  
  final triples = <Triple>[];
  final mappingIri = IriTerm(rootResource.crdt.mappingIri);
  
  triples.add(Triple(mappingIri, rdf.type, McDocumentMapping.iri));
  // Build document metadata, imports list, class mappings with property rules
  // Use McRule.predicate, AlgoVocab.mergeWith, McRule.isIdentifying
  
  final graph = RdfGraph.fromTriples(triples);
  dataset.addNamedGraph(mappingIri, graph);
}

return trig.encode(dataset);
```

### Type Discovery & Processing

**Entry Point:** `@RootResource` → recursive field traversal (field types, Set/List generics)

**Discovery Rules:**
- Must have `@SubResource` or `@RootResource`
- Track processed types to avoid cycles
- Process breadth-first (queue)

**Per-Class Processing:**
1. Discover all `@RdfProperty` fields
2. Look up CRDT annotation (default: `@CrdtLwwRegister()`)
3. Check `@MergeIdentifying()`
4. Generate rule triple using `McRule.predicate`, `AlgoVocab.mergeWith`, optional `McRule.isIdentifying`

### Error Handling

- Missing annotations → emit warning with context
- Invalid IRIs → fail fast with clear message
- Cycle detection → warn and skip

### Output Management

**Generated Files:** Write to build cache, mirroring source file structure (`lib/models/note.dart` → cache `.../lib/models/note.crdt.cache.trig`)

**Collision Prevention:** 
- One `.crdt.cache.trig` file per source file (multiple root resources → multiple named graphs in dataset)
- Distinct `crdt.mappingIri` required per root class (enforced at annotation validation)
- Named graph IRIs must be unique across entire codebase

### Testing Strategy

**Unit Tests:** Verify single class, default behaviors, type traversal  
**Golden File Tests:** Compare generated TriG against expected output  
**Integration Tests:** 
- Validate TriG encoding/decoding roundtrip
- Test multiple root resources per file
- Verify bootstrap aggregation (cache + manual assets)
- Test deployment tool splitting logic
- Validate merge contract loader compatibility with TriG input

## Open Questions & Key Decisions

**Namespace Prefixes:** Use `IriTerm` everywhere, let `turtle.encode()` optimize prefixes. Define constants in `MergeContracts`.

**Version Strategy:** Version in URL (`note-v1.ttl`), create new `@RootResource` for breaking changes.

**Validation:** Builder should validate CRDT semantics (e.g., identifying properties must be Immutable).

**External Types:** Only traverse types with `@SubResource`, treat others as primitives.

**Build Performance:** Incremental builder, only regenerate changed roots + dependents.

## Deployment Tool

Separate CLI tool for splitting consolidated TriG into individual TTL files for server deployment.

### Usage

```bash
# From app root
dart run locorda_dev:deploy_mappings output/deploy/
```

### Implementation

**Location:** `packages/locorda_dev/bin/deploy_mappings.dart`

**Algorithm:**
1. Instantiate `RdfCore` in `main()` (configurable, e.g., custom prefixes)
2. Read `lib/src/generated/mapping_bootstrap.g.dart` as string
3. Parse with Dart AST parser: `parseString(content: fileContent).unit`
4. Traverse AST to find `TopLevelVariableDeclaration` named `bootstrapMappings`
5. Extract list literals from `ListLiteral` initializer
6. Get raw string values from `SimpleStringLiteral.value`
7. For each string:
   - Use `RdfCore` to auto-detect format and decode to RDF
   - If TriG with named graphs: extract each graph separately
   - Extract Document IRI (`mc:DocumentMapping` subject)
   - Derive filename from IRI (e.g., `note-v1.ttl` from `https://example.com/mappings/note-v1#`)
   - Use `RdfCore` to encode as Turtle → write to `<output_dir>/<filename>`
8. Print summary (file count, IRIs)

**Implementation Example:**
```dart
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:rdflib/rdflib.dart';

void main(List<String> args) async {
  if (args.isEmpty) {
    print('Usage: dart run deploy_mappings.dart <output_dir>');
    exit(1);
  }
  
  final outputDir = args[0];
  
  // Single RdfCore instance for the entire tool (configurable)
  final rdfCore = RdfCore();
  // Optional: Register custom prefixes or configure codecs
  // rdfCore.registerPrefix('myapp', 'https://myapp.example.com/');
  
  final bootstrapFile = File('lib/src/generated/mapping_bootstrap.g.dart');
  final mappings = extractMappingsList(await bootstrapFile.readAsString());
  
  await deployMappings(rdfCore, mappings, outputDir);
}

List<String> extractMappingsList(String dartCode) {
  final parseResult = parseString(content: dartCode);
  final unit = parseResult.unit;
  
  for (final declaration in unit.declarations) {
    if (declaration is TopLevelVariableDeclaration) {
      for (final variable in declaration.variables.variables) {
        if (variable.name.lexeme == 'bootstrapMappings') {
          final initializer = variable.initializer;
          if (initializer is ListLiteral) {
            return initializer.elements
                .whereType<SimpleStringLiteral>()
                .map((lit) => lit.value)  // Unescaped string content
                .toList();
          }
        }
      }
    }
  }
  throw Exception('bootstrapMappings not found');
}

Future<void> deployMappings(
  RdfCore rdfCore,
  List<String> mappings,
  String outputDir,
) async {
  final output = Directory(outputDir);
  await output.create(recursive: true);
  
  for (final mappingStr in mappings) {
    // Use RdfCore for format detection and decoding
    final dataset = rdfCore.decode(mappingStr);
    
    // Process each graph (handles both single-graph Turtle and multi-graph TriG)
    for (final graphEntry in dataset.graphs.entries) {
      final graph = graphEntry.value;
      
      // Extract Document IRI from mc:DocumentMapping subject
      final docIri = _extractDocumentIri(graph);
      if (docIri == null) continue;
      
      // Derive filename from IRI
      final filename = _deriveFilename(docIri);
      
      // Use RdfCore to encode as Turtle
      final turtle = rdfCore.turtle.encode(graph);
      
      // Write to output directory
      final file = File('${output.path}/$filename');
      await file.writeAsString(turtle);
      
      print('✓ $filename → $docIri');
    }
  }
}
```

**Error Handling:**
- Missing bootstrap file → clear error message
- Parse failures → show context and line number
- IRI extraction failures → log graph subject, continue
- File write errors → report per-file, continue

**Example Output:**
```
✓ note-v1.ttl → https://example.com/mappings/note-v1#
✓ category-v1.ttl → https://example.com/mappings/category-v1#
✓ core-v1.ttl → https://w3id.org/solid-crdt-sync/mappings/core-v1# (manual)

Deployed 3 mappings to output/deploy/
```

## Summary

Automatic CRDT mapping generation from annotations via graph-based RDF construction using **TriG format for cache files**. Smart field traversal discovers all relevant types. Sensible defaults (LWW when no annotation). **Three-phase architecture:**
1. CRDT Mapping Builder (`locorda_init_generator`) generates per-file TriG datasets in cache (supports multiple root resources)
2. Bootstrap Builder (`locorda_init_generator`) aggregates cache + manual assets into `List<String>` constant (supports any RDF format)
3. Deployment tool processes list entries, splits into individual TTL files for server upload

Seamless integration with worker and config generators. **Dual-source support:** generated mappings from cache + handwritten mappings from assets. Deployment flexibility (offline bootstrap + online updates). Migration support (opt-in, manual mappings via assets, external mappings via `.external()`).

