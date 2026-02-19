**Detailed Plan: CRDT Mapping Codegen + initLocorda()**

---

## **Scope**
- Support Bootstrap loading of CRDT mapping files for offline-first cold start.
- Add **CRDT mapping generator** (TTL files per `@CrdtRootResource`).
- Add **convenience bootstrap** generator that can produce `initLocorda()`.
- Keep **manual mapping** and **explicit wiring** fully supported.
- Generators are **independent**: CRDT mapping does not require bootstrap, and bootstrap can exist without CRDT mapping.
- Provide a single `locorda_dev` package that users add as `dev_dependency` for all Locorda build-time tools.

---

## **Implementation Order Summary**
- **A**: Bootstrap support in the merge contract loader — `locorda_dev` triggers the mapping bootstrap builder (from `locorda_mapping_bootstrap_generator`) and the web worker builder (from `locorda_builder`) via `applies_builders`, and also triggers the RDF mapper builders. Users need only `locorda_dev` + `build_runner` as dev_dependencies.
- **B**: Implement the CRDT mapping generator — **See [020-crdt-mapping-generation.md](020-crdt-mapping-generation.md) for detailed specification**
- **C**: Build `initLocorda()` in `locorda_dev` in stages:
  - **C1**: Pass-through wrapper that forwards `Locorda.create` parameters.
  - **C2**: Make `mapperInitializer` optional when `initRdfMapper` is generated.
  - **C3**: Make `workerSetup` optional when `worker.dart` is generated.
  - **C4**: Generate full `LocordaConfig` (including `crdtMapping` based on crdt generator output) from annotations.
- **D**: Persistent MergeContract cache in storage backends.

---

## **Package: `locorda_dev`**

Unified dev_dependency for all Locorda build-time tools. Uses `applies_builders`
to trigger the existing builder packages in dependent apps.

### Role
- Triggers the **mapping bootstrap builder** (`locorda_mapping_bootstrap_generator`)
- Triggers the **web worker builder** (`locorda_builder`)
- Triggers the **RDF mapper builders** (`locorda_rdf_mapper_generator`)
- Will trigger the **CRDT mapping generator** (Phase B)
- Will contain the **initLocorda() generator** (Phase C)

### User's dev_dependencies (before and after)

**Before:**
```yaml
dev_dependencies:
  build_runner: ^2.4.0
  locorda_rdf_mapper_generator: ^0.11.8
  locorda_builder: any
  locorda_mapping_bootstrap_generator: any
```

**After:**
```yaml
dev_dependencies:
  build_runner: ^2.4.0
  locorda_dev: any
```

---

## **Shared Constraints**
- Manual mapping and explicit wiring remain fully supported.
- RDF and CRDT mappings are **separate artifacts**, but CRDT mapping **builds on RDF mapping annotations** to resolve class and property IRIs.
- Bootstrap generators detect existing outputs (e.g. `initRdfMapper`) rather than making assumptions.

## **Phase A — Bootstrap Loader for CRDT Mappings**

### Goals
- Support local development without deploying mapping files.
- Enable immediate availability of mappings on first run (cold start).
- Bootstrap is for **initial loading only** — system still checks online for updates.
- Core framework mappings automatically available without user configuration.
- One mechanism for both core and user mappings.

### Design Rationale

**Unified approach: `locorda_mapping_bootstrap_generator` for everyone.**

The builder scans TTL files and generates `const List<String>` in Dart — identical for core framework mappings and user app mappings. The generated Dart file is a deterministic transformation of the TTL source, analogous to `.g.dart` files from `json_serializable` or `freezed`.

**Why Dart const (not asset loading)?**
- **Platform-universal**: Works identically in Flutter, CLI, and Web Workers. The worker isolate has no access to `rootBundle` (pure Dart, no Flutter dependency) and Web Workers have no asset loading mechanism.
- **Zero runtime overhead**: Strings are compiled into the binary, parsed lazily on first use.
- **No new infrastructure**: No worker↔main message protocol needed.
- **Simple**: No async loading, no error handling for missing assets, no race conditions.

**TTL files are not duplicated** — they remain the authoritative source. The generated Dart file is a build artifact (like any `.g.dart`), checked into git for convenience.

