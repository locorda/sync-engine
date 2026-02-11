# Implementation Tasks: LocordaConfig Generation from Annotations

**Reference:** [019_locorda_config_generation.md](019_locorda_config_generation.md)  
**Date:** 2026-02-11

> These tasks implement annotation-driven `LocordaConfig` code generation (Phase 1 of the concept).
> Phase 2 (CRDT Mapping TTL generation) is out of scope for this document.

---

## Prerequisites & Ground Rules

- **Code is ground truth**: Always read actual file content before editing. Never trust descriptions alone.
- **Run tests**: After each task, run `cd packages/<package> && dart test` for affected packages.
- **Formatting**: Run `dart format .` in each modified package before considering a task done.
- **No breaking changes**: Existing annotations must remain backward-compatible. New parameters must have defaults.
- **Existing patterns**: Follow the code style and patterns already established in the codebase (e.g., `CodeGenerator` using `StringBuffer`, `InitLocordaBuilder` step-by-step approach).

---

## Task 1: Add New Annotation Classes to `locorda_annotations`

### Objective
Add `LcrdFullIndex`, `LcrdGroupingProperty`, `LcrdRegexTransform` as new classes, and enhance existing `LcrdRootResource`, `LcrdGroupKey`, and `LcrdIndexItem` annotations.

### Files to Modify

**`packages/locorda_annotations/lib/src/resource.dart`**

#### 1a. Add `LcrdFullIndex` class (new, add above `LcrdRootResource`)

```dart
/// Configuration for the default FullIndex of a root resource.
///
/// Controls whether a FullIndex is generated and its parameters.
/// Used as parameter in [LcrdRootResource.fullIndex].
class LcrdFullIndex {
  /// Whether FullIndex generation is enabled.
  final bool isEnabled;

  /// Local name for the FullIndex (default: 'default').
  final String localName;

  /// Item fetch policy for the FullIndex.
  final ItemFetchPolicy policy;

  /// Creates a FullIndex configuration with defaults.
  const LcrdFullIndex({
    this.localName = 'default',
    this.policy = ItemFetchPolicy.prefetch,
  }) : isEnabled = true;

  /// Disables FullIndex generation for this resource.
  /// Use when a resource only has GroupIndex indices.
  const LcrdFullIndex.disabled()
      : isEnabled = false,
        localName = '',
        policy = ItemFetchPolicy.prefetch;
}
```

Note: `ItemFetchPolicy` is imported from `locorda_core` which is already a dependency. The sealed class `ItemFetchPolicy` has static const members `prefetch` and `onRequest`, so use those as default values. Verify the import path works via `package:locorda_core/locorda_core.dart`.

#### 1b. Add `LcrdGroupingProperty` and `LcrdRegexTransform` (new, add before or after `LcrdGroupKey`)

```dart
/// Defines a regex transformation applied to a grouping property value.
///
/// Used within [LcrdGroupingProperty] to transform raw RDF values
/// (e.g., extracting year-month from a full date string).
class LcrdRegexTransform {
  final String pattern;
  final String replacement;

  const LcrdRegexTransform(this.pattern, this.replacement);
}

/// Defines a property used for grouping in a GroupIndex, with optional transforms.
///
/// The [property] IRI identifies which RDF predicate to group by.
/// Optional [transforms] apply regex transformations before grouping.
class LcrdGroupingProperty {
  final IriTerm property;
  final List<LcrdRegexTransform> transforms;

  const LcrdGroupingProperty(this.property, {this.transforms = const []});
}
```

Note: `IriTerm` is already available via `package:locorda_rdf_core/core.dart` which is transitively available through existing imports.

#### 1c. Enhance `LcrdRootResource` (modify existing class)

Current constructor:
```dart
const LcrdRootResource(IriTerm? classIri,
    [RootIriStrategy iriStrategy = const RootIriStrategy()])
    : super(classIri, iriStrategy);
```

New constructor — add `crdtMapping`, `generateCrdtMapping`, and `fullIndex` fields:
```dart
class LcrdRootResource extends RdfGlobalResource {
  /// Full absolute IRI identifying the CRDT mapping document.
  ///
  /// This is a static, app-owned IRI — fully known at compile time,
  /// not dependent on any user or Pod URL. Use Dart const string
  /// interpolation with a shared base constant to avoid repetition.
  ///
  /// Example: `'$appBaseUrl/mappings/note-v1.ttl'`
  /// where `const appBaseUrl = 'https://myapp.example.com';`
  final String crdtMapping;

  /// Whether to auto-generate the CRDT mapping file from property annotations.
  ///
  /// When `true` (default), the build system generates a `.ttl` file from
  /// `@CrdtLwwRegister`, `@CrdtOrSet`, `@CrdtImmutable` annotations.
  /// Set to `false` for manually authored mapping files.
  final bool generateCrdtMapping;

  /// Configuration for the default FullIndex.
  ///
  /// Defaults to `LcrdFullIndex()` (enabled, localName='default', prefetch).
  /// Use `LcrdFullIndex.disabled()` when only GroupIndex indices apply.
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

**BREAKING CHANGE**: The constructor signature changes from positional `[RootIriStrategy]` to named `{RootIriStrategy iriStrategy}`, and adds required positional `crdtMapping`. This is intentional — all call sites must be updated (see Task 5).

#### 1d. Enhance `LcrdGroupKey` (modify existing class)

Current:
```dart
class LcrdGroupKey extends RdfLocalResource {
  const LcrdGroupKey();
}
```

New:
```dart
/// Annotation for GroupIndex key classes.
///
/// Links a group key to its parent resource type and configures
/// the GroupIndex with an optional local name and grouping properties.
class LcrdGroupKey extends RdfLocalResource {
  /// The resource type this group index is for.
  final Type resourceType;

