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

A `VersionedClock` is an **immutable, content-addressed HLC snapshot**.
Each entry is anchored to the document's existing `crdt:ClockEntry` IRI
via `crdt:forClockEntry` (identity anchor) and carries its own frozen
`logicalTime` / `physicalTime` values. The referenced `ClockEntry` may
advance after the snapshot is taken — the snapshot keeps the values it
was created with.

```turtle
<#lcrd-vclk-md5-…> a crdt:VersionedClock ;
    crdt:hasClockEntry
        [ crdt:forClockEntry <#lcrd-clk-md5-aaa> ;
          crdt:logicalTime 7 ;
          crdt:physicalTime 1704074700001 ] ,
        [ crdt:forClockEntry <#lcrd-clk-md5-bbb> ;
          crdt:logicalTime 3 ;
          crdt:physicalTime 1704074700050 ] .
```

**Why `crdt:forClockEntry` instead of `crdt:installationIri` as the
identity anchor?** The framework currently does not write
`crdt:installationIri` onto its `ClockEntry` nodes — installation
identity is conveyed purely through the deterministic
`lcrd-clk-md5-<hash(installationLocalId)>` IRI fragment, which is
content-addressed, stable across local and remote storage, and
identical on every installation that sees the entry. Using the
`ClockEntry` IRI as the anchor therefore needs no additional triples
in the existing HLC representation and stays semantically equivalent
to an installation-keyed vector clock. `crdt:installationIri` remains
optional in the vocabulary for future cross-document discovery use
cases.

**Hash input**: canonical N-Quads over `(forClockEntry, logicalTime)`
pairs sorted by `forClockEntry`. `physicalTime` is **annotation only**
and excluded from the hash — consistent with `crdt:clockHash`, and
necessary because physical time is observer-dependent (clock skew, machine
speed) and would otherwise produce divergent IRIs for the same logical
state.

`physicalTime` is preserved per entry because it is needed as a
deterministic tie-breaker when two vclks are **concurrent** under
vector-clock domination (see merge semantics below).

### Document-level base clock (`crdt:appBaseClock`)

Naïvely emitting one `sync:PropertyStatement` + one `crdt:vclk` per
app property would bloat every document — most steady-state documents
have many properties whose effective vclk is identical (e.g. all
properties of a freshly created resource, or all properties that have
not been touched since the last save). To avoid this, the framework
lets a document declare a single document-level vclk as the **default**
for any app property whose `sync:PropertyStatement` is absent:

```turtle
<>  a sync:ManagedDocument ;
    crdt:appBaseClock <#lcrd-vclk-md5-baseline> .
```

Any app property without an explicit `sync:PropertyStatement` is read
as if it carried `crdt:vclk = appBaseClock`. If `crdt:appBaseClock`
itself is absent, the fallback is the document's current HLC vector
(`docClock`, built from `crdt:hasClockEntry`). The three-step lookup
`PS.vclk → appBaseClock → docClock` is uniform across local reads,
save-time comparisons, and remote merges.

**Scope: app properties only.** Framework properties never participate
in this scheme — they are stamped via the existing framework-data pass
(no PS, no vclk; the framework relies on document-wide bookkeeping for
its own state). The predicate is named `appBaseClock` to make the
boundary explicit.

#### Why lazy initialisation matters

If `appBaseClock` were always written, the simplest case — a freshly
created document where every app property carries the same
(post-create) docClock — would still need one extra triple plus a
full `VersionedClock` subgraph. By **only** setting `appBaseClock`
when it is actually needed, freshly created documents and documents
whose every save is a full rewrite stay maximally compact (no
PropertyStatements, no VersionedClock subgraphs, no `appBaseClock`).

### Save-time encoding

On each local save:

