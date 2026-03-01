# 024 — Flat File Storage Architecture

**Status**: Draft  
**Created**: 2026-03-01  
**Context**: Initial sync takes ~48–54s for Chat Essence app (2015 messages, 62 group shards × 2 types = 124 shard operations, 263 files total). Root cause is excessive file count and sequential per-shard overhead.

---

## Problem Statement

### Measured Performance (Chat Essence, Dir Backend, Initial Sync)

```
syncFunction                          53,985 ms
├── sync.metaPhase                       737 ms
├── sync.contentPhase                 53,098 ms
│   ├── content.collectSpecs              57 ms
│   ├── content.groupIndexBatch          478 ms  (128 GroupIndex entries)
│   ├── content.shardPhase            27,382 ms  (SyncChatMessage, 62 shards)
│   ├── content.shardPhase            15,664 ms  (SyncMessageGroup, 62 shards)
│   ├── content.shardPhase             1,672 ms  (SyncKeyword, 1 shard, 2015 docs)
│   └── ... (remaining types)
```

### Per-Shard Breakdown (typical shard, ~20–50 docs)

| Step | Duration |
|---|---|
| `shard.buildQueue` | 5–10 ms |
| `shard.syncDocsBatch` | 15–50 ms |
| `finalize.getFinalEntrySet` | 5–16 ms |
| `finalize.buildShardGraph` | < 5 ms |
| `finalize.generateMetadata` | < 5 ms |
| **`finalize.applyAndStore`** | **86–114 ms** (includes upload) |
| `finalize.commitBatch` | 6–28 ms |
| **`shard.finalize` total** | **99–136 ms** |

### Root Causes

1. **Too many files**: 263 files for one application with ~2000 documents is disproportionate.
2. **Fixed per-shard overhead**: Even tiny shards (3–7 docs) cost ~100ms for finalize (dominated by `applyAndStore` = serialize + upload).
3. **Sequential processing**: 124 shards processed one after another. At ~120ms each, that alone is ~15 seconds of pure sequential overhead.
4. **Structural overhead**: Each shard produces a separate file. The shard itself is a metadata document wrapping a handful of actual data documents.
5. **commitBatch scales with count**: The deferred DB commit after each shard costs 6–162ms depending on doc count.

### The Core Question

Is the Solid-oriented file organization (type-bound indices → group keys → shards → individual resources) fundamentally wrong for general-purpose file-oriented backends like Google Drive or local directories?

---

## Analysis: What the Current Architecture Provides

### Benefits of GroupIndex + Shards

1. **Granular sync**: Only fetch shards that changed (good for incremental updates).
2. **Partial sync** (`onRequest`): Apps can subscribe to specific groups (e.g., "only this month's messages").
3. **Linked Data compatibility**: Individual resources addressable via HTTP URIs (Solid).
4. **Bounded shard size**: Predictable memory usage per shard.

### Why It Hurts for Initial Sync

1. **Overhead dominates**: 124 × ~120ms overhead = ~15s, regardless of data volume.
2. **Diminishing returns on granularity**: During initial sync, *all* shards are needed — granularity provides zero benefit.
3. **File count explosion**: N groups × M types × S shards = hundreds of files for modest data.
4. **Upload serialization**: Each shard finalization involves a serialize-and-upload step that cannot be batched across shards.

### Where GroupIndices Still Make Sense

- **Solid Pods**: Resources must be individually addressable for Linked Data interop.
- **Very large datasets**: Where partial sync (`onRequest`) is critical because loading everything is infeasible (e.g., a user with 10 years of messages only loads recent months).
- **Multi-writer scenarios**: Where concurrent shard access reduces contention.

---

## Proposal: "Flat File" Storage Mode

### Core Idea

Replace the per-shard file model with **one TriG dataset file per resource type** for backends that benefit from fewer, larger files. Add a lightweight **manifest file** for fast change detection.

### File Layout (Example: Chat Essence)

```
locorda/chat_essence/
├── _manifest.trig              # Aggregate clock hashes per type
├── SyncChatMessage.trig        # All ~2015 chat messages as Named Graphs
├── SyncMessageGroup.trig       # All ~400 message groups as Named Graphs
├── SyncKeyword.trig            # All ~2015 keywords as Named Graphs
├── ClientInstallation.trig     # Installation metadata
├── ...                         # Other types (~5–10 more files)
└── _indices/                   # Optional: retained for Solid or onRequest
    └── ...
```

