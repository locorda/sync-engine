# 027 — Deque-Based Cross-Shard Batching

## Status: Proposed

## Problem

The current `_pipeDownload` / `_pipeUpload` / S08 implementations in
`FilePerResourceRemoteSyncStorage` use a **drain-at-boundary** pattern:
at every boundary event (`ShardComplete`, `PhaseComplete`, etc.) the
adapter pauses the input stream and drains all in-flight backend results
before forwarding the boundary downstream.

This creates **artificial batch boundaries** — the backend never sees
requests from two different shards in flight simultaneously. This defeats:

1. **HTTP/2 multiplexing** — requests could overlap across shard
   boundaries for much better latency.
2. **Bulk API opportunities** — backends that batch requests with a
   timeout window get artificially small batches cut short by each
   shard boundary.
3. **Pipeline throughput** — downstream stages are starved while the
   adapter blocks waiting for all results of the current shard to
   arrive before emitting anything.

## Goal

Replace drain-at-boundary with a **Deque + IRI-matching** algorithm
that:

- Sends requests to the backend **immediately**, never pausing the
  input stream at boundaries.
- Matches backend results **by IRI** (not positional) — the backend
  contract no longer requires result ordering.
- Emits results **as soon as they arrive**, as long as all preceding
  entries in the Deque are resolved (or are PassThroughs). Does not
  wait for the entire segment to complete — individual results flow
  out immediately.
- Preserves **coarse ordering** (Deque-Boundaries are emitted in
  order, separating segments) but does **not** enforce fine ordering
  within a segment. This maximises throughput: a result arriving
  "early" (before other results in the same segment) is emitted
  immediately.
- Handles **duplicate IRIs** across shards (same resource in multiple
  shards → multiple Deque entries with the same IRI).
- Has a **safety valve** (result cache size limit) to bound memory
  when the backend delivers results far out of order.

## Design

### Data Structures

```
CacheKey:  (IriTerm iri, String? requestETag)
           — composite key to distinguish requests for the same IRI
             with different ETags (same resource in multiple shards)

Deque:  Queue<DequeEntry>
        where DequeEntry = DataEntry       { key: CacheKey, data: TData }
                         | BoundaryEntry   { outputEvent: TOut }
                         | PassThroughEntry { outputEvent: TOut }

ResultCache:  Map<CacheKey, List<TRes>>
              — ALL backend results go here; flushLeading() consumes
                from the cache. No mutable state on DataEntry.

OutputController:  StreamController<TOut>
                   — the single output sink, driven by two concurrent
                     listeners (input stream + backend result stream)
```

#### Three-Way Entry Classification

Not every pipeline `Boundary` type is a Deque-Boundary. The Deque uses
a **three-way classification** for incoming events:

| Entry Type | Behaviour in Deque | `flushLeading()` | Example |
|---|---|---|---|
| **DataEntry** | Holds in-flight request; blocks flush until ResultCache has a matching entry | Emits when `ResultCache[key]` is non-empty, blocks otherwise | `ShardRef`, `LoadedCandidate`, `MergedShard` |
| **BoundaryEntry** | Segment delimiter — separates groups of related DataEntries | Emits immediately (never blocks), but only reachable after preceding entries resolve | `ShardComplete`, `PhaseComplete`, `PhaseError` |
| **PassThroughEntry** | Pre-resolved entry — never blocks flush | Emits immediately, like a DataEntry whose result is already cached | `ResourceError`, non-fetched `LoadedCandidate`, non-uploaded `MergedShard` |

The key distinction: a **BoundaryEntry** maintains coarse ordering
(everything before a shard boundary is emitted before the boundary
itself), while a **PassThroughEntry** can be emitted as soon as all
entries before it in the Deque are resolved — it never blocks the
entries after it.

#### DataEntry

A `DataEntry` represents a single in-flight request sent to the
backend. It is **immutable** — results are stored separately in the
ResultCache, not on the entry itself.

