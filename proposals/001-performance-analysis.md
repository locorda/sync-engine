# 001: Performance Analysis — Current Sync Architecture

## Executive Summary

Syncing ~15,000 resources takes ~18 seconds in either direction — downloading to an empty local **or** pushing to an empty remote (e.g., after a Matrix message import in Chat Essence). This document analyzes the current architecture to identify exactly where time is spent and why the architecture creates fundamental performance ceilings.

**Both initial sync directions are critical use cases:**
- **Empty local, full remote**: User installs on a new device, syncs existing data down
- **Empty remote, full local**: User imports data (e.g., Matrix exports), pushes to remote for the first time

## Current Architecture Overview

The sync pipeline follows a **phase-based, sequential** design:

```
Phase 0: Sync Preparation (materialize local shard state)
  └─ ShardDocumentGenerator: generates shard documents from index entries

Phase A+B: Remote Synchronization (per backend, per remote)
  ├─ Meta-types (sequential): idx:FullIndex, idx:GroupIndexTemplate
  │   └─ Per resource type: sync index docs → sync shards (each shard: 3-phase)
  └─ Content types (batched):
      ├─ Phase 3a: Collect IndexSyncSpecs (DB reads, parallel)
      ├─ Phase 3b: Batch sync all GroupIndex documents
      └─ Phase 3c: Three-phase shard sync across all content types
          ├─ Phase 1: Download all shard docs + build resource queues
          ├─ Phase 2: Global resource merge (CRDT merge + upload + DB commit)
          └─ Phase 3: Finalize shards (build metadata, upload, commit)
```

## Identified Bottleneck Categories

### 1. Sequential Network I/O (CRITICAL)

**All concurrency is disabled.** The `maxConcurrent*` settings are all hardcoded to 1:
```dart
// remote_storage.dart:169-175
int get maxConcurrentDocumentSyncs => 1; //10;
int get maxConcurrentShardSyncs => 1; //5;
int get maxConcurrentIndexSyncs => 1; //3;
```

This means:
- `downloadMany()` and `uploadMany()` in the base `RemoteSyncStorage` class are **sequential loops** (no parallelism)
- `DirSyncStorage` (local directory backend) does NOT override `downloadMany`/`uploadMany` — falls back to one-at-a-time
- `_executeInChunks()` with `maxConcurrent=1` runs shard operations **one at a time**

**Impact for 15,000 resources**: With 4 shards per index, each shard sync involves:
- 1 download (shard doc) + N downloads (individual resources) + 1 upload (shard doc) + N uploads (resources)
- Even at 1ms per file I/O, 15,000 × 2 operations = ~30 seconds of pure sequential I/O

### 2. Per-Resource Processing Overhead (HIGH)

Each resource goes through an expensive pipeline individually:

```
For each resource:
  1. Download from remote (file read + RDF parse)
  2. Load from local DB
  3. CRDT merge (organize graphs, compare clocks, merge each property)
  4. Reconcile shards (determine which shards, update document)
  5. Upload to remote (RDF serialize + file write)
  6. Commit to DB (save document + save index entries + update ETags)
```

The CRDT merge alone involves:
- `OrganizedGraph.fromGraph()` — walks entire graph to categorize subjects
- `ClockComparison.compareClocks()` — compares HLC timestamps
- Per-subject, per-property merge with CRDT algorithm lookup
- `_buildResultDocument()` — reassembles graph with statements, blank nodes, clock hash

For an initial sync (empty local), most of this is unnecessary — there's no local state to merge against.

### 3. Serialization/Deserialization Bottleneck (HIGH)

Every resource is:
1. **Decoded** from Jelly binary → RdfGraph (on download from remote)
2. **Merged** as RdfGraph objects
3. **Re-encoded** from RdfGraph → Jelly binary (on save to DB)
4. **Re-encoded again** from RdfGraph → Turtle/TriG (on upload to remote)

The pipeline touches every byte of every resource at least 3-4 times. For 15,000 resources, the aggregate decode/encode time is significant.

### 4. Database Write Amplification (MEDIUM-HIGH)

