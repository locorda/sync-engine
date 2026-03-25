# 008: Review of 007 Pipeline Design

Review of [007-two-pass-sync-pipeline.md](007-two-pass-sync-pipeline.md). Items already applied to 007 are not listed here.

---

## 1. Stream Operator Selection for Stage Implementation

**Severity: High** — the operator choice determines actual microtask overhead; a naive `StreamController`-per-stage approach incurs measurable overhead at 15k items, the correct choice eliminates it.

The choice of stream operator for each stage determines whether a `StreamController` is involved at all:

| Stage | Type | Operator | Microtask overhead |
|---|---|---|---|
| 1, 4 | 1:N async | `asyncExpand` | O(shards) ≈ 50/cycle — negligible |
| 3, 7, 11 | CPU 1:1 | `stream.map()` | **Zero** — synchronous, no controller |
| 2, 5, 8, 12 | Concurrent I/O | Custom `StreamTransformer`, `sync: true` | 1/item at I/O→CPU boundary |
| 6, 9, 13 | Chunked I/O | Custom `StreamTransformer`, `sync: true` | 1/chunk |
| 10 | Boundary-reactive | Custom `StreamTransformer`, `sync: true` | 1/boundary |
| 14 | Orchestration | Direct listener on Stage 13 output | — |

**`stream.map()` for CPU stages** (3, 7, 11): `map` propagates synchronously in the same call stack — no controller, no microtask, zero overhead. There is no blocking risk: per `map` call, only ~7 µs of CPU work occurs (Jelly decode+merge+encode at Stage 7), well within Dart's event loop responsiveness budget. The 210k-microtask scenario only arises if CPU stages are (mis-)implemented with a `StreamController`.

**`sync: true` for custom `StreamTransformer`s** (Stages 2, 5, 6, 8, 9, 10, 12, 13): these stages emit results from within `async` continuations (after `await`). With `sync: true`, the downstream `onData` runs immediately in the same continuation — results flow directly into the next `stream.map()` without an extra microtask round-trip. Without it, each emission schedules an extra microtask before CPU work can start. At 15k items this is measurable; at 50 shards it is negligible.

**`inputController` stays `sync: false`**: added to from synchronous code at pipeline startup, and from the `onData` callback of the Feedback Stage's stream subscription (a synchronous listener context). Using `sync: true` there would fire the entire downstream pipeline synchronously in the caller's call stack, violating Dart's re-entrancy contract for stream listeners.

**SDK caveat for `sync: true`**: `controller.add()` must be the **last operation** in the async continuation — any code after `add()` runs concurrently with the listener's synchronous execution.

**Action**: Added to Design Principles in 007 as a mandatory implementation requirement; implementation form annotated in each stage table.

---

## 2. Back-pressure: Explicit Pool Pause Required

**Severity: Medium** — memory risk on the `localOnly` fast path; resolved by design decision.

**Root cause**: In the `localOnly` scenario (full local → remote), Stage 5 passes all 15,000 items through at memory speed. Without back-pressure, all 15,000 items pile up in Stage 8's pool queue, each carrying an encoded `RdfGraph` ≈ 10 KB → ~150 MB peak in-flight. Relying on network latency as an implicit rate limiter is not acceptable — the pipeline must also be correct against local-directory backends where network RTT is zero.

**Decision**: Concurrency pool `StreamTransformer`s (Stages 2, 5, 8, 12) **must** implement explicit pool-based back-pressure:
- When all N slots are occupied: call `subscription.pause()` — upstream stops emitting
- When a slot becomes free: call `subscription.resume()` — upstream continues

This bounds in-flight items at any pool to exactly N at any moment. The `pause()`/`resume()` signal propagates automatically through `stream.map()` and `asyncExpand()` stages upstream — no additional machinery needed in CPU or fan-out stages.

**Effect on memory**: peak in-flight for each pool stage = N items × ~10 KB = ~100 KB at N=10. Total across all four pools ≈ 400 KB — acceptable.

**Action**: Added to Design Principles in 007; pool stages document the pause/resume contract.

---

## 3. Stage 6 Batching ✅ Applied

Chunk size documented as 500 items per `getDocumentsByIri()` IN-query in Stage 6's Batching row.

---

## 4. Stage Merging Analysis

**Severity: Low** — no action required at target scale.

**Stages 3+4** (Shard Parse → Change Detection): strongest candidate. They always execute sequentially per shard — Stage 4 immediately consumes Stage 3's output. Separating them costs one stream emission per shard (~50 shards total). Overhead negligible. Keep separate for conceptual clarity.

**Stages 10+11** (Shard Entry Load → Shard CRDT Merge): same argument. One extra emission per `ShardComplete`. ~50 emissions total. Negligible.

**Conclusion**: No merges are necessary at target scale. The stream overhead for shard boundaries is negligible; the 15,000 resource items are where overhead matters, and that is governed by the `sync: true` requirement above.

---

## 5. IRI Warmup in Stage 1 ✅ N/A — superseded by ID pass-through

~~**Severity: Low** — optimization opportunity.~~

The IRI→ID cache and `Storage.warmupIriIds()` are **not needed** in this pipeline. Stage 1 already fetches the integer PK (`index_shards.id`) in its bulk query and attaches it to `ShardRef`. Downstream events (`SyncCandidate`, `FetchedCandidate`, `MergeResult`) propagate this ID through the pipeline. Stages 4, 6, and 9 use the integer ID directly — zero IRI→ID lookups, zero cache.