**Result**: 263 files → ~10–15 files.

### TriG Dataset Structure

Each type file is a TriG document where every root resource is a Named Graph:

```trig
# SyncChatMessage.trig

# Default graph: type-level metadata (aggregate clock hash, count, etc.)
<> a idx:TypeDataset ;
   idx:clockHash "abc123"^^xsd:hexBinary ;
   idx:resourceCount 2015 ;
   idx:lastModified "2026-02-28T10:30:00Z"^^xsd:dateTime .

# Each resource is a Named Graph
<chat-message/msg-001> {
    <chat-message/msg-001#it> a chat:ChatMessage ;
        schema:text "Hello" ;
        schema:dateCreated "2025-06-15T10:30:00Z" ;
        crdt:clockHash "def456"^^xsd:hexBinary .
    # ... CRDT metadata triples
}

<chat-message/msg-002> {
    <chat-message/msg-002#it> a chat:ChatMessage ;
        schema:text "World" ;
        # ...
}
```

### Manifest File

A single file containing aggregate clock hashes per type, enabling O(1) "anything changed?" checks:

```trig
# _manifest.trig
<> a sync:SyncManifest ;
   sync:lastSyncedAt "2026-02-28T10:35:00Z"^^xsd:dateTime .

<SyncChatMessage.trig> a sync:TypeDataset ;
    sync:clockHash "abc123"^^xsd:hexBinary ;
    sync:resourceCount 2015 .

<SyncMessageGroup.trig> a sync:TypeDataset ;
    sync:clockHash "789xyz"^^xsd:hexBinary ;
    sync:resourceCount 400 .

# ...
```

### Sync Flow (Initial)

1. **Download manifest** (1 request) → compare clock hashes with local state.
2. **Download changed type files** (1 request per changed type, typically all on first sync).
3. **Parse TriG** → iterate Named Graphs → per-resource CRDT merge.
4. **Bulk commit** all merged resources to local DB in one transaction.
5. **Generate updated type files** → upload changed files + updated manifest.

**Initial sync**: 1 (manifest) + N (type files) downloads ≈ 10–15 requests instead of 263.

### Sync Flow (Incremental)

1. **Download manifest** (1 request) → compare per-type clock hashes.
2. **Download only changed type files** (often 1–2 files).
3. **Diff**: Parse TriG, compare per-resource clock hashes with local state, merge only changed resources.
4. **Re-serialize changed type file** → upload.

**Incremental sync**: 1 + 1–2 requests instead of scanning all shards.

---

## Phase 2 (Future): Smart Chunking

When a single type file grows too large (configurable threshold, e.g., 5 MB), automatically split into size-based chunks:

```
SyncChatMessage_chunk_0.trig   # Resources 0–999
SyncChatMessage_chunk_1.trig   # Resources 1000–1999
SyncChatMessage_chunk_2.trig   # Resources 2000–2015
```

Key differences from current sharding:
- **Size-based**, not logic-based (no group keys, no regex transformations).
- **Stable assignment**: Resource-to-chunk assignment is deterministic (e.g., hash-based modulo).
- **Manifest tracks per-chunk hashes**: Only changed chunks are downloaded.
- **No separate shard metadata files**: The chunk *is* the file.

This keeps the file count bounded while preventing individual files from becoming unwieldy.

---

## Open Questions

### 1. Linked Data Compatibility

**Question**: Does consolidating resources into type-level files break Linked Data discoverability?

**Assessment**: Within the TriG file, each resource remains a Named Graph with its original IRI. External systems can't dereference individual resource IRIs to files — but this is already the case for Google Drive and local directory backends. For Solid Pods, the existing per-resource mode should be retained.

**Proposed approach**: Backend-configurable storage mode:
- `StorageMode.flatFile` → new consolidated approach (default for GDrive, Dir).
- `StorageMode.linkedData` → current shard-based approach (default for Solid).

### 2. Concurrent Write Conflicts on Type Files

**Question**: If two installations modify different resources of the same type concurrently, they both re-upload the same type file. How to handle?

