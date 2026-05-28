# 028 — Property Statements and Versioned Clocks

## Status: Proposed

## Context

- Fixes GitHub issue [#50 — LwwRegister concurrent merge silently loses uncontested LWW properties](https://github.com/kkalass/locorda/issues/50).
- Supersedes the property-clock approach attempted in PR #60, which was
  conceptually flawed (volatile installation-keyed clock IRIs, overlapping
  `changedProperty` sets, non-deterministic IRIs, `logicalTime` without
  installation context).
- Builds on proposals
  [001 — framework/app data separation](001-framework-app-data-separation.md),
  [002 — Resource Statements](002-resource-statements.md),
  [007 — Resource identity & clock structure](007-resource-identity_and_clock-structure-and-hash.md) and
  [008 — Path-identified blank nodes](008-path-identified-blank-nodes.md).

## Problem

The current LWW merge logic resolves "concurrent" writes at **document
granularity**: a single `crdt:clockHash` per document, plus a single
document-wide `physicalTime` tie-break. When two installations concurrently
change *different* properties of the same document, the merge picks one
installation's full property snapshot as the "winner" and silently drops
the other installation's property values — even though those properties
are not in conflict.

### Reproduction (from issue #50)

Two installations `A` and `B` both start from the same baseline state and
both perform one local save:

| Property        | Baseline    | A writes   | B writes      |
| --------------- | ----------- | ---------- | ------------- |
| `schema:name`   | `"Old"`     | `"NewA"`   | (unchanged)   |
| `schema:rating` | `3`         | (unchanged)| `5`           |

After bidirectional sync the document should contain
`schema:name = "NewA"` AND `schema:rating = 5`. With the current
implementation, the document-level LWW tie-break picks one installation's
state wholesale and the other property silently regresses to baseline.

### Why this happens

LWW (and FWW, Counter, …) is semantically a **per-value** rule, but the
current bookkeeping is per-document:

- `crdt:clockHash` summarises the entire document's HLC vector.
- `physicalTime` is one document-level number, not a per-property number.
- There is no way to express *"property `schema:name` was last modified by
  vector clock V₁; property `schema:rating` by V₂"* — so the merger has no
  information to merge property-by-property.

### Why PR #60's per-property clocks were the wrong fix

PR #60 tried to attach a `crdt:PropertyClock` to each
(installation, property) pair, reusing the `lcrd-clk-md5-<installation>`
IRI scheme. That design fails because:

1. **Volatile identity** — those IRIs are reused for every save and
   overwritten in-place, so any pointer into them ages out immediately.
2. **Overlapping `changedProperty` sets** — multiple property-clocks per
   installation collide and step on each other.
3. **Meaningless `logicalTime`** — a logical time without an installation
   reference cannot be compared with vector-clock semantics.
4. **Non-deterministic IRIs** — IRIs depend on save order, which breaks
   content-addressing and merge determinism.

We need a design that scales beyond LWW (to OR-Set, 2P-Set, FWW, Counter,
…) without growing per-installation state for every property.

## Proposed Solution

Introduce two new framework concepts:

1. **`sync:PropertyStatement`** — a framework metadata node about a
   `(subject, property)` pair, attached to the managed document via
   `sync:hasStatement` (the polymorphic statement channel introduced
   alongside `sync:ResourceStatement` in proposal 002).
2. **`crdt:VersionedClock` (`vclk`)** — an immutable, content-addressed
   snapshot of the document's HLC at a specific save, attached to a
   statement via `crdt:vclk`.

Together, they let any CRDT rule that needs per-value or per-property
causality bookkeeping (LWW, FWW, OR-Set member tombstones, …) point at a
**shared, deduplicated** clock snapshot rather than carrying per-pair
installation vectors.

### Three statement granularities, one channel

All three statement types are attached via `sync:hasStatement`. Identity
is **content-derived** (proposal 008 path-identified scheme):

| Statement type            | Identifies                  | Identifying properties               | Fragment scheme (informative) |
| ------------------------- | --------------------------- | ------------------------------------ | ----------------------------- |
| `rdf:Statement`           | a specific `(s, p, o)`      | `rdf:subject`, `rdf:predicate`, `rdf:object` | `lcrd-stmt-md5-<hash(s,p,o)>` |
| `sync:PropertyStatement`  | a `(s, p)` pair             | `sync:resource`, `sync:property`     | `lcrd-prop-md5-<hash(s,p)>`   |
| `sync:ResourceStatement`  | a resource `s` as a whole   | `sync:resource`                      | `lcrd-res-md5-<hash(s)>`      |

Crucially, **`sync:PropertyStatement` is NOT a subclass of
`rdf:Statement`**. `rdf:Statement` reifies a specific triple (a single
`(s,p,o)` fact); `sync:PropertyStatement` is metadata about *the property
slot itself* irrespective of its current value(s). Conflating the two
would force every property-level metadata node to carry an arbitrary
`rdf:object`, which has no meaning for slots that are multi-valued or
currently empty.

### Versioned Clock (`crdt:VersionedClock`)

A `VersionedClock` is an **immutable, content-addressed HLC snapshot**:

```turtle
<#lcrd-vclk-md5-…> a crdt:VersionedClock ;
    crdt:hasClockEntry
        [ a crdt:ClockEntry ;
          crdt:installationIri <…/installations/A#it> ;
          crdt:logicalTime 7 ;
          crdt:physicalTime "2025-..."^^xsd:dateTime ] ,
        [ a crdt:ClockEntry ;
          crdt:installationIri <…/installations/B#it> ;
          crdt:logicalTime 3 ;
          crdt:physicalTime "2025-..."^^xsd:dateTime ] .
```

**Hash input**: canonical N-Quads over `(installationIri, logicalTime)`
pairs sorted by `installationIri`. `physicalTime` is **annotation only**
and excluded from the hash — consistent with `crdt:clockHash`, and
necessary because physical time is observer-dependent (clock skew, machine
speed) and would otherwise produce divergent IRIs for the same logical
state.

`physicalTime` is preserved per entry because it is needed as a
deterministic tie-breaker when two vclks are **concurrent** under
vector-clock domination (see merge semantics below).

### Save-time encoding

On each local save that mutates property `p` on subject `s`, the document
merger:

1. Constructs (or reuses, if identical) the current document HLC as a
   `crdt:VersionedClock` node `V`. Its IRI is determined by the hash, so
   any two saves with the same logical vector reuse the same `V` —
   automatic deduplication.
2. Ensures a `sync:PropertyStatement` `P` for `(s, p)` exists (identity is
   `(s, p)` — also deduplicated).
3. Sets `P crdt:vclk V` (LWW on the vclk pointer; vector-clock domination
   resolves "later than" cleanly).
4. Emits any value-level statements the rule requires (e.g. `rdf:Statement`
   tombstones for OR-Set removal) and stamps them with their own
   `crdt:vclk V` pointer.

All statements stamped in the same save share the same `V` (one allocation
per save, regardless of how many properties changed).

### Merge semantics

For any algorithm that previously asked *"is the incoming value newer than
the local value?"* and broke ties on document-wide `physicalTime`, the
question is now answered per statement:

```
local_vclk    = local PropertyStatement(s,p).vclk
remote_vclk   = remote PropertyStatement(s,p).vclk

case compareVectorClocks(local_vclk, remote_vclk) of
    LocalDominates  -> keep local value
    RemoteDominates -> take remote value
    Equal           -> values agree (no-op)
    Concurrent      -> tie-break by max(physicalTime) across the two
                       vclks; on physical-time tie, fall back to a
                       deterministic rule (installationIri ordering)
```

This applies symmetrically to:

| Algorithm        | Uses `crdt:vclk` on …                                | Decision                                                                 |
| ---------------- | ---------------------------------------------------- | ------------------------------------------------------------------------ |
| LWW_Register     | the property's `PropertyStatement`                   | Newer vclk wins                                                          |
| FWW_Register     | the property's `PropertyStatement`                   | Older vclk wins                                                          |
| Immutable        | (none — no metadata required)                        | Already conflict-free                                                    |
| OR_Set           | per-member `rdf:Statement` (add) and tombstone (remove) | Standard OR-Set semantics; vclk only needed if causal ordering of add/remove of the same member is required |
| 2P_Set           | per-member `rdf:Statement` tombstone                 | Once removed, stays removed (no vclk comparison needed for removal)      |
| Counter          | per-installation contribution `PropertyStatement`    | Sum of contributions; vclk used to deduplicate replayed contributions    |

LWW is the only algorithm changed by this proposal *today*. The others
benefit from having the mechanism in place when they are implemented.

### Garbage collection

- **`sync:PropertyStatement`**: bounded by the merge contract — at most
  one per `(subject, property)` pair declared by the schema. Never
  garbage-collected.
- **`crdt:VersionedClock`**: garbage-collected by local sweep — when no
  `crdt:vclk` triple in the local graph references a given vclk IRI, it
  is safe to delete. Deduplication makes the steady-state count small
  (one per distinct logical vector ever observed locally).
- **`rdf:Statement` tombstones**: continue to follow existing retention
  policies (proposal 002).

## Worked example (issue #50, fixed)

Baseline document on both installations:

```turtle
<> a sync:ManagedDocument ;
   foaf:primaryTopic <#it> ;
   crdt:hasClockEntry [ … A=5, B=2 … ] ;
   sync:hasStatement <#lcrd-prop-md5-name>, <#lcrd-prop-md5-rating> .

<#it> a schema:Thing ;
      schema:name "Old" ;
      schema:rating 3 .

<#lcrd-prop-md5-name>   a sync:PropertyStatement ;
    sync:resource <#it> ; sync:property schema:name ;
    crdt:vclk <#lcrd-vclk-md5-baseline> .

<#lcrd-prop-md5-rating> a sync:PropertyStatement ;
    sync:resource <#it> ; sync:property schema:rating ;
    crdt:vclk <#lcrd-vclk-md5-baseline> .
```

After A writes `schema:name = "NewA"` (HLC → A=6, B=2) and B *independently*
writes `schema:rating = 5` (HLC → A=5, B=3):

| Property        | Local A vclk | Local B vclk | After cross-merge                       |
| --------------- | ------------ | ------------ | --------------------------------------- |
| `schema:name`   | A=6,B=2      | A=5,B=2      | A dominates ⇒ `"NewA"`                  |
| `schema:rating` | A=5,B=2      | A=5,B=3      | B dominates ⇒ `5`                       |

Both values survive, because the merger compares per-property vclks
instead of a single document-wide tie-break.

## Implementation impact

- `RemoteDocumentMerger` / `LocalDocumentMerger`: replace document-wide
  `physicalTime` tie-break with per-property `vclk` comparison (helper
  added in `crdt/vector_clock.dart`). When generating a save, emit one
  shared `VersionedClock` node + one `PropertyStatement` per changed
  property.
- `crdt_document_manager`: extend the save pipeline to populate
  `sync:hasStatement` with `PropertyStatement`s for mutated properties,
  reusing existing `sync:ResourceStatement` plumbing.
- Tests: add a new save-scenario asset reproducing issue #50, plus
  symmetric `update_…` scenarios. Existing asset
  `test_cases/save/38_concurrent_lww_per_property/` will be renamed for
  consistency with the `all_tests.json` index.
- Generated bootstrap (`mapping_bootstrap.g.dart`) is already regenerated
  from the new mapping additions in `spec/mappings/core-v1.ttl`.

No public API change. No on-the-wire breaking change beyond the new
optional `sync:hasStatement` entries (older readers ignore them, consistent
with the existing framework/app separation contract).

## Open questions / explicit non-goals

- **Counter semantics**: included in the applicability table for
  completeness; concrete encoding deferred until a Counter rule is added.
- **`PropertyStatement` for nested blank nodes**: identity uses the
  canonical IRI of the subject (proposal 008). No special handling
  required at this layer.
- **Migration**: pre-existing documents without `PropertyStatement`s
  continue to work; the merger treats "no local vclk" as the equivalent
  of the document's `crdt:clockHash` snapshot, so the behavioural change
  is monotone (concurrent uncontested writes start being preserved; no
  previously preserved write is lost).