### A.1 Mapping bootstrap builder (in `locorda_mapping_bootstrap_generator`)

Builder that scans TTL files and generates Dart const strings:
- Scans configurable `mapping_roots` directories for `*.ttl` files.
- Generates `lib/src/generated/mapping_bootstrap.g.dart`:
  ```dart
  // GENERATED CODE - DO NOT MODIFY BY HAND
  const List<String> bootstrapMappings = [
    "<TTL content escaped as JSON string>",
    // ...
  ];
  ```
- Default `mapping_roots`: `['assets/contracts/mappings']`
- Configurable per package via `build.yaml` options.
- Applied via `locorda_dev` using `applies_builders`.

### A.2 Core mappings in `locorda_core`

TTL source files are in `assets/contracts/mappings/` inside `locorda_core` (symlinked or copied from `spec/mappings/`).

The mapping bootstrap builder from `locorda_mapping_bootstrap_generator` scans them and generates `lib/src/generated/mapping_bootstrap.g.dart`.

The generated `bootstrapMappings` is imported by `BootstrapRdfGraphFetcher` to provide core mappings (core-v1, index-v1, shard-v1, client-installation-v1) without any user configuration.

### A.3 User app mappings

**User workflow** (hand-written TTL):
```
my_app/
  assets/
    contracts/
      mappings/
        my-notes-v1.ttl    ← authoritative source, also used for deployment
  pubspec.yaml              ← depends on locorda_dev
  lib/src/generated/
    mapping_bootstrap.g.dart  ← auto-generated by builder
```

The same TTL file serves two purposes:
1. **Bootstrap**: Embedded as Dart const via the builder, available offline in the worker.
2. **Deployment**: Published to the mapping's canonical IRI on the web (user's deploy step).

**User workflow** (generated from annotations, Phase B):
- Phase B builder generates TTL to `assets/contracts/mappings/`.
- Phase A builder picks up the generated TTL and produces the Dart bootstrap.
- Both builders run in the same `build_runner` pipeline.

### A.4 `BootstrapRdfGraphFetcher`

Located in `recursive_rdf_loader.dart`. Provides bootstrap mappings to the merge contract loading system.

- **Core mappings** (from `bootstrapMappings` const in locorda_core): Always available.
- **User mappings**: Passed as `Iterable<String>?` via `WorkerParams.mappingBootstrapSources`.
- Combines both into a lazy-initialized `Map<IriTerm, RdfGraph>` (parsed only on first access).
- Falls back to online fetcher when no bootstrap match exists.

Lookup order:
1. In-memory bootstrap map (core + user, parsed lazily)
2. Online fetcher (if available)

### A.5 `CachingMergeContractLoader` behavior

Orchestrates bootstrap vs online:
- **Cold start**: Bootstrap fetcher provides immediate result.
- **Background refresh**: Periodically checks online IRI for updates.
- **Warm start**: Returns cached result instantly, refreshes in background if stale.

### A.6 `WorkerParams` surface

```dart
class WorkerParams {
  /// Additional bootstrap sources as raw TTL strings.
  /// Core framework mappings are included automatically.
  /// User app mappings from the generated bootstrap file go here.
  final Iterable<String>? mappingBootstrapSources;
  // ... existing params
}
```

**Example usage in user's `worker.dart`:**
```dart
import 'package:my_app/src/generated/mapping_bootstrap.g.dart' as app_bootstrap;

WorkerParams(
  mappingBootstrapSources: app_bootstrap.bootstrapMappings,
  // ...
)
```

Core mappings are automatically included by `BootstrapRdfGraphFetcher` — the user only passes their own app mappings.

---

## **Phase B — CRDT Mapping Generator**

**See [020-crdt-mapping-generation.md](020-crdt-mapping-generation.md) for complete specification.**

### Summary
- Triggered by `@LcrdRootResource` annotation with `generateCrdtMapping` flag
- Generates deployable CRDT mapping TTL files using graph-based generation (`RdfGraph` + `turtle.encode()`)
- Automatic field traversal to discover sub-resources and local resources
- Defaults to `CrdtLwwRegister` for properties without CRDT annotation
- Outputs to `assets/contracts/mappings/` for Phase A bootstrap integration
- Graph-based generation ensures correctness and maintainability