  /// Local name for this group index (default: 'default').
  final String? localName;

  /// Grouping property definitions with optional transforms.
  final List<LcrdGroupingProperty> groupingProperties;

  const LcrdGroupKey(
    this.resourceType, {
    this.localName,
    this.groupingProperties = const [],
  });
}
```

#### 1e. Enhance `LcrdIndexItem` (modify existing class)

Current:
```dart
class LcrdIndexItem extends RdfGlobalResource {
  const LcrdIndexItem(IndexItemIriStrategy iriStrategy)
      : super.deserializeOnly(null, iri: iriStrategy);
}
```

New — add `groupKeyType` field and named constructors:
```dart
/// Annotation for index item (entry) classes.
///
/// Use [LcrdIndexItem.fullIndex] for FullIndex entries and
/// [LcrdIndexItem.groupIndex] for GroupIndex entries.
class LcrdIndexItem extends RdfGlobalResource {
  /// The GroupKey type this item belongs to, or `null` for FullIndex items.
  final Type? groupKeyType;

  /// Creates a FullIndex item entry.
  ///
  /// The [iriStrategy] links back to the root resource type.
  /// Due to Dart const-constructor limitations, `IndexItemIriStrategy`
  /// must be passed as a parameter rather than constructed inline.
  const LcrdIndexItem.fullIndex(IndexItemIriStrategy iriStrategy)
      : groupKeyType = null,
        super.deserializeOnly(null, iri: iriStrategy);

  /// Creates a GroupIndex item entry linked to a specific [groupKeyType].
  const LcrdIndexItem.groupIndex(
      this.groupKeyType, IndexItemIriStrategy iriStrategy)
      : super.deserializeOnly(null, iri: iriStrategy);
}
```

**Note**: The old single constructor `LcrdIndexItem(iriStrategy)` is removed. Call sites must migrate to `.fullIndex()` or `.groupIndex()` (see Task 5).

### File to Modify: Exports

**`packages/locorda_annotations/lib/locorda_annotations.dart`**

Add the new classes to the `show` list in the `resource.dart` export:

```dart
export 'src/resource.dart'
    show
        LcrdRootResource,
        LcrdSubResource,
        LcrdGroupKey,
        LcrdIndexItem,
        LcrdFullIndex,           // NEW
        LcrdGroupingProperty,     // NEW
        LcrdRegexTransform,       // NEW
        RootIriStrategy,
        SubIriStrategy,
        IndexItemIriStrategy;
```

### Acceptance Criteria
- [ ] All new classes are `const`-constructable
- [ ] `LcrdFullIndex.disabled()` sets `isEnabled = false` 
- [ ] `LcrdRootResource` has `crdtMapping` as required positional parameter (after `classIri`)
- [ ] `LcrdRootResource.iriStrategy` is now a named parameter with default
- [ ] `LcrdGroupKey` takes `Type resourceType` as first positional parameter
- [ ] `LcrdIndexItem` has two named constructors: `.fullIndex()` and `.groupIndex()`
- [ ] No old single-constructor `LcrdIndexItem(...)` exists
- [ ] `dart analyze packages/locorda_annotations` passes (after updating call sites in Task 5)
- [ ] All new classes are exported from `locorda_annotations.dart`

---

## Task 2: Create the Config Generator Builder

### Objective
Create a new build_runner builder that scans `.dart` files for `@LcrdRootResource`, `@LcrdGroupKey`, and `@LcrdIndexItem` annotations, and generates a `locorda_config.g.dart` file.

### Architecture Overview

The config generator uses `package:source_gen` with a `SharedPartBuilder` or, more likely, a custom `Builder` similar to the existing `InitLocordaBuilder` since it needs to aggregate results across multiple files into one output file. Since `source_gen`'s generators produce per-file output, and we need a single aggregated output, use a custom `Builder` implementation.

**Approach**: Use a custom `Builder` that triggers on `pubspec.yaml` (like `InitLocordaBuilder`), uses `package:analyzer` to scan all `.dart` library files in `lib/` for the annotations, collects data, and generates a single output file.

### Files to Create

#### 2a. `packages/locorda_init_generator/lib/src/config/annotation_data.dart`

Data classes to hold extracted annotation information:

```dart
/// Immutable data extracted from @LcrdRootResource annotations.
class RootResourceData {
  final String className;
  final String? classIri;
  /// Raw Dart source expression for the crdtMapping IRI.
  /// May contain const interpolation (e.g., `'$appBaseUrl/mappings/note-v1.ttl'`).
  /// Emitted literally in generated code inside `Uri.parse(...)`.
  final String crdtMappingSource;
  final bool generateCrdtMapping;
  final FullIndexData fullIndex;
  final String sourceImport;