For each resource saved to the DB:
- `saveDocument()`: INSERT/UPDATE with Jelly-encoded content + metadata
- `saveIndexEntries()`: INSERT/UPDATE index entries for each index the resource belongs to
- `setRemoteETags()`: UPDATE ETag cache

Even with the batch chunking (2000 docs per transaction), this is substantial. The `inTransaction()` wrapper helps amortize fsync, but the individual INSERT statements still execute sequentially.

### 5. Phase Boundaries Create Unnecessary Waiting (MEDIUM)

The strict phase separation means:
- Phase 1 (download all shards) must complete **entirely** before Phase 2 (merge) begins
- Phase 2 must complete **entirely** before Phase 3 (finalize) begins
- No pipelining: a resource downloaded early in Phase 1 sits idle until all downloads complete

With 15,000 resources across multiple shards:
- Phase 1 downloads all shard documents → waits
- Phase 2 merges all resources → waits
- Phase 3 uploads all shards → waits

### 6. Redundant Work for Initial Sync — Both Directions (HIGH)

**Empty local (download from remote)**: The current code still:
- Checks local DB for existing documents (null for all)
- Loads cached ETags (null for all)
- Runs CRDT merge (trivial: `localGraph == null → accept remote`)
- Reconciles shards (computes shard assignment)
- Builds full CRDT documents with metadata, blank node mappings, statements