### Key Design Decisions (from 020)
1. **Graph-based generation:** Use `RdfGraph` and `turtle.encode()`, not string concatenation
2. **Field traversal:** Recursively discover `@LcrdSubResource` and `@RdfLocalResource` types
3. **Smart defaults:** Apply `LWW_Register` when no CRDT annotation present
4. **Enhanced annotation:** New `CrdtMappingConfig` class for imports, label, comment
5. **Integration:** Seamlessly chains with mapping bootstrap, worker generator, and config builder

---

## **Phase C — Convenience Bootstrap Generator (initLocorda) — in `locorda_dev`**

### Goals
- Reduce boilerplate for typical Locorda setup.
- Build incrementally: start simple, add features step-by-step.
- Detect and integrate with existing generators (RDF mapper, CRDT mappings, worker).
- The `initLocorda` builder in `locorda_dev` is also the anchor for `applies_builders`, ensuring all Locorda builders run when `locorda_dev` is a dependency.

### C.1 Step 1: pass-through wrapper
- Generated `initLocorda()` has parameters 1:1 with `Locorda.create` and forwards them.
- No magic, just a convenience function in `lib/generated/locorda_bootstrap.g.dart`.

### C.2 Step 2: optional mapperInitializer
- If `initRdfMapper` exists (from RDF mapper generator), make `mapperInitializer` optional.
- Expose required `initRdfMapper` dependencies as required params on `initLocorda`.
- Forward them internally to `initRdfMapper`.

### C.3 Step 3: optional workerSetup
- If a generated `worker.dart` exists, make `workerSetup` optional and default to it.
- User can still override by passing explicit `workerSetup`.

### C.4 Step 4: generate full LocordaConfig
- Generate `LocordaConfig` from annotations (using `@LcrdRootResource`, `@LcrdGroupKey`, `@LcrdIndexItem`).
- Automatically set `crdtMapping` URIs if Phase B mappings exist.
- Add new annotations if needed for full index config generation.

---

## **Phase D — Persistent MergeContract Cache**
- Add an optional interface (e.g. `MergeContractCache`) implemented by storage backends that want to persist merge contracts.
- Core remains DB-agnostic by checking `if (storage is MergeContractCache)` and using it when available.
- Cached item: computed `MergeContract` keyed by a canonical `governedBy` key + metadata (e.g. last refresh timestamp).
- Semantics:
  - If in-memory cache misses, read from persistent cache and return immediately.
  - Trigger online refresh in the background and update both caches on success depending on age of the persisted entry.
  - Use bootstrap only when both caches are empty.
- Store the timestamp in the MergeContractCache and also use it when restoring the in-memory cache entry from the storage.

---

## **Open Questions**
1. **Phase B → assets generation**: Can build_runner generate directly to `assets/contracts/mappings/`? Initial testing suggests it works. If so, Phase B TTL output → Phase A Dart const generation chains naturally in one `build_runner` pipeline.
2. **Deployment workflow**: How do users publish their TTL files to the canonical IRI? Document recommended patterns (e.g. copy from `assets/` to web server, or CI/CD step).
3. **CLI apps without Flutter**: For `locorda_core` standalone, users pass TTL strings via `WorkerParams.mappingBootstrapSources`. The same generated bootstrap file works since it's pure Dart with no Flutter dependency.

## **Shared Tests**
### Builder unit tests
- Input: annotated models
- Output: compare TTL with goldens (`note-v1.ttl` etc.)

### Traversal tests
- Verify sub/local resources are included
- Verify container types are resolved

### Default rule tests
- Missing CRDT annotation defaults to LWW + warning

---

## **Documentation**
- Add minimal README section:
  - how to opt‑in with `@CrdtRootResource`
  - where TTL files land
  - how to deploy mapping files
  - how to use `initLocorda()`

---

## **Open Decisions (confirm before implementation)**
1. **`@CrdtRootResource` fields**: exact parameters (label/comment/imports/version)
2. **Default LWW warning**: build warning vs silent default
3. **Namespace/prefix handling** in generated TTL
4. **Whether to generate constants for mapping URIs**