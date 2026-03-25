Here's a thorough analysis:

---

## 1. The Core Dart-Specific Risk: Stream Overhead

This is the design's biggest latent problem. **Dart async streams are not zero-cost.** Each `streamController.add()` schedules a microtask — a round-trip through the event loop microtask queue. With 14 `StreamTransformer`s and 15,000 items:

$$14 \times 15{,}000 = 210{,}000 \text{ microtask enqueue/dequeue cycles}$$

This is pure overhead — no useful work done. In a tight sync of 15,000 items, this is measurable wall time, not noise.

**Mitigation**: Use `sync: true` on `StreamController`s inside *CPU* stages (3, 7, 11). A `sync: true` controller calls listeners synchronously on `add()`, so an event propagates through adjacent CPU stages in a single call stack without yielding to the microtask queue. I/O stages must remain async (because they *need* to yield — that's how Dart's async I/O concurrency works). The practical result: CPU-to-CPU event passing is free; I/O-to-CPU or CPU-to-I/O yields once.

The document should call this out explicitly — it's not a micro-optimisation, it's correctness of the performance model.

---

## 2. Many Async Tasks — Is it a Problem?

Yes, but not the way it might seem. Dart is single-threaded; "async tasks" don't run in parallel. The real cost is **event loop round-trips per item**. Each `await`/`yield`/`StreamController.add()` is a scheduling point. For the pass-through CPU stages (e.g., Stage 7 passing a `ShardComplete` through), you pay the scheduling cost for zero I/O benefit.

The concurrency model only pays off at I/O stages: while Stage 8 is awaiting N HTTP responses concurrently, Stage 7 can process the next batch. But between sequential CPU stages (3→4, 7→8 pass-through), the async overhead has no corresponding concurrency benefit.

**Recommendation to add**: Note explicitly that CPU stage `StreamController`s must use `sync: true`. If a CPU stage only passes boundaries through (e.g., Stage 7 passing `ShardComplete` downstream), that passthrough should be synchronous.

---

## 3. Back-pressure: Not Addressed

Dart streams support `pause`/`resume`, but composing `StreamTransformer` chains that correctly propagate back-pressure is non-trivial. The document doesn't address this.

**Risk**: If Stage 5 passes 15,000 `localOnly` items through at memory speed (no I/O delay), they flood Stage 6's input buffer. Stage 6 then floods Stage 7, etc. Nothing upstream slows down. In the worst case, all 15,000 items are simultaneously in-flight in the pipeline, each holding an `RdfGraph` ≈ 10KB → ~150MB of in-flight data.

The I/O-chunked stages (2, 5, 8) self-limit naturally because they `await` concurrency slots. But pure pass-through paths have no back-pressure.

**Recommendation**: Either (a) add explicit `pause()` propagation design, or (b) accept that the chunked I/O stages are the natural rate limiters and document that CPU stages are not independently bounded.

---

## 4. Performance Target: Full Initial Sync Against a Local Directory Backend

~~*Original concern: network RTT would make 3 s impossible for a full initial sync. Resolved: see below.*~~

The 3-second target is explicitly for a **full initial sync** (empty local ← full remote, or full local → empty remote) against a **local directory backend** where network RTT is zero. The earlier RTT-based calculation does not apply here. The real bottleneck is **disk I/O + CPU**, and 3 s is a realistic target for that scenario.

For a real network backend (Solid Pod over HTTPS) the bottleneck shifts entirely to network I/O and the 3 s figure does not apply — that is a separate dimensioning problem.

**CPU budget sanity check with Jelly codec** (see §10 below):
- Decode 15k resources × ~20 triples: ~**110 ms**
- Decode ~100 shards (1–2k quads each): ~**55–110 ms**
- Encode 15k resources for DB + upload (Jelly): ~**270 ms**
- Total codec CPU: **~435–490 ms** — well under 1 s

This leaves ~2.5 s for SQLite batch writes and local file I/O, which is achievable with the chunked batch strategy (Stage 9: 500–2000 per transaction).

---

## 5. ~~Missing:~~ `index_entries` clockHash Update in Stage 9 — **Already Correctly Implemented**

~~*Original concern: `index_entries` may hold a stale clockHash after a CRDT merge, triggering spurious `conflictCandidate` on the next cycle.*~~

**Verified against existing codebase: Option A is already exactly what the code does.**