**Empty remote (upload from local)** — **even worse**: After Phase 1 confirms all shard documents return 404 (empty remote), the code:
- Calls `downloadMany` for ALL 15K individual resources → **all return 404 again** — completely redundant since Phase 1 already established the remote is empty
- For each 404 response, `downloadAndMerge` enters the "Not Found" branch (line 1318) and still:
  - Loads the local document from DB (necessary, but could be batched more efficiently)
  - Loads the merge contract (unnecessary — there's nothing to merge)
  - Runs `reconcileDocumentShards` (recomputes shard assignments we already know from the index entries)
- Then `uploadMany` for all 15K resources — **sequential** (`maxConcurrent = 1`)
- Then commits all to DB

The empty-remote path is arguably **more wasteful** than empty-local because it makes 15K network requests that are guaranteed to return 404, when Phase 1 already told us the remote is empty.

Most of this work produces trivial results that could be short-circuited in either direction.

### 7. RDF Graph Overhead (LOW-MEDIUM)

RdfGraph objects are immutable and use structural sharing, but:
- Each `.withTriples()` creates a new graph
- `OrganizedGraph.fromGraph()` creates multiple derived data structures
- Statement reification (for CRDT metadata) generates many small objects
- The `IdentifiedBlankNodeBuilder` walks the graph for canonical blank node IDs

## Where the 18 Seconds Go (Estimated Breakdown)

### Scenario A: Empty Local, Full Remote (download)

For 15,000 resources to empty local, with DirBackend:

| Phase | Operation | Est. Time | Notes |
|-------|-----------|-----------|-------|
| Phase 0 | Shard generation | ~0.5s | Mostly no-op for initial sync |
| Phase 1 | Download shard docs | ~0.2s | Few shard files |
| Phase 1 | Parse shard entries | ~0.1s | Build resource queues |
| Phase 2 | Download resources | ~5-7s | 15K sequential file reads + Jelly decode |
| Phase 2 | CRDT merge | ~2-4s | Per-resource graph operations (all trivial) |
| Phase 2 | Upload resources | ~4-6s | 15K sequential file writes + Turtle encode |
| Phase 2 | DB commit | ~2-3s | INSERT 15K documents + index entries |
| Phase 3 | Build shard docs | ~0.5s | Regenerate shard RDF |
| Phase 3 | Upload shards | ~0.2s | Few shard files |
| Phase 3 | DB commit | ~0.3s | Update shard documents |
| **Total** | | **~16-23s** | |

### Scenario B: Empty Remote, Full Local (upload after import)

For 15,000 resources push to empty remote, with DirBackend:

| Phase | Operation | Est. Time | Notes |
|-------|-----------|-----------|-------|
| Phase 0 | Shard generation | ~1-2s | Generates shard docs from 15K index entries |
| Phase 1 | Download shard docs | ~0.1s | All return 404 (remote is empty) |
| Phase 1 | Parse shard entries | ~0.1s | All empty, but still builds local queues |
| Phase 2 | Download resources | ~3-5s | **15K requests all returning 404** — pure waste |
| Phase 2 | Load local docs | ~1-2s | Reads 15K docs from DB (necessary) |
| Phase 2 | Merge contract load | ~1-2s | **15K loads for no-op merges** — unnecessary |
| Phase 2 | Shard reconciliation | ~0.5-1s | Recomputes shard assignments we already know |
| Phase 2 | Upload resources | ~5-8s | 15K sequential file writes (dominant cost) |
| Phase 2 | DB commit | ~2-3s | UPDATE 15K documents + index entries + ETags |
| Phase 3 | Build shard docs | ~0.5s | Regenerate shard RDF |
| Phase 3 | Upload shards | ~0.2s | Few shard files |
| Phase 3 | DB commit | ~0.3s | Update shard documents |
| **Total** | | **~15-25s** | |

**Key difference**: Scenario B wastes ~3-7s on 15K download attempts that are guaranteed to return 404, plus ~1-2s on merge contract loading that serves no purpose. The sequential upload of 15K resources is the dominant bottleneck.

In both scenarios, the dominant costs are **sequential file I/O** (read+write 15K files one at a time) and **per-resource processing overhead for trivial cases**.

## Fundamental Architectural Issues

### 1. No Streaming
Data flows through the pipeline in **bulk batches at phase boundaries**, not as a continuous stream. Downloaded resources wait for all downloads to complete before merge begins.

### 2. No Parallelism
Concurrency is disabled due to test failures (noted in FIXMEs). The architecture doesn't have proper isolation between concurrent operations on different resources.

### 3. No Fast Path for Common Cases
The most common sync scenarios (initial sync in either direction, single-device no-conflict sync) go through the same full CRDT merge as the rare multi-device conflict case.

### 4. No Phase 1 → Phase 2 Information Flow
Phase 1 downloads shard documents and discovers which resources exist remotely. But Phase 2 **ignores this information** and re-downloads every resource individually. For the empty-remote case, Phase 1 confirms all shards are 404, yet Phase 2 still makes 15K individual download requests that all return 404. The pipeline does not propagate "remote is empty for this shard" knowledge from Phase 1 to Phase 2.

### 5. RDF as Intermediate Format
Every resource is materialized as a full `RdfGraph` at every stage. There's no way to pass raw bytes through stages that don't need to inspect them.

### 6. Upload-Then-Commit Pattern
Resources are uploaded to remote **before** being committed to local DB. This means the entire upload pass must complete before the DB commit, adding latency.

### 7. Symmetric Treatment of Asymmetric Cases
The code uses the same `downloadAndMerge` → `uploadMany` → commit pipeline regardless of sync direction. But initial-push (empty remote) and initial-pull (empty local) have fundamentally different work profiles:
- **Empty local**: Needs download + accept-remote → DB write (upload is redundant since remote already has the data)
- **Empty remote**: Needs DB read → upload (download is redundant since remote has nothing)

Neither fast path is implemented. Both directions do the full download + merge + upload cycle.

## Dataset Mode (useShardDatasets)

The `useShardDatasets` flag bundles all resources in a shard into a single TriG file. This is designed to reduce the number of remote files, but:
- Still requires deserializing the full dataset to extract individual resources
- Upload still requires serializing the full dataset
- The combined storage building (`_buildCombinedStorage`) adds cross-shard merge overhead

For local directory sync, dataset mode trades fewer files for larger per-file processing.

## Conclusion

The 18-second sync time — whether pulling from remote or pushing to remote — is not caused by any single bottleneck but by the **compounding effect of sequential processing** at every level: sequential file I/O, sequential resource processing, sequential phase execution. Additionally, the pipeline treats both sync directions identically despite their fundamentally different work profiles, wasting significant time on operations guaranteed to be no-ops (downloading from an empty remote, uploading to a remote that already has the data). A streaming pipeline that overlaps I/O with processing, enables parallelism, and provides direction-aware fast paths could dramatically reduce this time in both scenarios.
