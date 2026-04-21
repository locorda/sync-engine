# locorda_annotations

CRDT merge strategy and RDF resource annotations for Locorda — used by code generators to produce merge contracts, RDF mappers, and sync configuration.

> Most Flutter applications should depend on [`locorda`](../locorda) rather than this package directly. `locorda` re-exports all annotations you need.

## Annotations

### Class-level

| Annotation | Purpose |
|------------|---------|
| `@RootResource` | Marks a class as a Locorda-managed RDF resource; configures vocabulary, merge contract, and index strategy |
| `@SubResource` | Nested global resource with a fragment IRI within a root resource document |
| `@LocalResource` | Blank-node resource that exists only within a parent resource |
| `@GroupKey` | Defines a group index partition key for paginated sync (e.g. by month) |
| `@IndexItem` | Marks a class as an index entry type for a FullIndex or GroupIndex |

### Property-level — CRDT strategies

| Annotation | CRDT type | Behaviour |
|------------|-----------|-----------|
| `@CrdtLwwRegister()` | Last-Write-Wins | Highest HLC timestamp wins; default if no annotation |
| `@CrdtOrSet()` | Observed-Remove Set | Multi-value, concurrent add/remove, re-addable |
| `@CrdtImmutable()` | Write-once | Set on creation, never overwritten by sync |
| `@MergeIdentifying()` | — | Marks a property as the identity key for blank-node CRDT merging |

### Parameters (used inside annotations)

| Class | Purpose |
|-------|---------|
| `MergeContract` | Configures the CRDT merge contract IRI; supports auto-generation or external reference |
| `FullIndex` | Configures the default full index (enabled, localName, fetch policy) |
| `GroupingProperty` / `RegexTransform` | Build group keys from property values via regex |
| `RootIriStrategy` / `SubIriStrategy` / `IndexItemIriStrategy` | IRI generation strategies |

## Example

```dart
import 'package:locorda/annotations.dart';

@RootResource(AppVocab(appBaseUri: 'https://myapp.example.com'))
class Note {
  @RdfIriPart()
  final String id;

  @CrdtLwwRegister()   // last writer wins on conflict
  final String title;

  @CrdtOrSet()         // multi-value, concurrent edits merge cleanly
  final List<String> tags;

  @CrdtImmutable()     // set once at creation
  final DateTime createdAt;
}
```

Run `dart run build_runner build` (with `locorda_dev` as a dev dependency) to generate the RDF mapper, CRDT merge contract, and sync configuration from these annotations.

## Further reading

- [locorda](../locorda) — main entry point and getting started guide
- [locorda_dev](../locorda_dev) — build-time code generation