  const RootResourceData({
    required this.className,
    required this.classIri,
    required this.crdtMappingSource,
    required this.generateCrdtMapping,
    required this.fullIndex,
    required this.sourceImport,
  });
}

class FullIndexData {
  final bool isEnabled;
  final String localName;
  final String policy; // 'prefetch' | 'onRequest'

  const FullIndexData({
    required this.isEnabled,
    required this.localName,
    required this.policy,
  });
}

/// Immutable data extracted from @LcrdGroupKey annotations.
class GroupKeyData {
  final String className;
  final String resourceTypeName;
  final String? localName;
  final List<GroupingPropertyData> groupingProperties;
  final String sourceImport;

  const GroupKeyData({
    required this.className,
    required this.resourceTypeName,
    required this.localName,
    required this.groupingProperties,
    required this.sourceImport,
  });
}

class GroupingPropertyData {
  final String propertyIri;
  final String propertySource; // The dart source expression for the IRI
  final List<RegexTransformData> transforms;

  const GroupingPropertyData({
    required this.propertyIri,
    required this.propertySource,
    required this.transforms,
  });
}

class RegexTransformData {
  final String pattern;
  final String replacement;

  const RegexTransformData({
    required this.pattern,
    required this.replacement,
  });
}

/// Immutable data extracted from @LcrdIndexItem annotations.
class IndexItemData {
  final String className;
  /// Resource type name from IndexItemIriStrategy
  final String resourceTypeName;
  /// GroupKey type name — null for FullIndex items
  final String? groupKeyTypeName;
  /// Set of property IRIs (extracted from @RdfProperty fields)
  final List<IndexPropertyData> properties;
  final String sourceImport;

  const IndexItemData({
    required this.className,
    required this.resourceTypeName,
    required this.groupKeyTypeName,
    required this.properties,
    required this.sourceImport,
  });

  bool get isFullIndexItem => groupKeyTypeName == null;
  bool get isGroupIndexItem => groupKeyTypeName != null;
}

class IndexPropertyData {
  /// The Dart source expression for the IRI term (e.g., 'SchemaNoteDigitalDocument.name')
  final String source;

  const IndexPropertyData({required this.source});
}
```

#### 2b. `packages/locorda_init_generator/lib/src/config/annotation_scanner.dart`

Scans `.dart` source files for annotations using `package:analyzer`:

```dart
/// Scans Dart source files for Locorda config annotations.
///
/// Extracts @LcrdRootResource, @LcrdGroupKey, and @LcrdIndexItem
/// annotation data from AST nodes without requiring resolved elements.
class AnnotationScanner {
  /// Scans a single compilation unit for config-relevant annotations.
  /// Returns all found data grouped by type.
  ScanResult scanUnit(CompilationUnit unit, String importUri);
}

class ScanResult {
  final List<RootResourceData> rootResources;
  final List<GroupKeyData> groupKeys;
  final List<IndexItemData> indexItems;
  // ...
}
```

**Implementation Notes:**
- Parse annotation AST nodes using `package:analyzer/dart/ast/ast.dart`
- For `@LcrdRootResource(classIri, crdtMapping, ...)`: extract from constructor arguments
- For `@LcrdGroupKey(ResourceType, ...)`: extract `Type` argument and named parameters
- For `@LcrdIndexItem.fullIndex(iriStrategy)` / `.groupIndex(type, iriStrategy)`: detect named constructor and extract arguments
- For `@RdfProperty(iri)` on fields of IndexItem classes: extract the IRI source expression
- **Critical**: Use AST-level analysis (unresolved), not element-model. The existing `InitLocordaBuilder` uses `parseString()` — follow the same pattern.
- The `sourceImport` for each data item should be the `package:` URI of the file it was found in, so the generated code can import it.

**How to find source files to scan:**
The builder triggers on `pubspec.yaml`. To find all `.dart` files in the consumer package's `lib/` directory, use the build system's `findAssets()` or iterate known asset globs. Study how `build` package provides access to package sources. Alternatively, use `buildStep.findAssets(Glob('lib/**.dart'))` from `package:glob`.

Add `glob` to the `pubspec.yaml` dependencies if it's not already present:
```yaml
dependencies:
  glob: ^2.1.2
```

#### 2c. `packages/locorda_init_generator/lib/src/config/config_code_generator.dart`

Generates the `locorda_config.g.dart` content:

```dart
/// Generates locorda_config.g.dart from collected annotation data.
class ConfigCodeGenerator {
  final List<RootResourceData> rootResources;
  final List<GroupKeyData> groupKeys;
  final List<IndexItemData> indexItems;

  const ConfigCodeGenerator({
    required this.rootResources,
    required this.groupKeys,
    required this.indexItems,
  });

  /// Generates the complete file content.
  String generate();
}
```

**Generated output structure** (use `StringBuffer`, follow existing `CodeGenerator` pattern):

```dart
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: unused_import, depend_on_referenced_packages

