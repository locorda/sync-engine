**Detailed Plan: CRDT Mapping Codegen + initLocorda()**

---

## **Scope**
- Support Bootstrap loading of crdt mapping files
- Add **CRDT mapping generator** (TTL files per `@CrdtRootResource`).
- Add **convenience bootstrap** generator that can produce `initLocorda()`.
- Keep **manual mapping** and **explicit wiring** fully supported.
- Generators are **independent**: CRDT mapping does not require bootstrap, and bootstrap can exist without CRDT mapping.

---

## **Implementation Order Summary**
- **A**: Add bootstrap support in the merge contract loader and config (support `package:` bootstrap URLs while preserving official online IRIs).
- **B**: Implement the CRDT mapping generator, triggered by `@CrdtRootResource`, emitting deployable TTL files that can be used in conjunction with A.
- **C**: Build `initLocorda()` in stages:
  - **C1**: Pass-through wrapper that forwards `Locorda.create` parameters.
  - **C2**: Make `mapperInitializer` optional when `initRdfMapper` is generated.
  - **C3**: Make `workerSetup` optional when `worker.dart` is generated.
  - **C4**: Generate full `LocordaConfig` (including `crdtMapping` based on crdt generator output) from annotations.

---

## **Shared Constraints**
- Manual mapping and explicit wiring remain fully supported.
- RDF and CRDT mappings are **separate artifacts**, but CRDT mapping **builds on RDF mapping annotations** to resolve class and property IRIs.
- Bootstrap generators detect existing outputs (e.g. `initRdfMapper`) rather than making assumptions.

---

## **Phase A — Bootstrap Loader for CRDT Mappings**

### Goals
- Support local development without deploying mapping files.
- Enable immediate availability of mappings on first run.
- Bootstrap is for **initial loading only** - system still checks online for updates.
- Core framework mappings automatically available without user configuration.

### A.1 New package: locorda_mapping_bootstrap_generator
- Pure codegen package with **NO locorda dependencies**
- Scans `mappings/*.ttl` in any package
- Generates `lib/generated/mapping_bootstrap.g.dart`:
  ```dart
  const Map<Uri, String> bootstrapMappings = {
    Uri.parse('https://...'): r'''<TTL content>''',
  };
  ```
- Used by **both** locorda_core and user applications

### A.2 Package core mappings in locorda_core
- Use the generator to embed `mappings/core-v1.ttl`, `mappings/index-v1.ttl`, etc.
- Generate `lib/generated/mapping_bootstrap.g.dart` in locorda_core
- Export as `coreBootstrapMappings` from locorda_core

### A.3 BootstrapMergeContractLoader enhancement
- Located in locorda_core
- **Automatically includes** core framework mappings (core-v1, index-v1, etc.)
- Accepts additional user-provided mappings via WorkerParams
- Loader behavior:
  - **Bootstrap phase**: Use embedded content on first load
  - **Update phase**: Periodically check online IRI for updates
  - Preserves official online IRI as canonical identifier

### A.4 WorkerParams surface
Add new optional parameter:
```dart
class WorkerParams {
  final Map<Uri, String>? mappingBootstrapSources;
  // ... existing params
}
```

- User provides **only app-specific** mappings
- Core mappings automatically available (don't need to be passed)
- Example usage in user's `worker.dart`:
  ```dart
  import '../generated/mapping_bootstrap.g.dart';
  
  WorkerParams(
    mappingBootstrapSources: bootstrapMappings, // app mappings only
    // ...
  )
  ```

---

## **Phase B — CRDT Mapping Generator (Triggered by @CrdtRootResource)**

### Goals
- Generate deployable CRDT mapping TTL files from annotations.
- Leverage Phase A bootstrap loader for local development.
- Require **opt-in** via `@CrdtRootResource`.

### B.1 New annotations (locorda_annotations)
- `@CrdtRootResource(...)`
  - `iri` (required) - the RDF class IRI this mapping applies to
  - `label`, `comment` (optional) - for TTL documentation
  - `imports` (optional, default `core-v1`) - which base mappings to import
  - `version` (optional, default `v1`) - mapping version
- Optional: `@CrdtExternalMapping(...)`
  - Opt-out marker for manual mapping (optional URI for documentation).

### B.2 Mapping rules
- `@CrdtLwwRegister` → `algo:LWW_Register`
- `@CrdtOrSet` → `algo:OR_Set`
- `@CrdtImmutable` → `algo:Immutable`
- `@McIdentifying` → `mc:isIdentifying true`
- If a property has **no CRDT annotation**, default to **LWW** (emit build warning).

### B.3 Analyzer graph extraction
#### Scan all Dart files in `lib/`
- Collect class metadata:
  - Root = `@CrdtRootResource`
  - Sub = `@LcrdSubResource`
  - Local = `@RdfLocalResource`
- Collect properties:
  - Must have `@RdfProperty` (for predicate IRI)
  - Extract CRDT annotations

#### Type traversal
- Build reachable subgraph per Root:
  - Direct type of a property
  - Container types: `List<T>`, `Set<T>`, `Iterable<T>`
  - Only traverse types annotated with `@LcrdSubResource` or `@RdfLocalResource`
- No heuristics beyond annotations.

### B.4 TTL generation
#### Output path
- `contracts/mappings/<root-name>-v1.ttl` (outside `lib/`, using `build_to: source`)

#### Content structure (align with current handwritten mappings)
- DocumentMapping header:
  - label/comment from `@CrdtRootResource`
  - `mc:imports ( mappings:core-v1 )` by default
- `mc:classMapping` list:
  - One ClassMapping per root + each reachable sub/local resource
  - Each ClassMapping lists predicates with merge rules

#### Example expected output
- For `Note` root:
  - `pnotes:PersonalNote` rules
  - `pnotes:Weblink` rules (folded in)
  - etc.

### B.5 Build system integration
#### Aggregating builder (not per-file)
- Use a single builder that scans all `lib/**/*.dart`
- Ensures rebuild when any subresource changes

#### build.yaml
- `build_to: source`
- Output in `contracts/mappings/`
- Builder config:
  - `output_dir`
  - `default_imports`
  - `default_version`

---

## **Phase C — Convenience Bootstrap Generator (initLocorda)**

### Goals
- Reduce boilerplate for typical Locorda setup.
- Build incrementally: start simple, add features step-by-step.
- Detect and integrate with existing generators (RDF mapper, CRDT mappings, worker).

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