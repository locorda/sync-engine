# 025 — Backend-Controlled Physical Layout

**Status**: Draft
**Created**: 2026-03-01
**Updated**: 2026-03-16
**Depends on**: 024 (Three-Phase Sync Architecture)
**Context**: After three-phase sync (024) fixes execution order and parallelism, further gains come from letting backends aggregate logical shards into fewer physical files — without changing the logical index/shard model.

## Strategic Context (026)

This proposal complements `026-recap-sync-direction.md` and builds on `024`:

- The logical index/shard model stays unchanged. There is **one** model, not two profiles.
- **024** fixes how shards are processed (parallel I/O, bulk commit).
- **025** fixes how backends map logical shards to physical files.
- The existing `_ShardSyncAdapter` abstraction is the right extension point.

---

## Problem Statement

After 024, all shard downloads and uploads happen in parallel with a single DB commit. But the file count per sync cycle remains high:

### File Count Analysis (Chat Essence)

| Category | Files |
|---|---|
| GroupIndex shards (SyncChatMessage) | 62 |
| GroupIndex shards (SyncMessageGroup) | 62 |
| FullIndex shards (SyncKeyword, etc.) | ~5–10 |
| Index metadata documents | ~128 |
| Infrastructure (ClientInstallation, etc.) | ~5 |
| **Total** | **~263** |

For the Dir backend, parallelized local file I/O makes 263 files manageable. For remote backends (GDrive, Solid, WebDAV), each file means an HTTP request — parallelism helps but can't eliminate per-request latency overhead.

### The Key Insight

The orchestrator works with **logical shards**. How those shards map to physical files is a backend concern. Currently, `_ShardSyncAdapter` has two implementations:

- `FilePerResourceShardSyncAdapter`: 1 document = 1 file (Linked Data mode)
- `FilePerShardShardSyncAdapter`: 1 shard's documents = 1 TriG dataset file

Both still produce one physical I/O operation per logical shard. A backend like GDrive could aggregate multiple logical shards into fewer physical files, dramatically reducing HTTP round-trips.

---

## Proposal: Extend `_ShardSyncAdapter` for Bulk Physical Layout

### Core Idea

The orchestrator continues to think in terms of logical shards. The `_ShardSyncAdapter` interface gains the ability to **aggregate** multiple shards into physical storage units at the backend's discretion.

### How It Works

1. **Orchestrator** (after 024) collects all shard download/upload specs in Phase 1/3.
2. **Backend adapter** receives the full list of shard specs and decides how to map them to physical files.
3. **Download**: Backend reads physical files, splits them back into per-shard data, returns logical shard contents.
4. **Upload**: Backend receives per-shard data, aggregates into its preferred physical layout, writes.

### Interface Evolution

```dart
/// Current interface (simplified):
abstract class _ShardSyncAdapter {
  Future<ShardData> downloadShard(ShardSpec spec);
  Future<void> uploadShard(ShardSpec spec, ShardData data);
}

/// Extended interface — backends can override bulk operations:
abstract class _ShardSyncAdapter {
  /// Download a single shard (default path, used by Dir backend).
  Future<ShardData> downloadShard(ShardSpec spec);

  /// Download multiple shards in bulk.
  /// Default: delegates to downloadShard() individually.
  /// Override: backend can read fewer physical files and split results.
  Future<Map<ShardSpec, ShardData>> downloadShards(List<ShardSpec> specs) async {
    return {for (final spec in specs) spec: await downloadShard(spec)};
  }

  /// Upload a single shard (default path).
  Future<void> uploadShard(ShardSpec spec, ShardData data);

  /// Upload multiple shards in bulk.
  /// Default: delegates to uploadShard() individually.
  /// Override: backend can aggregate into fewer physical files.
  Future<void> uploadShards(Map<ShardSpec, ShardData> shards) async {
    for (final entry in shards.entries) {
      await uploadShard(entry.key, entry.value);
    }
  }
}
```

### Per-Backend Strategies

| Backend | Download Strategy | Upload Strategy | Physical Files |
|---|---|---|---|
| **Dir** | Parallel file reads (024) | Parallel file writes | 1 per shard (unchanged) |
| **GDrive** | Batch API or aggregated files | Batch API or aggregated files | Configurable (1 per type, or fewer aggregated files) |
| **Solid** | Parallel GETs; future bulk endpoints | Parallel PUTs; future bulk endpoints | 1 per shard or per resource (Linked Data) |
| **WebDAV** | Parallel GETs | Parallel PUTs | 1 per shard (unchanged) |

---

## GDrive: Aggregated Shard Files

For GDrive, the adapter could aggregate all shards of a resource type into a single physical TriG dataset file:

### Physical Layout Example (Chat Essence on GDrive)

```
locorda/chat_essence/
├── SyncChatMessage.trig        # All 62 ChatMessage shards in one file
├── SyncMessageGroup.trig       # All 62 MessageGroup shards in one file
├── SyncKeyword.trig            # All Keyword shards in one file
├── ClientInstallation.trig     # Infrastructure
└── ...                         # ~10–15 physical files total
```

Each physical file contains multiple Named Graphs (one per logical shard). The shard structure is preserved within the file — the backend simply packs/unpacks shards from the physical container.

```trig
# SyncChatMessage.trig — contains all 62 logical shards

# Shard metadata (which shards are in this file, their clock hashes)
<> a idx:AggregatedShardFile ;
   idx:containsShard <shard/0>, <shard/1>, ... <shard/61> .

<shard/0> { 
    # All resources belonging to shard 0
    <chat-message/msg-001#it> a chat:ChatMessage ; ... .
    <chat-message/msg-042#it> a chat:ChatMessage ; ... .
}

<shard/1> {
    # All resources belonging to shard 1
    ...
}
```

### Change Detection

