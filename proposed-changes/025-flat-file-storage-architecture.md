# 025 — Flat File Storage Architecture

**Status**: Draft  
**Created**: 2026-03-01  
**Depends on**: 024 (Three-Phase Sync Architecture)  
**Context**: Even with three-phase sync (024), the fundamental problem of 263 files for ~2000 documents remains. This proposal reduces file count by consolidating resources into type-level files.

## Decision Alignment (026)

This proposal is aligned with `026-recap-sync-direction.md` as the structural optimization for the Dataset/Flat profile.

- 025 is not a global replacement for all modes.
- 025 is the default path for performance-first backends (Dir, GDrive).
- Linked-Data mode remains supported for Solid/interoperability-sensitive use cases.
- Fetch-policy implication remains explicit: flat mode prioritizes prefetch-style sync and does not target fine-grained `onRequest` semantics.

In short: 025 is phase B of the new strategy for the flat profile, not a full strategic retreat.

---

## Problem Statement

Proposal 024 addresses the *execution order* problem (sequential download/merge/upload per shard). This proposal addresses the *structural* problem: too many files.

### File Count Analysis (Chat Essence)

| Category | Files |
|---|---|
| GroupIndex shards (SyncChatMessage) | 62 |
| GroupIndex shards (SyncMessageGroup) | 62 |
| FullIndex shards (SyncKeyword, etc.) | ~5–10 |
| Index metadata documents | ~128 |
| Infrastructure (ClientInstallation, etc.) | ~5 |
| **Total** | **~263** |

Each file incurs:
- **Serialization cost**: ~2–5ms to convert graph to TriG.
- **Upload/download latency**: 1–300ms depending on backend (Dir: ~1ms, GDrive: ~200ms, Solid: ~300ms).
- **Shard metadata overhead**: Each shard is a metadata wrapper — the actual data is in the resources it references.
- **Index management**: GroupIndex entries, shard specs, index-of-indices — all framework bookkeeping.

### Why Fewer Files Helps (Even After 024)

Even with parallel downloads (024), fewer files means:
- Less total serialization work (no per-shard metadata generation).
- Fewer concurrent connections needed.
- Simpler change detection (one hash per type vs. one per shard).
- Dramatically less framework bookkeeping (no index/shard management).

---

## Proposal: One File Per Resource Type

### Core Idea

Replace the per-shard file model with **one TriG dataset file per resource type**. Add a lightweight **manifest file** for fast change detection.

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

---

## Sync Flow (Built on Three-Phase Architecture from 024)

### Initial Sync

```
Phase 1 (Download):
  1. Download _manifest.trig                    (1 request)
  2. Compare per-type clock hashes → all types changed (first sync)
  3. Download all type files in parallel         (~10 requests)

Phase 2 (Merge):
  4. For each type file: parse TriG → iterate Named Graphs
  5. Per-resource CRDT merge against local state
  6. Accumulate merge results

Phase 3 (Upload + Commit):
  7. Re-serialize changed type files
  8. Upload changed files + updated manifest     (parallel)
  9. Single commitDeferredBatch                  (1 DB transaction)
```

**Total requests**: ~12 instead of 263.

### Incremental Sync

```
Phase 1 (Download):
  1. Download _manifest.trig                    (1 request)
  2. Compare per-type clock hashes → 1–2 types changed
  3. Download only changed type files            (1–2 requests)

Phase 2 (Merge):
  4. Parse changed type files
  5. Per-resource clock hash comparison → merge only changed resources
  6. Skip unchanged resources entirely

Phase 3 (Upload + Commit):
  7. Re-serialize changed type files
  8. Upload + updated manifest                   (2–3 requests)
  9. Commit
```

**Total requests**: 3–5 instead of scanning all shards.

---

## Smart Chunking (Future Extension)

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

## Storage Mode Configuration

Backends choose their storage mode. The orchestrator adapts accordingly.

```dart
enum StorageMode {
  /// One TriG dataset file per resource type + manifest.
  /// Best for: GDrive, Dir, WebDAV — backends where fewer files = faster.
  flatFile,

  /// Current shard-based approach with individual resource files.
  /// Best for: Solid Pods — where Linked Data discoverability matters.
  linkedData,
}
```

- `StorageMode.flatFile` → new `FlatFileSyncOrchestrator` (much simpler than shard-based).
- `StorageMode.linkedData` → existing `RemoteSyncOrchestrator` (unchanged).
- Both share the CRDT merge logic (`CrdtDocumentManager`).
- Both benefit from the three-phase execution model (024).