The existing `_commitBatchChunk()` method in `remote_sync_orchestrator.dart` commits both `documents` and `index_entries` in a single `inTransaction()` call. The clockHash written to `index_entries` is extracted from the **post-merge** document's `sync:crdtClockHash` literal (via `IndexManager.prepareIndexEntryWrites()`), not from the original shard parse. The update is fully batched: a `_DeferredBatchCommit` record collects `saveRequests` (documents) and `indexEntryRequests` side-by-side, flushed together in chunks of up to 2000 items.

Key files:
- `remote_sync_orchestrator.dart` — `_commitBatchChunk()` wraps both writes in `inTransaction()`; `_DeferredBatchCommit` typedef bundles `saveRequests + indexEntryRequests`
- `index_manager.dart` — `prepareIndexEntryWrites()` extracts the post-merge clockHash from the merged document
- `drift_storage.dart` — `saveIndexEntries()` delegates to `IndexDao.saveIndexEntriesBatch()` (batch insert/replace, chunk-safe)

**Action for the proposal**: Stage 9 should explicitly document that `index_entries` is updated in the same batched transaction as `documents`, using the post-merge clockHash. This is not an _additional_ step but a natural consequence of the `_DeferredBatchCommit` pattern that must be preserved when re-implementing Stage 9 in the new pipeline.

---

## 6. Stage 6 Batching Unspecified

For the "full local → remote" scenario, all 15,000 items are `localOnly`, so Stage 5 passes through and Stage 6 must load all 15,000 documents from DB. "Chunked DB reads" is stated but not specified. Should use `getDocumentsByIri()` with chunked IN-queries (e.g., 500 per query). This is analogous to Stage 9's 500–2000 per transaction and should be documented at the same level.

---

## 7. Should Any Stages be Merged?

**Stages 3+4** (Shard Parse → Change Detection): strongest candidate. They always execute sequentially per shard — Stage 4 immediately consumes Stage 3's output for the same shard. Separating them costs one stream emission per shard (cheap at ~50 shards, negligible). Keep separate for the conceptual clarity.

**Stages 10+11** (Shard Entry Load → Shard CRDT Merge): same argument. One stream emission per `ShardComplete`. ~50 shards = 50 extra emissions. Negligible. Worth keeping separate.

**No merges are necessary** at the target scale. The stream overhead for the ~50 shard boundaries is negligible; the 15,000 resource items are where the overhead matters, and those are governed by the `sync: true` fix above.

---

## 8. Missing: IRI Warmup in Pipeline Startup

`Storage.warmupIriIds()` exists but isn't called in the pipeline. Stage 1 processes all index IRIs and shard IRIs upfront. Warming up the IRI→ID cache at Stage 1 time (before Stages 4, 6, 9 need them) would eliminate repeated lookups in those stages. One call at the start of Stage 1, passing all resolved shard IRIs, costs one isolate round-trip in exchange for eliminating per-item lookups in downstream DB stages.

---

## 9. Design Principle 4 Needs Update

> "All decoding/encoding happens in CPU stages (3, 7)"

Stage 11 is also a CPU stage doing encoding. Should read "CPU stages (3, 7, 11)".

---

## 10. Codec Performance Budget (from BENCHMARKS.md)

Benchmarks from `locorda_rdf` (JIT; AOT comparable or faster for encoding):

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

**Implication for format choice**: Only TriG and Jelly scale acceptably. Jelly is the clear winner for any shard-heavy workload. The `preferredUploadContentType` decision in OQ5 is strongly supported by these numbers.

---

## Summary

| Concern | Severity | Action |
|---|---|---|
| `sync: true` for CPU stage `StreamController`s | **High** — measurable at 15K items | Add to design as mandatory requirement |
| Back-pressure design | **Medium** — memory risk | Document the rate-limiter model or add explicit pause design |
| `index_entries` clockHash update | ~~**High** — correctness bug~~ **Resolved** | Already correct: existing `_commitBatchChunk()` atomically writes docs + `index_entries` with post-merge clockHash, batched up to 2000/chunk. Stage 9 must document this invariant. |
| Stage 6 batching unspecified | **Medium** | Document chunk size (500/batch) |
| Performance target scope | ~~Medium~~ **Resolved** | 3s = full initial sync against local dir backend; network backend is out of scope for this target — updated in document |
| IRI warmup in Stage 1 | **Low** | Note as optimization opportunity |
| Design Principle 4 wording | **Low** | Add Stage 11 to the list |

----