| Field      | Type                 | Description |
|------------|----------------------|-------------|
| `key`      | `CacheKey`           | `(documentIri, requestETag)` — composite key for ResultCache matching. |
| `data`     | `TData`              | The original pipeline event (e.g. `ShardRef`, `LoadedCandidate`). |

`flushLeading()` checks `ResultCache[entry.key]` to determine whether
the entry is resolved. No mutable state on the entry.

#### BoundaryEntry

A `BoundaryEntry` is a **segment delimiter** — it separates groups of
related DataEntries. It holds the pre-converted output event and is
emitted during `flushLeading()` once all preceding entries have been
resolved. It does NOT block flush by itself — it flows through as soon
as it becomes the Deque head.

Critical: which pipeline events are BoundaryEntries depends on the
stage — see the per-stage classification below.

#### PassThroughEntry

A `PassThroughEntry` is like a pre-resolved DataEntry — it holds an
already-converted output event and never blocks flush. Examples:
`ResourceError` in S06 (an error for one resource does not block other
resources in the same shard), or a `LoadedCandidate` that doesn't need
fetching.

### Per-Stage Classification

#### S02 — Shard Fetch

| Input Event | Classification | Rationale |
|---|---|---|
| `ShardRef` | **DataEntry** | Sent to `backend.download` |
| `PhaseComplete` | **BoundaryEntry** | Phase delimiter |
| `PhaseError` | **BoundaryEntry** | Phase delimiter |

Shards freely reorder within a phase — no shard-level boundaries exist.
Downstream stages group by shard anyway, so intra-phase ordering does
not matter.

#### S06 — Resource Fetch

| Input Event | Classification | Rationale |
|---|---|---|
| `LoadedCandidate` (needs fetch) | **DataEntry** | Sent to `backend.download` |
| `LoadedCandidate` (no fetch needed) | **PassThroughEntry** | Skipped direction, pre-resolved |
| `ResourceError` | **PassThroughEntry** | Error for one resource — does NOT block other resources in shard |
| `ShardComplete` | **BoundaryEntry** | Shard delimiter — must follow all resources of that shard |
| `ShardError` | **BoundaryEntry** | Shard delimiter |
| `PhaseComplete` | **BoundaryEntry** | Phase delimiter |
| `PhaseError` | **BoundaryEntry** | Phase delimiter |

`ResourceError` is a pipeline `Boundary` type but a **Deque
PassThrough** — it does not block the flush of subsequent resources
in the same shard.

#### S08 — Resource Upload (special — see dedicated section)

| Input Event | Classification | Rationale |
|---|---|---|
| `MergeResult` (needs upload, no shard error) | **DataEntry** | Sent to `backend.upload` |
| `MergeResult` (no upload / shard has error) | **PassThroughEntry** | Not uploaded |
| `ResourceError` | **Special** | Triggers `discardUntilBoundary()` — taints shard |
| `ShardComplete` | **BoundaryEntry** | Shard delimiter + error aggregation |
| `ShardError` | **BoundaryEntry** | Shard delimiter |
| `PhaseComplete` | **BoundaryEntry** | Phase delimiter |
| `PhaseError` | **BoundaryEntry** | Phase delimiter |

#### S12 — Shard Upload

| Input Event | Classification | Rationale |
|---|---|---|
| `MergedShard` (needs upload) | **DataEntry** | Sent to `backend.upload` |
| `MergedShard` (no upload needed) | **PassThroughEntry** | Not uploaded |
| `ConflictedShard` | **PassThroughEntry** | Already errored shard, pass through |
| `ShardComplete` | **BoundaryEntry** | **Must** follow its shard's upload result — downstream expects upload done before ShardComplete |
| `ShardError` | **BoundaryEntry** | Shard delimiter |
| `PhaseComplete` | **BoundaryEntry** | Phase delimiter |
| `PhaseError` | **BoundaryEntry** | Phase delimiter |

**S12 is critical**: `ShardComplete`/`ShardError` must be
BoundaryEntries (not PassThroughs) because each shard's upload result
must arrive downstream _before_ its `ShardComplete`. Without the
boundary, a `ShardComplete` could slip past an unresolved shard upload
and confuse downstream stages.

