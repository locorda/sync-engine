
# 026 - Recap Sync Direction

**Status**: Decision
**Created**: 2026-03-09
**Updated**: 2026-03-16
**Related**: 024 (Three-Phase Sync Architecture), 025 (Backend-Controlled Physical Layout)

## Problem Statement

Locorda has reached a strategic turning point:

- The API and core sync semantics are good.
- The current execution is too slow for real use.
- This is true even on local directory backend for chat-essence-scale data.

So performance is not an optional improvement. It is a product requirement.

### Root Cause Analysis

The performance problem is **not** in the logical index/shard model itself. It is in how the model is executed:

1. **Sequential per-shard processing**: Each shard is downloaded, merged, uploaded, and committed individually. 124 shards × ~120ms = 15s just for shard finalization.
2. **Per-shard DB commits**: 124 separate SQLite transactions where 1 would suffice.
3. **No I/O parallelism**: Downloads and uploads happen one at a time.
4. **Serialization overhead**: Every shard is fully re-serialized even when only one document changed.

The logical shard/index model provides real value: partitioning for large types, change detection via clock hashes, partial sync via group indices. These are not the bottleneck and should not be discarded.

## Decision

Adopt a **performance-first execution strategy within the existing logical model**, with backend-controlled physical file layout.

1. **Keep the logical index/shard model** — it provides partitioning, change detection, and partial sync capabilities that are genuinely needed (especially for types that grow large, like chat messages).
2. **Fix the execution** (024) — three-phase sync with parallel I/O and bulk DB commits. This is the primary performance lever.
3. **Let backends control physical file layout** (025) — the orchestrator works with logical shards; the backend decides whether each logical shard maps to a physical file, whether multiple shards are packed into fewer files, or whether everything goes into a single file.
4. **No multi-profile architecture** — one model, one orchestrator, one API. The backend adapter is the only variation point.

## Why This Direction

### 1. The performance problem is execution, not architecture

The measured 54s sync time breaks down into sequential I/O (download/upload per shard) and per-shard DB commits. Parallelizing I/O and batching commits addresses the bulk of it without touching the data model.

### 2. "One file per type" is a dead end

A naive flat-file approach (one file per resource type) fails for types that grow large. Chat Essence has 10,000+ messages — all one type. A single file per type would be 10-20 MB and growing. At some point you need to split it, and then you are re-inventing shards. Better to keep the existing shard infrastructure and fix the execution layer on top of it.

### 3. Multi-profile is YAGNI

The previous version of this document proposed two storage profiles (Dataset/Flat vs. Linked-Data). Analysis shows this would mean:
- Two orchestrator code paths to maintain and test
- Profile migration tooling
- Doubled complexity for a feature whose "flat" profile would eventually need partitioning anyway

The existing `_ShardSyncAdapter` abstraction already separates logical from physical: `FilePerResourceShardSyncAdapter` (1 file per document) vs. `FilePerShardShardSyncAdapter` (all documents of a shard in one TriG dataset). This is the right extension point — not a second orchestrator.

### 4. No cloud storage API solves the many-small-files problem

Research shows that no consumer cloud storage (Google Drive, OneDrive, Dropbox, S3) has APIs suited for many small files. Dropbox has batch upload sessions, but is the exception. The universal recommendation from all providers is **client-side file aggregation** — which is exactly what the `FilePerShardShardSyncAdapter` already does at shard level.

The logical-to-physical mapping via `_ShardSyncAdapter` lets each backend choose its aggregation strategy without changing the sync model.

### 5. Solid bulk endpoints are on the roadmap

The Solid Community Server has bulk upload/download on their TODO list. If those materialize, a Solid backend could implement `downloadManyDatasets`/`uploadManyDatasets` as actual bulk operations. The three-phase architecture (024) makes this a clean backend-level change. Designing the Dir backend cleanly now (with efficient per-file I/O) means the same logical model works with Solid bulk endpoints when available.

## Option Review (Updated)

### Opt 1: Give up

Rejected.

### Opt 2: Radical single-file + changelogs only

Rejected as primary strategy. Throws away the index/shard model that solves real partitioning needs. For types with unbounded growth (chat messages), you need partitioning. Building a changelog system adds complexity comparable to what we already have.

However: A backend *could* implement this under the `_ShardSyncAdapter` abstraction — packing all shards into one physical file with per-installation changelogs. This is a backend implementation detail, not an architectural change.

### Opt 3: Fix execution within current model (024)

**Selected as primary strategy.** Three-phase sync with parallel I/O and bulk DB commits. Preserves the logical model, fixes the execution bottleneck.

### Opt 4: Multi-profile (previous version of this document)

Rejected. YAGNI. Doubles complexity for a "flat" profile that would eventually need partitioning anyway. The `_ShardSyncAdapter` provides the necessary variation point at backend level without a second orchestrator.

### Opt 5: Backend-controlled physical layout (025, revised)

**Selected as secondary strategy.** Extend `_ShardSyncAdapter` so backends can aggregate multiple logical shards into fewer physical files. This is an incremental optimization on top of 024, not a separate architecture.

## Consequences

### What we keep

- Offline-first CRDT sync.
- User-owned storage model.
- The full index/shard model (FullIndex, GroupIndex, ShardDeterminer, etc.).
- One developer-facing API, one orchestrator, one code path.

### What we fix

- Sequential per-shard execution → three-phase parallel execution (024).
- Per-shard DB commits → single bulk commit.
- 1:1 logical-to-physical file mapping → backend-controlled aggregation (025).

### What we drop

- Multi-profile concept (Dataset/Flat vs. Linked-Data).
- `StorageMode` enum / profile switching / migration tooling.
- `FlatFileSyncOrchestrator` (proposed in previous 025 version).
- Any notion of a separate "flat file" sync path.

### What we defer

- Solid support: blocked by Solid's per-resource HTTP overhead. Viable when Solid gets bulk endpoints.
- Changelog-based incremental sync: a backend-level optimization that can be added later without architectural changes.

## Execution Plan

1. **Phase A (024)**: Three-phase sync within existing orchestrator.
	- Separate download, merge, upload/commit phases.
	- Parallelize downloads and uploads via `downloadMany`/`uploadMany`.
	- Collapse per-shard `commitDeferredBatch` into a single bulk commit.
	- Benchmark on Dir backend with Chat Essence.
	- **Target**: Dir initial sync from ~54s to <15s.

2. **Phase B (025)**: Backend-controlled physical layout.
	- Extend `_ShardSyncAdapter` to support bulk shard operations (backend receives all shard data, decides physical layout).
	- GDrive backend: pack multiple shards into fewer physical files.
	- Dir backend: likely no change needed (local file I/O is cheap after parallelization).
	- **Target**: GDrive initial sync acceptable for real use.

3. **Phase C**: Optimize merge performance.
	- Profile CRDT merge CPU time (~15s for 2015 docs) — is this reducible?
	- Optimize serialization (avoid re-serializing unchanged shards).
	- Consider streaming merge for very large types.

## Benchmark Gates

Before declaring each phase complete:

1. **024**: Dir initial sync under 15s for Chat Essence scale. Incremental sync under 2s.
2. **025**: GDrive initial sync under 30s for Chat Essence scale.
3. CRDT convergence checks after partial upload failures and retries.
4. No regression in existing test suite.

## Final Position

The logical index/shard model is sound. The execution is the problem.

Fix the execution. Let backends control the physical layout. One model, one path, no unnecessary abstractions.

**Direction**: performance-first execution, keep the canonical sync model, backend-controlled physical aggregation.