import 'package:locorda_objects/locorda_objects.dart';
import 'package:locorda_core/locorda_core.dart';
// ... imports for each model file (sourceImport from data classes)

/// Generated LocordaConfig from annotations.
///
/// All crdtMapping IRIs are static, app-owned, absolute IRIs
/// fully determined at compile time from annotation values.
LocordaConfig generateLocordaConfig() {
  return LocordaConfig(
    resources: [
      // ... one ResourceConfig per RootResourceData
    ],
  );
}
```

**Generation algorithm** (per `RootResourceData`):

1. Find all `GroupKeyData` where `resourceTypeName == rootResource.className`
2. Find all `IndexItemData` where `resourceTypeName == rootResource.className`
3. For each `GroupKeyData`: find the matching `IndexItemData` where `groupKeyTypeName == groupKey.className`
4. If `fullIndex.isEnabled`: find `IndexItemData` where `isFullIndexItem && resourceTypeName == rootResource.className`
5. Assemble `ResourceConfig(...)` with all indices
6. For the `crdtMapping` URI: The annotation value is a full absolute IRI string (e.g., `'https://app.example.com/mappings/note-v1.ttl'`). At AST level this may be a string interpolation (e.g., `'$appBaseUrl/mappings/note-v1.ttl'`). Extract the raw Dart source expression via `.toSource()` and emit it directly in the generated code.

   **Important**: The scanner should store the `crdtMapping` as the raw **Dart source expression** (not the resolved string value), because it may contain const interpolation that must be preserved in the generated code. The generated code emits `Uri.parse(<source expression>)` literally.

#### 2d. `packages/locorda_init_generator/lib/src/config/config_builder.dart`

The builder itself:

```dart
/// Builder that generates lib/locorda_config.g.dart
///
/// Scans all .dart files in the consumer package's lib/ directory for
/// @LcrdRootResource, @LcrdGroupKey, and @LcrdIndexItem annotations,
/// then generates a LocordaConfig factory function.
class ConfigBuilder implements Builder {
  final BuilderOptions options;

  ConfigBuilder(this.options);

  @override
  Map<String, List<String>> get buildExtensions => {
        'pubspec.yaml': ['lib/locorda_config.g.dart'],
      };

  @override
  Future<void> build(BuildStep buildStep) async {
    // 1. Find all .dart files in lib/
    // 2. Parse each file, run AnnotationScanner
    // 3. Aggregate all ScanResults
    // 4. Run ConfigCodeGenerator
    // 5. Write output to lib/locorda_config.g.dart
  }
}

Builder configBuilder(BuilderOptions options) => ConfigBuilder(options);
```

**Trigger**: `pubspec.yaml` → `lib/locorda_config.g.dart` (same pattern as `init_locorda_generator`).

**File scanning**: Use `buildStep.findAssets(Glob('lib/**.dart'))` to discover source files. For each file, read content via `buildStep.readAsString()`, parse via `parseString()`, and scan.

**Skip generated files**: Filter out files ending in `.g.dart` to avoid scanning generated code.

### Files to Modify

#### 2e. `packages/locorda_init_generator/build.yaml`

Add the new builder alongside the existing one:

```yaml
builders:
  init_locorda_generator:
    # ... existing config unchanged ...
    
  locorda_config_generator:
    import: "package:locorda_init_generator/builder.dart"
    builder_factories: ["configBuilder"]
    build_extensions:
      pubspec.yaml:
        - lib/locorda_config.g.dart
    auto_apply: dependents
    build_to: source
    defaults:
      generate_for:
        - pubspec.yaml
```

#### 2f. `packages/locorda_init_generator/lib/builder.dart`

Add the new export:

```dart
export 'src/init_locorda_builder.dart';
export 'src/config/config_builder.dart';
```

#### 2g. `packages/locorda_init_generator/pubspec.yaml`

Add `glob` dependency if not present:

```yaml
dependencies:
  glob: ^2.1.2
  # ... existing deps ...
