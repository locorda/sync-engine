
# 026 - Recap Sync Direction

**Status**: Decision proposal
**Created**: 2026-03-09
**Related**: 024 (Three-Phase Sync Architecture), 025 (Flat File Storage Architecture)

## Problem Statement

Locorda has reached a strategic turning point:

- The API and core sync semantics are good.
- The current shard/index-heavy execution is too slow for real use.
- This is true even on local directory backend for chat-essence-scale data.

So performance is not an optional improvement. It is a product requirement.

## Decision

Adopt a **performance-first architecture with one canonical core model and two storage profiles**.

1. Make fast sync the default direction for the next months.
2. Keep one internal model and expose two sync/storage profiles as projections:
	- **Dataset/Flat mode** (few files, type-level datasets, manifest-driven change detection) for `Dir` and `GDrive` by default.
	- **Linked-Data mode** (resource/shard-oriented, discoverability-oriented) for `Solid` and interoperability-sensitive deployments.
3. Implement in sequence:
	- First: 024 execution-order improvements (three-phase sync).
	- Then: 025 structural file-count reduction (flat files/chunks).
4. Define backend/profile switching semantics explicitly:
	- Same-profile switch: cheap.
	- Cross-profile switch: explicit projection rebuild/migration step.

This preserves developer simplicity (one API, one mental model) while making backend tradeoffs explicit where they belong.

## Why This Direction

### 1. Two independent bottlenecks exist

- **Execution-order bottleneck**: sequential per-shard download/merge/upload/commit loops.
- **File-count bottleneck**: too many files, too much metadata and request overhead.

024 addresses the first. 025 addresses the second. Both are needed.

### 2. "One universal storage representation" is the wrong optimization target

Trying to preserve every capability in one execution model is what keeps performance below acceptable levels.

The goal should be one **canonical sync model**, not one universal file layout.

### 3. Current codebase already points to profile separation

There is already a mode axis (`useShardDatasets`) and fetch-policy constraints that naturally separate:

- Prefetch-heavy dataset sync for throughput.
- Fine-grained linked-data sync for selective retrieval.

The missing piece is to document these as projection profiles over one core model, not as competing product concepts.

## Option Review

### Opt 1: Give up

Rejected. Does not match project goals.

### Opt 2: Radical state files + changes files only

Partially valid, but too absolute if applied globally.

- Good: maximum performance and simplified sync path.
- Risk: unnecessary strategic loss if it fully replaces linked-data mode.

### Opt 3: Refine current approach only

Necessary but not sufficient.

- 024 alone likely gives meaningful speedup.
- But 024 alone does not remove file-cardinality overhead.

### Opt 4: Recommended hybrid (new)

**Performance-first unified core + projection profiles**:

- Apply Opt 3 first (024).
- Apply Opt 2-style structure where it brings clear value (025 for flat mode).
- Preserve linked-data mode where interoperability/discoverability matters.
- Avoid always maintaining both remote representations at runtime.

## Are Opt 2 Tradeoffs Inevitable?

Only if we insist on one universal storage mode.

At product level, they are **not** inevitable:

- In dataset/flat mode, we accept reduced fine-grained linked-data behavior to get required speed.
- In linked-data mode, we keep semantics and selective capabilities, with a known slower performance envelope.
- We keep one developer-facing API and one canonical internal semantics layer.

This makes tradeoffs explicit, testable, and backend-dependent rather than ideological.

## Capability Matrix (Target)

| Capability | Dataset/Flat mode (Dir, GDrive default) | Linked-Data mode (Solid default) |
|---|---|---|
| Initial sync speed | High | Medium/Low |
| Incremental sync speed | High | Medium |
| File count overhead | Low | High |
| `onRequest`/fine-grained partial fetch | Limited (chunk-level only) | Full |
| Linked-data discoverability | Limited | Full |
| Cross-app semantic interoperability | Limited/optional | Strong |
| Complexity in hot path | Lower | Higher |

## Consequences

### What we keep

- Offline-first CRDT sync.
- User-owned storage model.
- Interoperable linked-data path (in linked-data mode).
- One developer-facing API and one core domain model.

### What we accept

- Not every backend needs every feature in its default mode.
- Dataset mode prioritizes throughput over fine-grained remote structure.
- Cross-profile backend switching is a migration operation, not a free runtime toggle.

### What we avoid

- Forcing Solid-style linked-data constraints onto backends where this is mostly overhead.
- Forcing performance backends to always maintain shard/index remote artifacts they do not use.

## Simplicity Guardrails

To avoid "two products in one codebase", follow these guardrails:

1. **One API surface**: app developers configure profile defaults, not low-level index/shard behavior.
2. **One canonical state contract**: CRDT merge semantics and local persistence stay profile-agnostic.
3. **Projection adapters**: profile-specific remote serialization lives behind storage adapters.
4. **No mandatory dual-write**: do not write both profile representations on every sync.
5. **Explicit migration tooling**: if profile changes, run projection rebuild once with progress/reporting.
6. **Docs by profile**: keep linked-data details out of flat-profile quickstarts.

## 90-Day Execution Plan

1. **Phase A (024)**: three-phase orchestration in production path.
	- Separate download, merge, upload/commit concerns.
	- Collapse per-shard commits into bulk commit where safe.
	- Introduce controlled backend concurrency with deterministic tests.
2. **Phase B (025)**: flat-file mode hardening.
	- Per-type datasets + manifest hashes.
	- Conflict-safe upload (ETag/version compare-and-swap + retry merge).
	- Benchmarks on Dir and GDrive.
3. **Phase C**: capability stabilization.
	- Keep linked-data mode for Solid with explicit performance expectations.
	- Add deterministic chunking for coarse partial sync in flat mode.
4. **Phase D**: product defaults.
	- Default backend presets: `Dir/GDrive => flat`, `Solid => linked`.
	- Document profile choice as product decision, not low-level tweak.
	- Provide explicit migration command/process for cross-profile backend switching.

## Benchmark Gates (Required)

Before declaring success, define and enforce targets:

1. Initial sync budget (chat-essence-scale dataset) per backend profile.
2. Incremental sync budget (small daily changes) per backend profile.
3. Conflict-recovery correctness for concurrent writes to same type dataset.
4. CRDT convergence checks after partial upload failures and retries.

## Final Position

We should not abandon the original vision.

We should stop forcing one remote representation to serve incompatible goals.

**Direction**: performance-first, one canonical core model, projection-based storage profiles, and explicit defaults by backend/use case.