### Result Matching with Composite Keys

The same resource IRI can appear in multiple shards with **different
ETags**, resulting in multiple `DataEntry` instances in the Deque.

Example (S06): Resource A in Shard 1 (`storedEtag: "v1"`) and Shard 2
(`storedEtag: "v2"`). Remote has version `"v1"`:
- Request 1: `{iri: A, ifNoneMatch: "v1"}` → 304 Not Modified
- Request 2: `{iri: A, ifNoneMatch: "v2"}` → 200 + graph

With IRI-only matching, the 304 could be assigned to Request 2 —
corrupting the pipeline's view of Shard 2's state.

The **composite key** `(IriTerm, String? requestETag)` prevents this.
Each request produces a unique key, and each result echoes back both
`documentIri` and `requestETag` so the cache lookup is O(1) and
unambiguous.

For stages where IRIs are always unique (S02, S12), the `requestETag`
is redundant but harmless — the composite key degenerates to IRI-only.

### Algorithm

#### Input Stream Events

**Data event** (resource/shard to fetch/upload):
```
1. Build key = (documentIri, requestETag)
2. Create DataEntry { key, data }
3. Append to Deque
4. Send request to backend via requestSink
5. Call flushLeading()   // may already find a cached result
```

**Boundary event** (ShardComplete, PhaseComplete, PhaseError, etc.):
```
1. If Deque is empty:
     → emit boundary directly to output (fast path)
2. Else:
     → Append BoundaryEntry to Deque
3. Call flushLeading()
```

**PassThrough event** (ResourceError, non-fetched LoadedCandidate, etc.):
```
1. Convert to output event
2. If Deque is empty:
     → emit directly to output (fast path)
3. Else:
     → Append PassThroughEntry to Deque
4. Call flushLeading()
```

#### Backend Result Events

When a result arrives from the backend stream:

```
1. Build key = (result.documentIri, result.requestETag)
2. ResultCache[key].add(result)        // always cache first
3. Check ResultCache size limit (see Safety Valve)
4. Call flushLeading()                 // consumes from cache
```

All results go into the cache — no scanning, no branching. The
`flushLeading()` call handles consumption. O(1) per result.

#### `flushLeading()`

Emits all resolved entries and boundaries from the front of the Deque:

```
while Deque is not empty:
  entry = Deque.first
  if entry is DataEntry:
    cached = ResultCache[entry.key]
    if cached is not empty:
      result = cached.removeFirst()
      if cached is empty: ResultCache.remove(entry.key)
      emit toOutput(entry.data, result)
      Deque.removeFirst()
    else:
      break   // no result yet → stop flushing
  if entry is BoundaryEntry:
    emit entry.outputEvent
    Deque.removeFirst()
  if entry is PassThroughEntry:
    emit entry.outputEvent
    Deque.removeFirst()
```

All result matching happens here via simple cache lookup — O(1) per
entry. This ensures Deque-Boundaries are emitted **in order** while
individual results and PassThroughs within a segment can arrive and be
emitted in **any order**. A `PassThroughEntry` never blocks — it
flushes immediately.

### Safety Valve — Result Cache Size Limit

When `ResultCache` grows beyond a configured limit (e.g. 100), a
**forced flush** is triggered to prevent unbounded memory growth:

```
while resultCache.size > (limit - threshold):
  // Force-flush the leading segment:
  for each unresolved DataEntry in Deque (before first Boundary):
    emit onError(entry.data, TimeoutError, stackTrace)
    Deque.removeFirst()
  // Flush any following BoundaryEntries
  flushLeading()
```

`threshold` (e.g. 10) provides hysteresis — we flush down to
`limit - threshold` rather than exactly `limit` to avoid thrashing.

The forced flush converts unresolved items to `ResourceError` or
`ShardError` depending on the stage. This is a last-resort safety
measure — it should not trigger under normal operation.

### Stream End Behaviour