---

## Open Questions

### 1. Linked Data Compatibility

**Question**: Does consolidating resources into type-level files break Linked Data discoverability?

**Assessment**: Within the TriG file, each resource remains a Named Graph with its original IRI. External systems can't dereference individual resource IRIs to files — but this is already the case for Google Drive and local directory backends. For Solid Pods, the existing per-resource mode (`StorageMode.linkedData`) is retained.

### 2. Concurrent Write Conflicts on Type Files

**Question**: If two installations modify different resources of the same type concurrently, they both re-upload the same type file. How to handle?

**Assessment**: Mitigations:
- **ETags / version checks**: Detect conflict, re-download, re-merge, re-upload.
- **CRDT semantics guarantee convergence**: Even if the file is overwritten, the next sync detects and fixes it.
- **Scale reminder**: 2–20 installations, infrequent concurrent writes → low conflict probability.

### 3. Memory Pressure for Large Types

**Question**: Loading all 2015 messages into memory at once for serialization — is that a problem?

**Assessment**: ~2015 resources × ~1–2 KB = ~2–4 MB. Well within mobile device limits. Smart Chunking addresses growth beyond ~5 MB.

### 4. Relationship to GroupIndex Subscriptions

**Question**: Apps using GroupIndex for partial sync (`onRequest`) — how does Flat File mode interact?

**Recommendation**: Flat File mode disables `onRequest`. All data for a type is always downloaded. Apps that genuinely need partial sync should use `StorageMode.linkedData`.

### 5. Migration Path

**Assessment**: Since this is early development phase, a clean break is acceptable. For future versions:
1. Read all shards → collect all resources.
2. Write consolidated type files + manifest.
3. Delete old shard files.
4. Update local sync state.

### 6. What Happens to the Index/Shard Abstractions in Code?

**Assessment**: For `StorageMode.linkedData`, the current shard-based orchestrator remains. For `StorageMode.flatFile`, a new, much simpler orchestrator bypasses shard-level processing entirely. The two share CRDT merge logic but diverge at storage/orchestration.

---

## Expected Impact

### Performance (Initial Sync, Chat Essence)

| Metric | Current | After 024 only | After 024 + 025 |
|---|---|---|---|
| Files read | 263 | 263 (parallel) | ~10–15 |
| Files written | 263 | 263 (parallel) | ~10–15 |
| Shard finalize overhead | 124 × ~120ms | 0 (bulk) | 0 (no shards) |
| DB commits | 124 | 1 | 1 |
| Serialization work | 263 files | 263 files | ~10–15 files |
| **Estimated total** | **48–54s** | **~20–25s** | **~5–10s** |

### Code Complexity

| Aspect | Current | After 025 |
|---|---|---|
| Orchestrator paths | 1 (shard-based) | 2 (flat + shard, sharing CRDT core) |
| Per-type sync logic | shards → docs → merge → finalize → upload | parse TriG → merge → serialize → upload |
| Index management | GroupIndex, FullIndex, ShardSpec, etc. | Manifest + type files (flatFile mode) |

---

## Relationship to Previous Proposals

- **024 (Three-Phase Sync)**: Prerequisite. Provides the download/merge/upload phase separation that Flat File builds on. 024 alone gives ~2× improvement; 025 on top gives ~5–10×.
- **015 (Shard-Level File Consolidation)**: Introduced dataset-mode shards (all resources of a shard in one TriG file). This proposal goes further: consolidate across shards into a single file per type.
- **014 (GDrive Sync Performance)**: Identified HTTP latency as bottleneck. Flat File achieves the same goal (fewer requests) without requiring batch API support.
- **013 (Sync Structure Analysis)**: Documented the "28s for 3 documents" problem. Same root cause, now at larger scale.

---

## Next Steps (if approved)

1. **Implement 024 first** — three-phase sync is the foundation.
2. **Design `FlatFileSyncOrchestrator`** — new orchestrator that reads/writes type-level TriG files.
3. **Implement manifest generation** — aggregate clock hash computation per type.
4. **Add `StorageMode` configuration** to backend setup.
5. **Benchmark** — measure actual improvement with Chat Essence on Dir and GDrive.
6. **Smart Chunking design** — threshold and chunk assignment strategy.