1. Compute the **post-save** docClock `D` as usual (advance the
   installation's own `ClockEntry`).
2. For each *changed* app property `(s, p)`, its effective vclk is `D`.
3. For each *unchanged* app property, its effective vclk is whatever it
   was before this save:
      * if an explicit `sync:PropertyStatement` exists → its `crdt:vclk`;
      * else if `crdt:appBaseClock` is set → that vclk;
      * else the **pre-save** docClock.
4. **Set `crdt:appBaseClock` lazily.** If all of the following hold,
   set `appBaseClock` to the **pre-save** docClock snapshot (creating
   the corresponding `crdt:VersionedClock` node, deduplicated by
   content hash like any other vclk):
      * (a) `crdt:appBaseClock` is currently absent on the document,
      * (b) the pre-save docClock differs from `D` (this save advances
        the clock — otherwise nothing would dangle),
      * (c) at least one app property is *unchanged* by this save and
        has no explicit `sync:PropertyStatement` (i.e. its implicit
        reference would dangle once the docClock moves to `D`).
   Once set, `appBaseClock` is **never overwritten** by this proposal.
   (Future work may introduce a compaction trigger; see Open questions.)
5. Emit (or update) a `sync:PropertyStatement` `P` for `(s, p)` with
   `P crdt:vclk D` **only if** `D` differs from the effective default —
   that is, from `appBaseClock` when set, or from `D` itself when
   `appBaseClock` is absent. In the second case `D` *is* the default,
   so no PS is needed.
6. Any value-level statements the CRDT rule requires (e.g.
   `rdf:Statement` tombstones for OR-Set removal) are emitted and
   stamped with their own `crdt:vclk` (these are *value*-granular and
   do not benefit from the appBaseClock shortcut).
7. Existing PropertyStatements whose new effective vclk now equals the
   implicit default are removed via the standard LWW GC path in
   `LwwRegister.localValueChange` (`triplesToRemove`) — no new GC
   mechanism needed.

All statements stamped in the same save share the same `D` (one
VersionedClock allocation per save, regardless of how many properties
changed).

### Merge semantics

For any algorithm that previously asked *"is the incoming value newer than
the local value?"* and broke ties on document-wide `physicalTime`, the
question is now answered per statement, using the three-step lookup
on both sides:

```
resolveVclk(doc, s, p) =
    if exists PS(s,p) in doc with crdt:vclk V -> V
    else if doc has crdt:appBaseClock V       -> V
    else                                       -> doc.docClock

local_vclk  = resolveVclk(localDoc,  s, p)
remote_vclk = resolveVclk(remoteDoc, s, p)

case compareVectorClocks(local_vclk, remote_vclk) of
    LocalDominates  -> keep local value
    RemoteDominates -> take remote value
    Equal           -> values agree (no-op)
    Concurrent      -> tie-break by max(physicalTime) across the two
                       vclks; on physical-time tie, fall back to a
                       deterministic rule (forClockEntry ordering)
```

The `resolveVclk` fallback is the merge-protocol change required by
the `appBaseClock` optimisation. It is **symmetric**: each side
resolves *its own* `appBaseClock`/`docClock`, independently of the
other side's choices about which properties to materialise as explicit
`PropertyStatement`s. Two installations may freely differ on whether a
given property has an explicit `PS` — the comparison still yields the
same answer, because both sides agree on the *vector content* the
implicit default represents (the pre-save docClock at the time the
property was last written or the document was first created).

Note that `appBaseClock` is **monotone within a single installation**
(set once, never moved) and is normally the *same content* on every
installation when both have observed the document since its creation
— two installations only diverge on `appBaseClock` if one observed the
document *before* the first clock-advancing save and the other did
not. Even in that case the fallback resolution remains semantically
correct: each side resolves to a valid vclk snapshot of the document
at the time the property was last touched, and the standard vector-
clock comparison handles the rest.

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
  one per `(subject, property)` pair declared by the schema. Removed
  by the LWW GC path when its `crdt:vclk` becomes equal to the
  document's effective implicit default (`appBaseClock` or `docClock`).
- **`crdt:VersionedClock`**: garbage-collected by local sweep — when no
  `crdt:vclk` *and* no `crdt:appBaseClock` triple in the local graph
  references a given vclk IRI, it is safe to delete. Deduplication
  keeps the steady-state count small (one per distinct logical vector
  ever observed locally, plus the `appBaseClock` snapshot if any).
- **`crdt:appBaseClock`**: never removed once set by this proposal
  (write-once). Its target `VersionedClock` subgraph is held alive by
  the `appBaseClock` reference itself.
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

## Vocabulary additions

Added to `spec/vocabularies/crdt-mechanics.ttl`:

- `crdt:appBaseClock` — optional, functional property on
  `sync:ManagedDocument` with range `crdt:VersionedClock`. Provides the
  document-wide default vclk for app properties that have no explicit
  `sync:PropertyStatement`. Domain restricted to `sync:ManagedDocument`
  to make the framework-only scope discoverable from the vocabulary.

No changes to `sync:PropertyStatement` or `crdt:VersionedClock` beyond
what earlier sections of this proposal already introduce.

## Implementation impact

- `RemoteDocumentMerger` / `LocalDocumentMerger`: replace document-wide
  `physicalTime` tie-break with the `resolveVclk` per-property
  comparison (helper added in `crdt/vector_clock.dart`). When
  generating a save, emit one shared `VersionedClock` node + one
  `PropertyStatement` per changed property whose effective vclk differs
  from the implicit default; on the first clock-advancing save that
  leaves at least one app property implicit, also write
  `crdt:appBaseClock` referencing the pre-save docClock snapshot.
- `crdt_document_manager`: extend the save pipeline to populate
  `sync:hasStatement` with `PropertyStatement`s for mutated properties
  (subject to the implicit-default check), reusing existing
  `sync:ResourceStatement` plumbing.
- Tests: add a new save-scenario asset reproducing issue #50, plus
  symmetric `update_…` scenarios and an explicit
  `appBaseClock`-emission scenario (first incremental edit after
  creation). Existing asset
  `test_cases/save/38_concurrent_lww_per_property/` will be renamed for
  consistency with the `all_tests.json` index.
- Generated bootstrap (`mapping_bootstrap.g.dart`) is regenerated from
  the new mapping additions in `spec/mappings/core-v1.ttl`.

No public API change. No on-the-wire breaking change beyond the new
optional `sync:hasStatement` and `crdt:appBaseClock` triples (older
readers ignore them, consistent with the existing framework/app
separation contract).

## Open questions / explicit non-goals

- **Counter semantics**: included in the applicability table for
  completeness; concrete encoding deferred until a Counter rule is added.
- **`PropertyStatement` for nested blank nodes**: identity uses the
  canonical IRI of the subject (proposal 008). No special handling
  required at this layer.
- **Migration**: pre-existing documents without `PropertyStatement`s or
  `appBaseClock` continue to work; readers treat "no PS, no
  appBaseClock" as the document's current docClock (the legacy
  semantics), so the behavioural change is monotone (concurrent
  uncontested writes start being preserved; no previously preserved
  write is lost).
- **`appBaseClock` compaction**: `appBaseClock` is currently
  write-once. A future optimisation could move it forward when a save
  effectively rewrites every app property (making every explicit
  PropertyStatement collapsible into a new shared default), but the
  detection rule and merge implications need careful design and are
  out of scope here.
- **Shards and "all properties always at docClock" documents**: shard
  documents are a degenerate case where the shard subject's only
  property (`rdf:type idx:Shard`) is effectively immutable and every
  save rewrites the entries collectively. The lazy-set rule in
  step (4) of *Save-time encoding* (condition (c): "at least one app
  property is unchanged and has no explicit PS") is designed so that
  `appBaseClock` is never set on such documents in the first place,
  but the per-entry properties may still produce `PropertyStatement`s
  under the current rules. A follow-up proposal will revisit shard
  encoding once this proposal lands, to evaluate whether shard entries
  should bypass per-property statementing entirely (treating the entire
  shard payload as a single immutable-per-save unit).