**Assessment**: This is inherent to the "fewer, larger files" approach. Mitigations:
- **ETags / version checks**: Detect conflict, re-download, re-merge, re-upload (similar to current shard conflict handling).
- **CRDT semantics guarantee convergence**: Even if the same file is overwritten, the next sync will detect the discrepancy and merge again.
- **Scale reminder**: 2–20 installations, infrequent concurrent writes → low real-world conflict probability.

### 3. Memory Pressure for Large Types

**Question**: Loading all 2015 messages into memory at once for serialization — is that a problem?

**Assessment**: At ~1–2 KB per RDF resource, 2015 messages ≈ 2–4 MB of RDF text. This is well within acceptable limits for mobile devices. Smart Chunking (Phase 2) addresses growth beyond ~5 MB.

### 4. Relationship to Existing GroupIndex Subscriptions

**Question**: Apps using GroupIndex for partial sync (`onRequest`) — how does Flat File mode interact?

**Assessment**: Two options:
- **Option A**: Flat File mode disables `onRequest` entirely. All data for a type is always downloaded. Simple, fits the "sync everything" use case.
- **Option B**: Keep GroupIndex subscription metadata (for query/filter purposes) but store the actual data in flat files. The group metadata is application-level only, not storage-level.

Recommend Option A for simplicity. Apps that genuinely need partial sync should use the `linkedData` storage mode.

### 5. Migration Path

**Question**: How do existing deployments transition from shard-based to flat-file storage?

**Assessment**: Since this is early development phase, a clean break is acceptable. For future versions, a migration would involve:
1. Read all shards → collect all resources.
2. Write consolidated type files + manifest.
3. Delete old shard files.
4. Update local sync state.

### 6. What Happens to the Index/Shard Abstractions in Code?

**Question**: Do we need to keep the `Shard`, `ShardSyncOrchestrator`, `IndexSpec` etc. in the codebase?

**Assessment**: For `StorageMode.linkedData` (Solid), the current shard-based orchestrator remains the right approach. For `StorageMode.flatFile`, a new, much simpler orchestrator path is needed that bypasses shard-level processing entirely. The two modes could share CRDT merge logic but diverge at the storage/orchestration layer.

---

## Expected Impact

### Performance (Initial Sync, Chat Essence)

| Metric | Current (Shard-based) | Projected (Flat File) |
|---|---|---|
| Files read | 263 | ~10–15 |
| Files written | 263 | ~10–15 |
| Shard finalize overhead | 124 × ~120ms = ~15s | 0 (no shards) |
| DB commits | 124 (per shard) | ~10 (per type, bulk) |
| Estimated total | ~48–54s | **~5–10s** (projected) |

### Performance (Incremental Sync)

| Metric | Current | Projected |
|---|---|---|
| Change detection | Download all shard metadata | Download manifest (1 file) |
| Data transfer | Changed shards only | Changed type files only |
| Granularity | Per-shard | Per-type (coarser, but fewer requests) |

### Code Complexity

| Aspect | Current | Projected |
|---|---|---|
| Orchestrator paths | 1 (shard-based) | 2 (flat + shard, sharing CRDT core) |
| Per-type sync logic | shards → docs → merge → finalize → upload | parse TriG → merge → serialize → upload |
| Index management | GroupIndex, FullIndex, ShardSpec, etc. | Manifest + type files |

---

## Relationship to Previous Proposals

- **015 (Shard-Level File Consolidation)**: Introduced dataset-mode shards (all resources of a shard in one TriG file). This proposal goes further: consolidate across shards into a single file per type.
- **014 (GDrive Sync Performance)**: Identified HTTP latency as bottleneck, proposed batch APIs. Flat File mode achieves the same goal (fewer requests) without requiring batch API support from backends.
- **013 (Sync Structure Analysis)**: Documented the "28s for 3 documents" problem. Same root cause, now at larger scale (2015 documents).

---

## Next Steps (if approved)

1. **Design the `FlatFileSyncOrchestrator`** — new orchestrator path that reads/writes type-level TriG files instead of per-shard processing.
2. **Implement manifest generation and comparison** — aggregate clock hash computation per type.
3. **Add `StorageMode` configuration** to backend setup.
4. **Benchmark** — measure actual improvement with Chat Essence app on Dir and GDrive backends.
5. **Decide on GroupIndex interaction** (Open Question 4).
6. **Phase 2 design** — smart chunking threshold and assignment strategy.