**Action**: Documented in Stage 1 as an "ID pass-through" note. `warmupIriIds()` must not be called in the pipeline.

---

## 6. Codec Performance Budget (from BENCHMARKS.md)

Benchmarks from `locorda_rdf` (JIT; AOT comparable or faster for encoding). Informs the 3 s performance target already documented in 007.

**Individual resource decode** (~20 triples, `small` benchmark row):

| Format | µs/triple | 15k × 20 triples |
|--------|-----------|------------------|
| Turtle | 4.96 µs   | ~**1.5 s**       |
| Jelly  | 0.37 µs   | ~**110 ms**      |

→ 14× speedup on the Stage 4 decode path. With Jelly the codec is no longer a bottleneck.

**Shard decode** (`large` dataset benchmark, 34.3k quads, ≈ upper-bound shard):

| Format | Decode time | Relative |
|--------|------------|----------|
| TriG   | 168 ms     | 100%     |
| Jelly  | **19 ms**  | **11%** — 9× faster |

A realistic shard (1–2k quads) costs ~0.55–1.1 ms with Jelly; 100 shards ≈ **55–110 ms total**.

**Encode budget** for Stage 7/11 pre-encoding (µs/triple, `small` row):

| Format | µs/triple | 20-triple resource | 15k resources total |
|--------|-----------|-------------------|---------------------|
| Jelly  | 0.89 µs   | ~18 µs            | **~270 ms**         |
| Turtle | 1.72 µs   | ~34 µs            | ~510 ms             |

Pre-encoding is cheap. The Jelly zero-copy shortcut (`encodedForDb` = `encodedForUpload` when both use Jelly) eliminates this cost entirely when DB and upload format match.

**Scaling characteristics** (decode, Large/Small ratio):

| Format  | Ratio  | Assessment |
|---------|--------|------------|
| N-Quads | 2.18×  | super-linear — unsuitable for large shards |
| JSON-LD | 15.24× | catastrophic — rules out for shards |
| TriG    | 0.98×  | linear |
| Jelly   | 1.37×  | sub-linear — best at scale |

Only TriG and Jelly scale acceptably. Jelly is the clear winner for shard-heavy workloads. Supports the `preferredUploadContentType` decision in OQ5.

---

## 7. Three Issues Found in Pass 2 Review

### C3 — Pool Stages Must Buffer Boundary Events (Correctness)

**Severity: High** — ordering invariant breaks if boundaries are forwarded while I/O slots are occupied.

DP8 documents the `pause()/resume()` back-pressure contract but does not cover what happens when a `ShardComplete` or `PhaseComplete` arrives at a pool stage while I/O slots are still occupied.

**Problem**: A `ShardComplete(A)` that reaches Stage 5 while downloads for shard A's candidates are still in-flight would be forwarded before those downloads complete. Downstream, Stage 10 would read `getActiveIndexEntriesForShard(A)` before Stage 9 has committed those resources — `index_entries.clockHash` values would be stale, causing spurious `conflictCandidate` classifications on the next sync cycle.

**Required rule**: Pool stages (2, 5, 8, 12) must treat boundary events as **flush points**: when a boundary is dequeued from the input, it is buffered until all previously-dispatched in-flight operations have completed and emitted their results; only then is the boundary forwarded downstream.

**Action**: Added to DP8 in 007.

---

### E1 — `ShardComplete` Dart Code Invalid (Syntax Bug)

**Severity: Low** — spec illustration only, but invalid Dart misleads implementers.

```dart
class ShardComplete extends Boundary {
  ...
  const ShardComplete(this.shardIri, this.shardStorageId, {this.remoteShardGraph});
  final String? newEtag;  // ← declared after constructor, NOT in constructor params
}
```

`final` fields of a `const` class must all be initialized in the constructor. `newEtag` is not listed in the constructor → invalid Dart.

**Fix**: move `newEtag` declaration before the constructor; add `this.newEtag` as a named parameter.

**Action**: Fixed in `ShardComplete` Dart block in 007.

---

### E2 — Batch-Size Inconsistency (DP1 and Summary Table)

**Severity: Low** — cosmetic; stage descriptions are already correct.

Stage 9 and 13 descriptions say `500 items/shards per transaction`. DP1 and the Summary Table rows for Stage 9 and 13 still say `500–2000`.

**Action**: DP1 and Summary Table rows 9 and 13 updated to `500` in 007.

---

## Summary

| Concern | Severity | Action |
|---|---|---|
| `sync: true` for CPU stage `StreamController`s | **High** — measurable at 15k items | Add to Design Principles as mandatory requirement |
| Back-pressure design | **Medium** — memory risk | Document rate-limiter model or add explicit `pause()` design |
| Stage 6 chunk size unspecified | **Medium** | Document 500/batch IN-query chunking |
| Stage merging | **Low** — no action needed | No merges necessary at target scale |
| IRI warmup in Stage 1 | **N/A** | Superseded by ID pass-through — `warmupIriIds()` not needed |
| Codec performance budget | Informational | See §6; supports 3 s target and OQ5 format choice |
| C3: Pool stages must buffer boundary events | **High** — ordering invariant | Added to DP8: boundaries held until pool drains |
| E1: `ShardComplete` constructor missing `newEtag` | **Low** — invalid Dart | Fixed: `newEtag` moved into constructor params |
| E2: Batch-size inconsistency (DP1 + Summary Table) | **Low** — cosmetic | DP1 and Summary Table rows 9 + 13 updated to `500` |