```

Also add `locorda_annotations` dependency (needed for annotation type references during scanning — or not, if doing pure AST string matching). **Decision**: Use pure AST string matching (comparing annotation names as strings, not resolved types). This avoids needing `locorda_annotations` as a dependency of the generator. The existing `InitLocordaBuilder` uses the same approach (string matching on AST).

### Acceptance Criteria
- [ ] `ConfigBuilder` triggers on `pubspec.yaml` and scans `lib/**.dart` files
- [ ] `AnnotationScanner` correctly extracts data from all three annotation types
- [ ] `ConfigCodeGenerator` produces valid Dart code
- [ ] Generated file includes proper imports for all referenced model classes
- [ ] Generated `generateLocordaConfig()` function compiles
- [ ] `dart analyze packages/locorda_init_generator` passes
- [ ] `.g.dart` files are excluded from scanning

---

## Task 3: Implement the Annotation Scanner

### Objective
Implement the `AnnotationScanner` class that extracts annotation data from Dart AST nodes.

### File
`packages/locorda_init_generator/lib/src/config/annotation_scanner.dart`

### Implementation Details

**Detecting annotations by name** (AST-level, no resolution):

For a class declaration, iterate `node.metadata` (list of `Annotation` nodes). Check:
- `@LcrdRootResource(...)` → `annotation.name.name == 'LcrdRootResource'`
- `@LcrdGroupKey(...)` → `annotation.name.name == 'LcrdGroupKey'`
- `@LcrdIndexItem.fullIndex(...)` → `annotation.name.name == 'LcrdIndexItem'` and `annotation.constructorName?.name == 'fullIndex'`
- `@LcrdIndexItem.groupIndex(...)` → same with `'groupIndex'`

**Extracting constructor arguments:**

From the `Annotation` node, access `annotation.arguments?.arguments` (a `NodeList<Expression>`). Positional arguments come first, named arguments are `NamedExpression` nodes.

**Extracting `@LcrdRootResource(classIri, crdtMapping, {...})`:**
- arg[0]: `classIri` — call `.toSource()` for the literal dart expression
- arg[1]: `crdtMapping` — use `.toSource()` to capture the raw Dart expression (preserves const interpolation)
- Named args: `iriStrategy`, `generateCrdtMapping`, `fullIndex` — detect by `NamedExpression.name`
- For `fullIndex`: if the value is `LcrdFullIndex.disabled` or `LcrdFullIndex.disabled()`, set `isEnabled = false`. If it's a `LcrdFullIndex(...)` constructor call, extract its named args (`localName`, `policy`). Default: enabled with defaults.

**Extracting `@LcrdGroupKey(resourceType, {...})`:**
- arg[0]: `resourceType` — `SimpleIdentifier.name` (the type name)
- Named: `localName`, `groupingProperties` (list literal of `LcrdGroupingProperty(...)` constructor calls)
- For each `LcrdGroupingProperty(iri, {transforms: [...]})`: extract IRI source and transform list

**Extracting `@LcrdIndexItem.fullIndex(iriStrategy)` / `.groupIndex(type, iriStrategy)`:**
- For `.groupIndex`: arg[0] is `Type`, arg[1] is `IndexItemIriStrategy(ResourceType)`
- For `.fullIndex`: arg[0] is `IndexItemIriStrategy(ResourceType)`
- Extract `ResourceType` from `IndexItemIriStrategy(ResourceType)` → the argument of the constructor call
- Then scan the class's fields for `@RdfProperty(iri)` to collect index properties

**Extracting index properties from fields:**

For each `FieldDeclaration` in the annotated class:
- Check `metadata` for `@RdfProperty(...)` or custom property annotations (like `@NoteCategoryProperty()`)
- For `@RdfProperty(iri)`: extract `iri.toSource()`
- For custom annotations: these extend `RdfProperty` — the scanner cannot know this without resolution. **Pragmatic solution**: Extract the first annotation argument from any non-CRDT, non-Lcrd annotation on the field that takes an IRI-like argument. OR: only extract `@RdfProperty(...)` and require custom properties to also have explicit `@RdfProperty(...)`.

> **⚠️ Design decision needed**: Custom property annotations like `@NoteCategoryProperty()` wrap an IRI internally. At AST level, the scanner cannot resolve the parent class. Options:
> 1. Only support `@RdfProperty(iri)` — users must add explicit `@RdfProperty` alongside custom annotations
> 2. Let users declare included properties explicitly in the annotation — e.g., `@LcrdIndexItem.fullIndex(iriStrategy, properties: {...})` 
> 3. Use resolved analysis (heavier, requires analyzer contexts)
> 
> **Recommended:** Option 1 — simplest, most predictable. Document that index item properties must have explicit `@RdfProperty(iri)`. Custom annotations without `@RdfProperty` are silently excluded.

### Acceptance Criteria
- [ ] Correctly parses `@LcrdRootResource` with all parameter variants
- [ ] Correctly parses `@LcrdGroupKey` with `groupingProperties` including nested `LcrdRegexTransform`
- [ ] Correctly parses both `@LcrdIndexItem.fullIndex()` and `.groupIndex()`
- [ ] Extracts `@RdfProperty` IRIs from index item class fields
- [ ] Returns empty results for files without relevant annotations
- [ ] Handles edge cases: no annotations, unnamed files, abstract classes
- [ ] Unit tests cover all parseable variants (see Task 6)

---

## Task 4: Implement the Config Code Generator

### Objective
Implement `ConfigCodeGenerator` that produces valid `locorda_config.g.dart` from collected annotation data.

### File
`packages/locorda_init_generator/lib/src/config/config_code_generator.dart`

### Implementation Details

Follow the existing `CodeGenerator` pattern (StringBuffer, private `_write*` methods).

**Structure:**
```
_writeHeader(buffer)
_writeImports(buffer)
_writeDocumentation(buffer)
_writeFunction(buffer)
  _writeResourceConfig(buffer, rootResource)
    _writeGroupIndex(buffer, groupKey, indexItem)
    _writeFullIndex(buffer, fullIndex, indexItem)
```

**Import collection:**
Collect unique `sourceImport` values from all data objects. Always import:
- `package:locorda_objects/locorda_objects.dart` (for `LocordaConfig`, `ResourceConfig`, etc.)
- `package:locorda_core/locorda_core.dart` (for `ItemFetchPolicy`, `GroupingProperty`, `RegexTransform`)

**The `crdtMapping` URI generation:**
The `crdtMapping` annotation value is a full absolute IRI, stored as a raw Dart source expression (may contain const interpolation like `'$appBaseUrl/mappings/note-v1.ttl'`). The generator emits `Uri.parse(<source expression>)` directly, preserving the original const expression.

Example: if the annotation has `'$appBaseUrl/mappings/note-v1.ttl'`, the generated code is:
```dart
crdtMapping: Uri.parse('$appBaseUrl/mappings/note-v1.ttl'),
```

**Property set generation for IndexItem:**
```dart
IndexItem(NoteIndexEntry, {
  SchemaNoteDigitalDocument.name,
  SchemaNoteDigitalDocument.dateCreated,
})
```
The property sources are stored as raw Dart expressions in `IndexPropertyData.source`.

**GroupingProperty generation:**
```dart
GroupingProperty(SchemaNoteDigitalDocument.dateCreated,
    transforms: [
      RegexTransform(r'pattern', r'replacement'),
    ])
```

### Acceptance Criteria
- [ ] Generated code compiles without errors
- [ ] Generated code follows the exact `LocordaConfig` API from `locorda_objects`
- [ ] `generateLocordaConfig()` signature has no parameters
- [ ] Resources with only GroupIndex (fullIndex disabled) have no FullIndex in output
- [ ] Resources with default FullIndex and no IndexItem generate `FullIndex()` without `item:`
- [ ] Resources with FullIndex and IndexItem generate full `FullIndex(item: IndexItem(...))` 
- [ ] All model class imports are included
- [ ] Correct Dart formatting (run `dart format` on output)
- [ ] Unit tests verify generated code structure (see Task 6)

---

## Task 5: Update Example App to Use New Annotations

### Objective
Update the personal notes app model files to use the enhanced annotation API. Update `main.dart` to (optionally) use generated config.

### Files to Modify

#### 5a. `packages/locorda/example/personal_notes_app/lib/models/note.dart`

Change the annotation from:
```dart
@LcrdRootResource(PersonalNotesVocab.PersonalNote,
    RootIriStrategy(RootIriConfig('note')))
```
To:
```dart
@LcrdRootResource(
  PersonalNotesVocab.PersonalNote,
  '$appBaseUrl/mappings/note-v1.ttl',
  iriStrategy: RootIriStrategy(RootIriConfig('note')),
  fullIndex: LcrdFullIndex.disabled(),
)
```

#### 5b. `packages/locorda/example/personal_notes_app/lib/models/category.dart`

Change from:
```dart
@LcrdRootResource(PersonalNotesVocab.NotesCategory)
```
To:
```dart
@LcrdRootResource(
  PersonalNotesVocab.NotesCategory,
  '$appBaseUrl/mappings/category-v1.ttl',
)
```

(Default `fullIndex: LcrdFullIndex()` provides FullIndex with prefetch.)

#### 5c. `packages/locorda/example/personal_notes_app/lib/models/note_group_key.dart`

Change from:
```dart
@LcrdGroupKey()
```
To:
```dart
@LcrdGroupKey(
  Note,
  localName: 'notes_by_month',
  groupingProperties: [
    LcrdGroupingProperty(
      SchemaNoteDigitalDocument.dateCreated,
      transforms: [
        LcrdRegexTransform(
          r'^([0-9]{4})-([0-9]{2})-([0-9]{2}).*',
          r'${1}-${2}',
        ),
      ],
    ),
  ],
)
```

Ensure `Note` is imported and available.

#### 5d. `packages/locorda/example/personal_notes_app/lib/models/note_index_entry.dart`

Change from:
```dart
@LcrdIndexItem(IndexItemIriStrategy(Note))
```
To:
```dart
@LcrdIndexItem.groupIndex(NoteGroupKey, IndexItemIriStrategy(Note))
```

Ensure `NoteGroupKey` is imported.

#### 5e. Create `packages/locorda/example/personal_notes_app/lib/models/category_index_entry.dart` (NEW)

This is optional but recommended — if Category should have an IndexItem for its FullIndex:

```dart
import 'package:locorda_annotations/locorda_annotations.dart';
import 'package:locorda_rdf_mapper_annotations/annotations.dart';
import 'category.dart';
// import vocabulary for SchemaCreativeWork

@LcrdIndexItem.fullIndex(IndexItemIriStrategy(Category))
class CategoryIndexEntry {
  @RdfProperty(SchemaCreativeWork.name) 
  final String name;

  // ... constructor etc. following existing model pattern
}
```

> **Note**: This file is optional. Category's FullIndex works without an IndexItem (it just won't have property filtering). Check whether the example app benefits from this.

#### 5f. `packages/locorda/example/personal_notes_app/lib/main.dart`

Once the config generator works, the manual `LocordaConfig(...)` block can be replaced with:

```dart
import 'locorda_config.g.dart';

// In initialization:
config: generateLocordaConfig(),
```

**Note**: Keep the manual config as a comment or in a separate function for reference until the generator is fully working and tested.

### Acceptance Criteria
- [ ] All model files use updated annotation constructors
- [ ] `dart analyze` passes for the example app
- [ ] Example app still compiles and runs correctly with manual config
- [ ] (After generator works) Generated config matches the previous manual config semantically

---

## Task 6: Write Tests

### Objective
Comprehensive unit tests for the annotation scanner and config code generator.

### Files to Create

#### 6a. `packages/locorda_init_generator/test/config/annotation_scanner_test.dart`

Test cases:
1. **Empty file** → empty `ScanResult`
2. **File with `@LcrdRootResource` only** → extracts `RootResourceData` with classIri, crdtMapping, defaults
3. **`@LcrdRootResource` with all parameters** → extracts iriStrategy, generateCrdtMapping=false, fullIndex with custom localName/policy
4. **`@LcrdRootResource` with `LcrdFullIndex.disabled()`** → `fullIndex.isEnabled == false`
5. **`@LcrdGroupKey` with resourceType and groupingProperties** → extracts all nested data including regex transforms
6. **`@LcrdGroupKey` with no optional parameters** → defaults applied
7. **`@LcrdIndexItem.fullIndex()`** → `groupKeyType == null`, extracts resourceType from IriStrategy
8. **`@LcrdIndexItem.groupIndex()`** → extracts both groupKeyType and resourceType
9. **IndexItem field scanning** → extracts `@RdfProperty` IRIs from class fields
10. **Multiple annotations in one file** → all collected
11. **File with no relevant annotations** → empty result
12. **`.g.dart` filename** → skipped (test at builder level)

**Test approach**: Create in-memory Dart source strings, call `parseString()`, then `scanner.scanUnit()`.

#### 6b. `packages/locorda_init_generator/test/config/config_code_generator_test.dart`

Test cases:
1. **Single resource with default FullIndex** → generates `ResourceConfig` with `FullIndex()`
2. **Single resource with disabled FullIndex and GroupIndex** → no FullIndex in output
3. **Resource with FullIndex + GroupIndex** → both indices generated
4. **GroupIndex with groupingProperties and transforms** → correct `GroupingProperty` and `RegexTransform` output
5. **IndexItem with properties** → correct `IndexItem(Type, {prop1, prop2})` output
6. **Multiple resources** → all in `resources: [...]`
7. **Imports are correct** → all sourceImport URIs appear as imports
8. **crdtMapping URI generation** → `Uri.parse(<source expression>)` emits raw Dart source
9. **Generated code compiles** (optional: use `dart analyze` on generated string)

**Test approach**: Construct `*Data` objects, call `generator.generate()`, assert on output string content (use `contains()` checks and/or full snapshot matching).

#### 6c. `packages/locorda_init_generator/test/config/config_builder_test.dart` (optional)

Integration test using `package:build_test`:
1. Set up a fake package with annotated `.dart` files
2. Run `ConfigBuilder`
3. Verify `locorda_config.g.dart` is generated with correct content

This is more complex and can be deferred. The unit tests in 6a and 6b provide the critical coverage.

### Acceptance Criteria
- [ ] All scanner test cases pass
- [ ] All code generator test cases pass
- [ ] Tests use in-memory source strings (no file I/O)
- [ ] `dart test packages/locorda_init_generator` passes
- [ ] Edge cases covered (empty input, missing annotations, defaults)

---

## Task 7: Integrate Config Generator with initLocorda Builder

### Objective
Modify the existing `InitLocordaBuilder` to optionally detect `locorda_config.g.dart` and integrate it into the generated `initLocorda()` function.

### Files to Modify

#### 7a. `packages/locorda_init_generator/lib/src/init_locorda_builder.dart`

Add a detection step (after Step 2, before Step 3):

```dart
// Step 2b: Detect locorda_config.g.dart
final hasGeneratedConfig = await buildStep.canRead(
  AssetId(inputId.package, 'lib/locorda_config.g.dart'),
);
_log.fine('Has locorda_config.g.dart: $hasGeneratedConfig');
```

Pass `hasGeneratedConfig` to `CodeGenerator`.

#### 7b. `packages/locorda_init_generator/lib/src/code_generator.dart`

Add `hasGeneratedConfig` parameter:

```dart
class CodeGenerator {
  final bool hasGeneratedWorker;
  final bool hasInitMapper;
  final bool hasGeneratedConfig;  // NEW
  // ...
}
```

**Modifications:**

In `_writeImports`:
```dart
if (hasGeneratedConfig) {
  buffer.writeln("import 'locorda_config.g.dart' show generateLocordaConfig;");
}
```

In `_writeDocumentation`:
```dart
if (hasGeneratedConfig) {
  buffer.writeln('/// - config: Generated from annotations via generateLocordaConfig()');
}
```

In `_filterLocordaParams`:
```dart
if (hasGeneratedConfig && param.name == 'config') {
  return false;
}
```

In `_writeFunctionBody`:
```dart
if (hasGeneratedConfig) {
  buffer.writeln('    config: generateLocordaConfig(),');
}
```

This means when `locorda_config.g.dart` is present:
- The `config` parameter is removed from `initLocorda()` signature
- `initLocorda()` calls `generateLocordaConfig()` internally

When `locorda_config.g.dart` is NOT present, behavior is unchanged — user passes `config:` manually.

#### 7c. `packages/locorda_init_generator/build.yaml`

Add `lib/locorda_config.g.dart` to the `required_inputs` of the existing `init_locorda_generator` builder so it can detect the file:

```yaml
builders:
  init_locorda_generator:
    # ... existing ...
    required_inputs:
      - lib/worker_generated.g.dart
      - lib/init_rdf_mapper.g.dart
      - lib/locorda_config.g.dart    # NEW
  
  locorda_config_generator:
    # ... new builder from Task 2 ...
```

### Acceptance Criteria
- [ ] When `locorda_config.g.dart` exists: `initLocorda()` has no `config` param, calls `generateLocordaConfig()` internally
- [ ] When `locorda_config.g.dart` does NOT exist: behavior unchanged, `config` param present
- [ ] Generated `initLocorda()` imports and calls `generateLocordaConfig()`
- [ ] `dart test packages/locorda_init_generator` passes (update existing `CodeGenerator` tests)
- [ ] No breaking change when config generator is not used

---

## Task 8: Update Existing CodeGenerator Tests

### Objective
Update existing tests to handle the new `hasGeneratedConfig` parameter and add new test cases.

### File to Modify
`packages/locorda_init_generator/test/code_generator_test.dart`

### Changes

1. Add `hasGeneratedConfig: false` to all existing `CodeGenerator(...)` constructors
2. Add new test cases:
   - **`generates initLocorda with config detection`**: `hasGeneratedConfig: true` — verify `config` removed from signature, `generateLocordaConfig()` in body, import of `locorda_config.g.dart`
   - **`generates initLocorda with all detections`**: all three booleans true — verify combined output

### Acceptance Criteria
- [ ] All existing tests still pass with `hasGeneratedConfig: false`
- [ ] New test cases verify config integration behavior
- [ ] `dart test packages/locorda_init_generator` passes

---

## Execution Order

```
Task 1 → Task 5 (annotations → update call sites)
    ↓
Task 2 → Task 3 → Task 4 (builder skeleton → scanner → generator)
    ↓
Task 6 (tests for scanner + generator)
    ↓
Task 7 → Task 8 (initLocorda integration → update existing tests)
```

Tasks 1+5 and Tasks 2+3+4 can be done in parallel. Task 6 requires Tasks 3+4. Tasks 7+8 require Tasks 2+6.

**Recommended sequential order for a single implementer:**
1. Task 1 (annotations)
2. Task 5 (update call sites so the project compiles)
3. Task 2 (builder skeleton + data classes)
4. Task 3 (annotation scanner)
5. Task 6a (scanner tests — validate before continuing)
6. Task 4 (config code generator)
7. Task 6b (generator tests)
8. Task 7 (initLocorda integration)
9. Task 8 (update existing tests)

---

## Open Design Decisions

These items need project-owner confirmation before or during implementation:

1. **Custom property annotations in IndexItems**: `@NoteCategoryProperty()` (extends `RdfProperty`) cannot be detected at AST level. **Recommendation**: Require explicit `@RdfProperty(iri)` on index item fields; custom annotations are silently ignored in property extraction.

2. **Index items without `@RdfProperty`**: Should the scanner warn or error when an `@LcrdIndexItem`-annotated class has no `@RdfProperty` fields? **Recommendation**: Generate `IndexItem(Type, {})` with empty properties — valid but pointless. Emit a build warning.

---

## Reference Files

| Purpose | Path |
|---------|------|
| Concept document | `proposed-changes/019_locorda_config_generation.md` |
| Current annotations | `packages/locorda_annotations/lib/src/resource.dart` |
| CRDT annotations | `packages/locorda_annotations/lib/src/crdt_annotations.dart` |
| Annotation exports | `packages/locorda_annotations/lib/locorda_annotations.dart` |
| Existing builder pattern | `packages/locorda_init_generator/lib/src/init_locorda_builder.dart` |
| Existing code generator | `packages/locorda_init_generator/lib/src/code_generator.dart` |
| Builder entry point | `packages/locorda_init_generator/lib/builder.dart` |
| Builder config | `packages/locorda_init_generator/build.yaml` |
| Generator dependencies | `packages/locorda_init_generator/pubspec.yaml` |
| Runtime config classes | `packages/locorda_objects/lib/src/config/locorda_config.dart` |
| Index config base | `packages/locorda_core/lib/src/index/index_config_base.dart` |
| Example app main | `packages/locorda/example/personal_notes_app/lib/main.dart` |
| Example note model | `packages/locorda/example/personal_notes_app/lib/models/note.dart` |
| Example category model | `packages/locorda/example/personal_notes_app/lib/models/category.dart` |
| Example group key | `packages/locorda/example/personal_notes_app/lib/models/note_group_key.dart` |
| Example index entry | `packages/locorda/example/personal_notes_app/lib/models/note_index_entry.dart` |
| Existing generator tests | `packages/locorda_init_generator/test/code_generator_test.dart` |
