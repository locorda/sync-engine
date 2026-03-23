# Streaming Sync Pipeline — Proposal Overview

## Problem

Syncing ~15,000 resources (Chat Essence app) takes ~18 seconds in either direction:
- **Empty local ← full remote**: User installs on new device, syncs existing data down
- **Full local → empty remote**: User imports data (e.g., Matrix message exports), pushes to remote for the first time

Both are critical first-run experiences and equally unacceptable for a good UX.

## Root Causes

The current architecture is **sequential at every level**: sequential file I/O, sequential resource processing, sequential phase execution, with concurrency explicitly disabled due to unresolved test failures. Additionally, the pipeline treats both sync directions identically — performing redundant downloads (15K 404s when pushing to empty remote) and redundant uploads (when pulling from remote that already has the data).

## Proposal Documents

| # | Document | What it covers |
|---|----------|---------------|
| [001](001-performance-analysis.md) | **Performance Analysis** | Deep analysis of current architecture, bottleneck identification, estimated time breakdown |
| [002](002-streaming-sync-architecture.md) | **Streaming Sync Architecture** | Core design: 4-stage pipeline (Source → Merge → Commit → Finalize) with fast paths |
| [003](003-implementation-plan.md) | **Implementation Plan** | Phased rollout from quick wins to full streaming, dependency graph, effort estimates |
| [004](004-interface-design.md) | **Interface Design** | Exact Dart interfaces, data types, pipeline orchestrator, testing strategy |
| [005](005-dataset-mode-optimization.md) | **Dataset Mode Optimization** | Specialized optimizations for shard-dataset mode (bulk files), byte pass-through |
| [006](006-quick-wins.md) | **Quick Wins** | Immediate improvements to existing code (concurrent I/O, fast paths, profiling) |

## Key Design Decisions

1. **Streaming, not batching**: Resources flow through the pipeline continuously, not as collected batches at phase boundaries
2. **Fast paths for common cases**: Initial sync (100% accept-remote) and no-conflict sync skip expensive CRDT merge
3. **Parallel I/O with backpressure**: Multiple concurrent downloads/uploads with natural Dart Stream backpressure
4. **Incremental adoption**: New pipeline coexists with old as alternative implementation, validated by comparing outputs

## Expected Impact

| Scenario | Current | After Quick Wins | Full Streaming |
|----------|---------|-----------------|----------------|
| 15K pull to empty local (dir) | ~18s | ~3-5s | ~2-3s |
| 15K push to empty remote (dir) | ~18s | ~3-5s | ~2-3s |
| 15K initial sync (dataset) | ~12s | ~4-6s | ~2-3s |
| Incremental sync (100 changed) | ~3s | ~1-2s | <1s |

## Relationship to Prior Work

These proposals build on the conclusions from the existing `proposed-changes/` directory:

- **026-recap-sync-direction.md**: Already concluded the problem is **execution, not architecture** — our proposals are fully aligned, proposing execution improvements within the existing logical index/shard model
- **024-three-phase-sync-architecture.md**: Established the three-phase approach we extend into a streaming pipeline
- **015-file-aggregation-for-performance.md**: Dataset mode (`FilePerShardShardSyncAdapter`) — we propose streaming optimizations on top
- **016-more-performance-improvements.md**: Documented the 4.5s GDrive mirror / 25s GDrive normal / 7-22s Solid benchmarks that motivate this work

The logical shard/index model is preserved. All proposed changes are in the **execution layer**.

## Recommended Approach

1. Start with **Quick Wins** (document 006) — high impact, low risk
2. Implement **Fast Path Merge** (Phase 2 of 003) — biggest single improvement
3. Build **Streaming Pipeline** (Phases 3-5) — if needed after quick wins
4. **Dataset Optimizations** (005) — for production backends (GDrive)
