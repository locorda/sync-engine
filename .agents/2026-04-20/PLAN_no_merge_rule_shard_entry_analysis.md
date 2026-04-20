# Analysis: "No merge rule found" Warnings for Index Entry Header Properties

**Date**: 2026-04-20  
**Status**: Paused, not yet fixed

---

## Root Cause

`LocalDocumentMerger._generateCrdtMetadataForChanges` emits `WARNING [WORKER:merge_contract] No merge rule found for property <https://schema.org/name> on unknown type, using LWW_Register` for index shard entry fragments.

### Why it happens

Entry fragments (e.g. `#entry-8274b4...`) have **no `rdf:type`** triple in the shard document. When `LocalDocumentMerger` processes a "common subject" (an existing entry that changed its header properties like `schema:dateModified`), it calls `_getCrdtAlgorithm(mergeContract, null, predicate)`. The merge contract has no rule for `(null type, schema:name)` → logs WARNING and falls back to LWW_Register.

### Affected paths

| Path | Status |
|------|--------|
| **added subjects** (new entry, `local_document_merger.dart` ~L248) | ✅ Has `isShardEntry` check → uses LWW_Register directly, no warning |
| **common subjects** (changed entry, `local_document_merger.dart` ~L338) | ❌ Missing `isShardEntry` check → calls `_getCrdtAlgorithm` → warning |
| `RemoteDocumentMerger` (~L255) | ✅ Has `isShardEntry` check → correct |

### Code location of the gap

`packages/locorda_core/lib/src/local_document_merger.dart`, the "common subjects" loop (approx. line 338):
```dart
// MISSING: no isShardEntry check here
final crdtType =
    _getCrdtAlgorithm(mergeContract, resourceType, predicate);
```

Should mirror the "added subjects" pattern:
```dart
final isShardEntry = isShard &&
    predicates.contains(IdxShardEntry.resource) &&
    predicates.contains(IdxShardEntry.crdtClockHash);

final crdtType =
    isShardEntry && !isShardEntryStructuralPredicate(predicate)
        ? _crdtTypeRegistry.getType(Algo.LWW_Register)
        : _getCrdtAlgorithm(mergeContract, resourceType, predicate);
```

### Architectural question (unresolved)

User recalls that index entries are **generated data** that should be rebuilt deterministically, not processed by CRDT merge machinery at all. Two options were identified but not decided:

**Option A (minimal fix)**: Add `isShardEntry` check to "common subjects" loop — eliminates warnings, matches existing behavior in "added subjects" and `RemoteDocumentMerger`.

**Option B (design-aligned)**: When `isShard=true`, skip entry-fragment subjects entirely in `_generateCrdtMetadataForChanges` — only shard-level subjects (shard IRI itself) generate CRDT metadata.

Option B is architecturally cleaner but changes behavior and requires more careful analysis of side effects.

---

## Impact

- Warnings appear in log during every sync when a note is modified (entry changes from old to new `dateModified` → "common subject" with changed predicate)
- Functionally harmless: LWW_Register is used anyway (same result as "added subjects" path)
- Log noise obscures real issues

---

## Files to modify (when resuming)

- `packages/locorda_core/lib/src/local_document_merger.dart` — "common subjects" loop, around line 338
