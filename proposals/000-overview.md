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
| [007](007-two-pass-sync-pipeline.md) | **Feedback-Loop Sync Pipeline** | Authoritative pipeline design: 14-stage streaming pipeline with feedback loop, backend storage modes, boundary elements |
| [008](008-implementation-plan.md) | **Implementation Plan** | Phased rollout: IoGI first, then thin-slice pipeline, backend interfaces, testing strategy |

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

See [008 — Implementation Plan](008-implementation-plan.md) for the phased rollout.