- Per-file ETag/hash detects whether the aggregated file has changed.
- Inside the file, per-shard clock hashes enable skipping unchanged shard data during merge (Phase 2).
- The backend downloads the full file but the orchestrator merges only changed shards — same as today.

### Result: HTTP Round-Trips

| Scenario | Current (263 files) | After 024 (parallel) | After 024 + 025 (aggregated) |
|---|---|---|---|
| Initial sync downloads | 263 sequential | 263 parallel | ~10–15 parallel |
| Incremental sync downloads | scan all shards | scan all shards (parallel) | download changed type files |

---

## Dir Backend: Minimal Changes

The Dir backend already performs well with parallel local file I/O (after 024). Aggregation is **not needed** for local filesystems — the overhead per file is ~1ms.

The Dir adapter uses the default `downloadShards`/`uploadShards` implementation (delegating to individual shard operations) with parallelism from 024.

---

## Solid Backend: Linked Data Preservation

For Solid, the adapter continues to use per-resource or per-shard files to preserve Linked Data discoverability. If Solid Community Server adds bulk endpoints (on their roadmap), the adapter can implement `downloadShards`/`uploadShards` using those endpoints without changing the logical model.

---

## Open Questions

### 1. Granularity of Aggregation

**Question**: Should aggregation always be per-type, or should backends choose?

**Assessment**: Leave it to the backend. A simple GDrive backend might start with one file per type. A more sophisticated version might split very large types into size-based chunks. The `_ShardSyncAdapter` interface doesn't prescribe aggregation granularity.

### 2. Concurrent Write Conflicts on Aggregated Files

**Question**: Two installations modify different shards of the same type → both upload the same aggregated file.

**Assessment**: Same mitigations as today:
- **ETags** detect the conflict.
- **Re-download, re-merge, re-upload** resolves it.
- **CRDT semantics** guarantee eventual convergence regardless.
- **Scale reminder**: 2–20 installations, low conflict probability.

### 3. Partial Sync / onRequest with Aggregated Files

**Question**: GroupIndex `onRequest` fetch policy expects to download individual shards. How does this work with aggregated files?

**Assessment**: Two options:
- **No onRequest for aggregated backends**: GDrive always uses prefetch. Aggregated files contain all shards — there's nothing to lazily fetch.
- **Backend decides**: A backend that supports fine-grained access (Solid) uses per-shard layout; a backend that doesn't (GDrive) uses aggregation. The fetch policy is a logical concern; physical layout adapts to what the backend can do.

### 4. Changelog-Based Incremental Sync (GDrive Future)

**Question**: GDrive has a Changes API. Could a future GDrive adapter skip the "download and compare" step?

**Assessment**: Yes. A changelog-based adapter could:
1. Query GDrive Changes API for modified files since last sync.
2. Download only those files.
3. Merge only changed shards within those files.

This is a backend-specific optimization that fits cleanly into the `downloadShards` interface — the orchestrator doesn't need to know how the backend detected changes.

### 5. Memory Pressure for Large Aggregated Files

**Question**: Loading all shards of a type into memory for packing/unpacking.

**Assessment**: For Chat Essence (~2015 resources × ~1–2 KB = ~2–4 MB), well within limits. For very large types, the backend could split into multiple physical files (e.g., by shard range). The orchestrator remains unaware of this detail.

---

## Expected Impact

### Performance (Initial Sync, Chat Essence, GDrive Backend)

| Metric | Current | After 024 only | After 024 + 025 |
|---|---|---|---|
| HTTP requests (download) | 263 sequential | 263 parallel | ~10–15 parallel |
| HTTP requests (upload) | 263 sequential | 263 parallel | ~10–15 parallel |
| Per-request latency | ~200ms × 263 | ~200ms (amortized via parallelism) | ~200ms × ~12 |
| DB commits | 124 | 1 | 1 |
| **Estimated total (GDrive)** | **minutes** | **~30–40s** | **~5–10s** |

### Dir Backend: No Additional Impact Beyond 024

For Dir, 024's parallelism and bulk commit already bring the main gains. 025 is not needed for local filesystems.

### Code Complexity

| Aspect | Impact |
|---|---|
| Logical model | **No change** — indices, shards, groups unchanged |
| Orchestrator | **Minimal change** — calls bulk adapter methods instead of per-shard |
| `_ShardSyncAdapter` | **Extended** — bulk methods with default sequential fallback |
| New code | **Per-backend** — each backend implements its aggregation strategy |
| Existing adapters | **Unchanged** — default implementations preserve current behavior |

---

## Relationship to Other Proposals

- **024 (Three-Phase Sync)**: Prerequisite. Provides the phase separation that makes bulk adapter operations possible. 024 alone gives ~2× improvement; 025 on top gives the additional reduction in HTTP round-trips.
- **026 (Recap Sync Direction)**: Defines the strategic direction — one model, fix execution, let backends optimize physical layout.
- **015 (Shard-Level File Consolidation)**: Introduced dataset-mode shards (one TriG file per shard). This proposal extends the idea: backends can aggregate multiple shards into one file.
- **014 (GDrive Sync Performance)**: Identified HTTP latency as bottleneck. Backend-controlled aggregation addresses this by reducing request count.

---

## Next Steps (if approved)

1. **Implement 024 first** — three-phase sync is the foundation.
2. **Add bulk methods to `_ShardSyncAdapter`** — `downloadShards`/`uploadShards` with default sequential fallback.
3. **Update `RemoteSyncOrchestrator`** — call bulk methods from three-phase flow.
4. **Implement GDrive aggregation adapter** — pack/unpack shards into per-type physical files.
5. **Benchmark** — measure actual improvement with Chat Essence on GDrive.
6. **Evaluate changelog optimization** — prototype GDrive Changes API integration.