When the **input stream** ends:
- Stop sending new requests to `requestSink`
- Close `requestSink` (via `unawaited` — backend may not have
  subscribed)
- Keep listening to the backend result stream

When the **backend result stream** ends:
- If Deque still has unresolved `DataEntry` items → convert each to
  an error event (`ResourceError`/`ShardError`) via `onError` callback
- Flush remaining boundaries
- Close output controller

When **both** streams have ended → done.

### Concurrency Model

Use `listen()` on both streams feeding a single `StreamController<TOut>`:

```dart
final out = StreamController<TOut>();

// Listener 1: input stream
inputSubscription = stream.listen(
  (event) { /* Data or boundary → Deque + requestSink */ },
  onDone: () { /* close requestSink, set inputDone */ },
  onError: (e, st) { /* ... */ },
);

// Listener 2: backend result stream
backendSubscription = backendResults.listen(
  (result) { /* IRI match → resolve in Deque → flushLeading */ },
  onDone: () { /* set backendDone, error remaining */ },
  onError: (e, st) { /* backendFailed → error all remaining */ },
);

yield* out.stream;
```

Both listeners call `flushLeading()` which adds events to `out`. The
`StreamController` serialises these additions — no explicit locking
needed since Dart is single-threaded.

**Completion**: When both `inputDone` and `backendDone` are true and
the Deque is empty, close `out`.

### Backpressure

The `StreamController` is non-broadcast and supports `pause`/`resume`.
If the downstream consumer pauses, `out.stream` pauses, but the two
listeners continue adding to the controller's buffer. This is acceptable
for bounded Deque sizes (enforced by the cache limit safety valve).

Future refinement: if the Deque itself grows too large, we could pause
`inputSubscription` to create backpressure upstream. For now, the cache
limit safety valve provides sufficient protection.

## API Changes

### 1. `RemoteDownloadResult<T>` — add `documentIri` + `requestETag`

```dart
class RemoteDownloadResult<T> {
  final IriTerm documentIri;    // NEW — echo of request documentIri
  final String? requestETag;    // NEW — echo of request ifNoneMatch
  final T? graph;
  final String? etag;
  final bool notModified;
  // ...
}
```

`requestETag` echoes back the `ifNoneMatch` value from the request.
Together with `documentIri` it forms the composite key for matching.

### 2. `RemoteUploadResult` (sealed) — add `documentIri` + `requestETag`

```dart
sealed class RemoteUploadResult {
  IriTerm get documentIri;      // NEW — echo of request documentIri
  String? get requestETag;      // NEW — echo of request ifMatch
  // ...
}

final class ConflictUploadResult extends RemoteUploadResult {
  @override final IriTerm documentIri;
  @override final String? requestETag;
  const ConflictUploadResult({required this.documentIri, this.requestETag});
}

final class SuccessUploadResult extends RemoteUploadResult {
  @override final IriTerm documentIri;
  @override final String? requestETag;
  final String etag;
  const SuccessUploadResult(this.etag, {required this.documentIri, this.requestETag});
}
```

### 3. `RemoteSyncBackend` contract — drop order guarantee

Before:
> "Results must be emitted in the same order as the input requests."

After:
> "Results may be emitted in any order. Each result carries `documentIri`
> and `requestETag` (echo of the conditional header from the request) to
> identify which request it answers. The adapter uses the composite key
> `(documentIri, requestETag)` for matching."

### 4. Backend implementations to update

All implementations must include `documentIri` in their results. Since
they already have access to `request.documentIri`, this is a trivial
pass-through:

| Backend | File | Effort |
|---------|------|--------|
| `_InMemorySyncBackend` | `in_memory_backend.dart` | `documentIri: request.documentIri, requestETag: request.ifNoneMatch` (download) / `request.ifMatch` (upload) |
| `DirSyncStorage` | `dir_backend.dart` | Same |
| 12 test backends | `stage{2,6,8,12}_test.dart` × 3 layouts | Same |

## Unified Helper

Currently there are three near-identical pipe methods:
- `_pipeDownload` (for S02 shard fetch, S06 resource fetch)
- `_pipeUpload` (for S12 shard upload)
- S08 inline `resourceUpload` (custom with `discardPending`)

The Deque algorithm is generic over request/result types. We can unify
download and upload into a **single helper** parameterised by:

```dart
Stream<TOut> _pipe<TData, TIn, TOut, TReq, TRes>({
  required Stream<TIn> stream,
  required TData? Function(TIn) extract,           // non-null → DataEntry (sent to backend)
  required bool Function(TIn) isBoundary,          // true → BoundaryEntry (segment delimiter)
  // false + extract==null → PassThroughEntry
  required (IriTerm, String?) Function(TData) toCacheKey,  // (iri, requestETag) for Deque key
  required TReq Function(TData) toRequest,
  required (IriTerm, String?) Function(TRes) resultCacheKey,  // extract composite key from result
  required TOut Function(TData, TRes) toOutput,
  required TOut Function(TIn) passBoundary,        // converts non-data events to output
  TOut Function(TData, Object error, StackTrace stackTrace)? onError,
  required Stream<TRes> Function(Stream<TReq>) backendCall,
  PipeperfCollector? perf,
  String? perfStage,
  int cacheLimit = 100,
  int cacheThreshold = 10,
})
```

The three-way classification is driven by two callbacks:
- `extract(event)` returns non-null → **DataEntry**
- `extract(event)` returns null + `isBoundary(event)` true → **BoundaryEntry**
- `extract(event)` returns null + `isBoundary(event)` false → **PassThroughEntry**

S08 requires special logic (error aggregation, `discardPending`
equivalent) that can either be handled via additional callbacks or
remain as a separate method using the same core Deque class.

**Recommendation**: Extract the Deque + IRI matching into a reusable
`_DequeState<TData, TRes>` helper class. `_pipe` and S08 both use it,
with S08 adding its shard-error-tracking on top.

## S08 Resource Upload — Special Considerations

S08 differs from the generic pipe in two ways:

1. **Error aggregation**: When a `ResourceError` arrives, the remaining
   resources in that shard should not be uploaded. In the Deque model,
   this means marking the remaining `DataEntry` items (up to the next
   shard boundary) as "discarded" — they don't need backend results and
   can be converted to pass-through `UploadResult` events without ETags.

2. **Shard-level error promotion**: Multiple `ResourceError`s are
   collapsed into a single `ShardError` at the shard boundary. The
   Deque flushes these as they resolve.

The `_DequeState` helper can support a `discard(IriTerm)` or
`discardUntilBoundary()` operation for this.

## Implementation Plan

### Phase 1: API Changes (prerequisites)

1. Add `documentIri` field to `RemoteDownloadResult`
2. Add `documentIri` getter to `RemoteUploadResult` sealed hierarchy
3. Update `RemoteSyncBackend` doc comments (drop order guarantee)
4. Update `_InMemorySyncBackend` — pass through `request.documentIri`
5. Update `DirSyncStorage` — same
6. Update all 12 test backends — same
7. Update all existing call sites that construct results (e.g. factory
   methods, `notModified`, `copyWith`)
8. Run tests — should still pass (drain-at-boundary still works, just
   results now carry an extra field)

### Phase 2: Deque Helper

1. Create `_DequeState<TData, TRes>` helper class encapsulating:
   - Deque (Queue of DataEntry/BoundaryEntry)
   - ResultCache (Map<(IriTerm, String?), List<TRes>>)
   - `addData((IriTerm, String?) key, TData)` → adds entry
   - `addBoundary(TOut)` → adds BoundaryEntry or emits directly
   - `addPassThrough(TOut)` → adds PassThroughEntry or emits directly
   - `addResult((IriTerm, String?) key, TRes)` → adds to cache, calls flushLeading
   - `flushLeading(emit)` → flushes resolved entries
   - `forceFlush(emit, onError)` → safety valve
   - `errorRemaining(emit, onError)` → fill unresolved with errors
   - `discardUntilBoundary(emit)` → for S08 error aggregation

### Phase 3: Unified `_pipe` Method

1. Implement `_pipe` using `_DequeState`, `listen()` on both streams,
   and `StreamController<TOut>` output
2. Replace `_pipeDownload` calls in S02 and S06
3. Replace `_pipeUpload` call in S12
4. Delete `_pipeDownload`, `_pipeDownload2`, `_pipeUpload`
5. Run tests

### Phase 4: S08 Migration

1. Rewrite S08 `resourceUpload` using `_DequeState` with discard
   semantics
2. Run tests

### Phase 5: Cleanup

1. Remove any dead code
2. Verify all 695+ tests pass
3. Consider adding targeted unit tests for the Deque helper itself
   (edge cases: duplicate IRIs, cache overflow, backend early close)

## Error Semantics (from design discussion)

- **PhaseError**: Flows through as a boundary marker — no special
  optimisation. Future S14 may recover from PhaseError.
- **Backend stream errors**: Only real errors (network failures, HTTP
  500s) should appear as stream errors. HTTP 404 (not found) and 304
  (not modified) must be result events, not errors.
- **Cache overflow**: Force-flushes convert unresolved items to
  `ResourceError`/`ShardError` — a last resort, not expected in
  normal operation.
- **Backend stream ends early**: Unresolved Deque items become
  `ResourceError`/`ShardError`.
- **Backend broken** (stream error): All remaining unresolved items
  become errors, no more requests sent.

## Diagram

```
Input Stream                          Backend
    │                                   │
    ├── Data(iri=A) ──────────────────► request A
    │   └── Deque: [A]                  │
    ├── Data(iri=B) ──────────────────► request B
    │   └── Deque: [A, B]              │
    ├── Boundary(ShardComplete)         │
    │   └── Deque: [A, B, ─SC─]       │
    ├── Data(iri=C) ──────────────────► request C
    │   └── Deque: [A, B, ─SC─, C]    │
    │                                   │
    │                          result B ◄┤
    │   resolve B in Deque              │
    │   └── Deque: [A, B✓, ─SC─, C]   │
    │   flushLeading: A unresolved → stop
    │                                   │
    │                          result A ◄┤
    │   resolve A in Deque              │
    │   └── Deque: [A✓, B✓, ─SC─, C]  │
    │   flushLeading:                   │
    │     emit output(A)                │
    │     emit output(B)                │
    │     emit ShardComplete            │
    │   └── Deque: [C]                 │
    │                                   │
    │                          result C ◄┤
    │   resolve C → emit output(C)      │
    │   └── Deque: []                  │
    │                                   │
    ▼ done                         done ▼
```

Note how B's result arrived before A's, but both are emitted as soon as
the leading segment is fully resolved. The ShardComplete boundary waits
for both A and B but is emitted immediately after them — and before C,
maintaining coarse ordering without enforcing fine ordering.

### Diagram: PassThrough (ResourceError in S06)

```
Input Stream                          Backend
    │                                   │
    ├── Data(iri=A) ──────────────────► request A
    │   └── Deque: [A]                  │
    ├── PassThrough(ResourceError X)    │
    │   └── Deque: [A, ═PT(ErrX)═]     │
    ├── Data(iri=B) ──────────────────► request B
    │   └── Deque: [A, ═PT(ErrX)═, B]  │
    ├── Boundary(ShardComplete)         │
    │   └── Deque: [A, ═PT═, B, ─SC─]  │
    │                                   │
    │                          result A ◄┤
    │   resolve A                       │
    │   flushLeading:                   │
    │     emit output(A)                │
    │     emit ResourceError(X)  ← PT!  │
    │   └── Deque: [B, ─SC─]           │
    │   B unresolved → stop             │
    │                                   │
    │                          result B ◄┤
    │   resolve B                       │
    │   flushLeading:                   │
    │     emit output(B)                │
    │     emit ShardComplete            │
    │   └── Deque: []                  │
```

The `ResourceError` PassThrough flows out as soon as A (before it) is
resolved — it does NOT block B or the ShardComplete after it.
