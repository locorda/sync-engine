# 003: Implementation Plan — Streaming Sync

## Overview

This document provides a concrete implementation plan for the stream-composition pipeline described in [002-streaming-sync-architecture.md](002-streaming-sync-architecture.md). The plan is organized in phases, each delivering incremental value and testable independently.

## Phase 0: Preparation (No Behavior Change)

### 0.1: Extract Sync Primitives

Factor out reusable logic from `RemoteSyncOrchestrator` and `_DocumentSyncHelper` into focused, testable units:

- **`ShardEntryComparator`**: Compares local vs remote shard entries, produces sync candidates
- **`FastPathMerger`**: Handles the trivial merge cases (null local, null remote, same clock hash) without constructing OrganizedGraph
- **`ResourceCommitter`**: Encapsulates the save-document + save-index-entries + save-etag pattern

These extractions make the existing code more testable AND provide building blocks for the streaming pipeline.

### 0.2: Fix Concurrency Guards

The `maxConcurrent*` settings are disabled due to test failures. Before enabling concurrent I/O in the streaming pipeline, we need to understand why:

- Audit test failures when concurrency is enabled
- Likely cause: shared mutable state in storage operations or IRI ID caches
- Fix: ensure per-operation isolation or proper synchronization
- This unblocks concurrent I/O for all backends, not just streaming

### 0.3: Add Benchmarks

Create a benchmark harness for measuring sync performance:

```dart
/// benchmark/sync_benchmark.dart
///
/// Setup: populate remote with N resources, empty local
/// Measure: time for full sync cycle
/// Variants: N = 100, 1000, 5000, 15000
/// Backends: InMemory, DirBackend, (later: GDrive)
```

This gives us a baseline and a way to measure each improvement.

### 0.4: Add Remote Index Mirror Infrastructure

The mirror is **owned by the Remote Backend**, not by Core. Core provides:

1. **Callback mechanism**: `CommitCallback` typedef — called within Core's DB commit transaction so backend mirror writes are atomic with Core state.
2. **Convenience services**: `RemoteIndexMirrorService` (standard metadata), `RemoteContentMirrorService` (full content) — backends choose what they need.
3. **Drift tables**: Add `remote_index_entries` and `remote_content_mirror` tables, but accessed only through the convenience services, never directly by Core.

Implementation steps:
- Schema: `remote_index_entries(remoteId, resourceIri, shardIri, clockHash)` + optional `remote_content_mirror(remoteId, documentIri, content, contentType)`
- Implement `RemoteIndexMirrorService` and `RemoteContentMirrorService` backed by Drift
- Add `CommitCallback` typedef to pipeline interfaces
- **Write-only initially**: Wire backend callback into existing sync commit, but don't use mirror for reads yet
- Verify consistency: compare mirror state with actual remote shard contents in tests

### 0.5: Register Jelly Codec

Ensure Jelly (and all other RDF codecs) are registered with `rdf_core` at `SyncEngine` initialization. This is a prerequisite for `RdfGraphSource` lazy decoding in the Merge stage.

### 0.6: Implement RdfGraphSource

Implement the `RdfGraphSource` sealed class hierarchy (see [004](004-interface-design.md)):
- `EncodedRdfGraphSource` (sealed) — intermediate for not-yet-decoded content
  - `TextGraphSource` — wraps serialized text + content type
  - `BinaryGraphSource` — wraps binary bytes + content type
- `DecodedGraphSource` — wraps an already-decoded `RdfGraph`, with optional `originalSource: EncodedRdfGraphSource?` for pass-through
- Add `RdfGraphSource.decode()` method that resolves to an `RdfGraph` using registered codecs

## Phase 1: Enable Concurrent I/O (Quick Win)

### 1.1: Implement `downloadMany`/`uploadMany` for DirBackend

Currently falls back to sequential base implementation. Override with parallel I/O:

```dart
@override
Future<List<RemoteDownloadResult<RdfGraph>>> downloadMany(
  Iterable<RemoteDownloadRequest> requests,
) async {
  final futures = requests.map((req) => download(
    req.documentIri,
    ifNoneMatch: req.ifNoneMatch,
  ));
  return Future.wait(futures);
}
```

For file I/O, `Future.wait` already provides concurrency because each `file.readAsString()` is an independent async operation.

### 1.2: Re-enable Concurrency Settings

After fixing concurrency guards (Phase 0.2), set reasonable defaults:

```dart
int get maxConcurrentDocumentSyncs => 10;
int get maxConcurrentShardSyncs => 5;
int get maxConcurrentIndexSyncs => 3;
```

**Expected improvement**: 3-5× speedup on I/O-bound operations with existing architecture.

## Phase 2: Fast Path Merge

### 2.1: Implement `FastPathMerger`

```dart
class FastPathMerger {
  final RemoteDocumentMerger _fullMerger;
  final HlcService _hlcService;
  final ShardDeterminer _shardDeterminer;

  Future<MergedResource?> merge({
    required IriTerm documentIri,
    required RdfGraphSource? localGraph,
    required RdfGraphSource? remoteGraph,
    required String? localClockHash,
    required String? remoteClockHash,
    required Future<MergeContract> Function() mergeContractLoader,
  }) async {
    // Fast path 1: No local state → accept remote
    // Decode to extract metadata (typeIri, clock, shards),
    // preserve originalSource in DecodedGraphSource for DB storage
    if (localGraph == null && remoteGraph != null) {
      return _acceptRemote(documentIri, remoteGraph, needsUpload: false);
    }

    // Fast path 2: No remote state → keep local (upload only)
    // Pass EncodedRdfGraphSource through without decoding —
    // metadata from index entry, raw bytes for upload
    if (remoteGraph == null && localGraph != null) {
      return _keepLocal(documentIri, localGraph, needsUpload: true);
    }

    // Fast path 3: Same clock hash → skip
    if (localClockHash != null && localClockHash == remoteClockHash) {
      return null;
    }

    // Slow path: full CRDT merge — decode both graphs
    final local = await localGraph!.decode();
    final remote = await remoteGraph!.decode();
    final mergeContract = await mergeContractLoader();
    return _fullMerge(documentIri, local, remote, mergeContract);
  }
}
```

Note: Fast path 1 (accept-remote) decodes to extract typeIri/clock/shardIris, then ensures `originalSource` is in the DB's storage format (Jelly): if remote already provided Jelly, reuses original bytes; otherwise encodes the decoded graph to Jelly. Commit writes `originalSource` bytes directly — no CPU. Fast path 2 (keep-local) passes `EncodedRdfGraphSource` through without decoding — metadata comes from the index entry, content is already in DB format.

### 2.2: Skip Redundant Downloads for Empty Remote

Before Phase 2 starts per-resource processing, check if Phase 1 already established that the remote shard is empty. If so, skip `downloadMany` entirely.

**Expected improvement**: Eliminates ~3-5s of wasted 404 requests for initial push.

### 2.3: Integrate Fast Path into Existing Orchestrator

Before building the full streaming pipeline, integrate `FastPathMerger` into `_DocumentSyncHelper.downloadAndMerge()`. This gives immediate benefit with minimal architectural change.

## Phase 3: Boundary Elements & Stream Infrastructure

### 3.1: Implement Boundary Types

Implement the shared `Boundary` sealed class and per-stage event types:

```dart
sealed class Boundary { ... }
class ShardComplete extends Boundary { ... }
class LevelComplete extends Boundary { ... }
```

Plus the per-stage event sealed classes that wrap boundaries (see [004](004-interface-design.md) for full types).

### 3.2: Remote Discovery Stream

Create the single-stream Remote Discovery that traverses the index hierarchy internally, emitting data + boundary events:

```dart
Stream<DiscoveryEvent> remoteDiscovery(BackendConfig backend) async* {
  // Traverse: IoI-Index → IoI-Shards → Indices → Shards
  // ETag-conditional downloads; only changed shards emit entries
  // Yields ShardComplete + LevelComplete boundaries inline
}
```

### 3.3: Diff Transform

Implement as a `StreamTransformer<DiscoveryEvent, DiffEvent>`:

- Per data event: DB lookup for local + mirror entries, emit SyncCandidates
- Per ShardComplete: rest-query for local items changed since last sync not seen remotely
- Per LevelComplete: forward as DiffBoundary
- Deduplication via internal `Set<IriTerm>`

**Critical**: The rest-query at ShardComplete must filter by `updatedAt > lastSyncTimestamp` — only locally-changed items need to be synced, not all local-only items.

### 3.4: Add Remote Index Mirror Table (Read Path)

Switch the Diff Transform to use the mirror for efficient diffing (was write-only in Phase 0.4).

## Phase 4: Resource Fetch & Backend Transform

### 4.1: Backend as Stream Transform

Implement the backend-as-transform pattern:

```dart
StreamTransformer<FetchRequest, FetchResult> backendFetchTransform(
  BackendConfig backend,
);
```

Each backend implementation decides internally how to fulfill fetch requests:
- **File-per-Resource** (Solid): Individual HTTP requests, returns `RdfGraphSource.binary()`
- **File-per-Shard** (Dir): Returns from internal cache (populated during Discovery), returns `RdfGraphSource.text()` or `RdfGraphSource.binary()`
- **Aggregated** (GDrive): Returns from internal cache

Backend-specific caching is internal to the transform, not visible to the pipeline.

### 4.2: Resource Fetch Stage

Implement as `StreamTransformer<DiffEvent, FetchEvent>`:

- Collects candidates into bounded batches
- Sends through backend transform for concurrent I/O
- For `LocalOnlyCandidate`: loads raw bytes from local DB → `BinaryGraphSource` (no decoding)
- For `RemoteOnlyCandidate`/`ConflictCandidate`: fetches via backend transform → `EncodedRdfGraphSource`
- Forwards boundaries

## Phase 5: Full Stream-Composition Pipeline

### 5.1: Compose Pipeline

Wire all stream transforms together:

```dart
Future<void> streamingSync(RemoteConfig remote, DateTime syncTime) async {
  final pipeline = remoteDiscovery(remote)
      .transform(diffTransform(db, remote.id, lastSyncTimestamp))
      .transform(fetchTransform(backend))
      .transform(mergeTransform(merger))
      .transform(uploadTransform(backend))
      .transform(dbCommitTransform(db, backend.onCommit, remote.id, syncTime))
      .transform(finalizeTransform(backend));

  await pipeline.drain();
}
```

No orchestrator class — the pipeline *is* the composed transforms (7 stages).

### 5.2: Upload Transform

Pure Remote I/O — uploads resources with `needsUpload: true`, passes others through:
- Batches for concurrent uploads (configurable, e.g., 10 concurrent)
- Captures upload ETag in `UploadedResource.etag`
- No DB access, no decoding/encoding
- Backends with complex upload formats (e.g., GDrive aggregate files) handle transformation internally
- Forwards boundaries after batch flush

### 5.3: DB Commit Transform with Backend Mirror Callback

Pure DB I/O — no remote calls, no decoding or encoding:
- Collects uploaded resources into batches
- Flushes batch at boundary events or when batch is full
- Each batch runs a single atomic DB transaction:
  1. Documents (raw bytes from `graphSource`)
  2. Index entries
  3. ETags (including upload ETags from Upload stage)
  4. `backend.onCommit(batch)` — backend-owned mirror callback
- The backend callback runs inside the same Drift transaction — if it fails, everything rolls back
- Core has no knowledge of what the backend persists in the callback
- Forwards boundaries and emits `CommittedResource` events

### 5.4: Shard Finalize Transform

The terminal transform:
- Aggregates committed resources per shard
- At `ShardComplete` boundary: generate shard document from DB, upload, commit metadata
- Resources are committed before shards — ensures shard documents reflect actual state

### 5.5: Integration Testing

- Run both old `SyncFunction` and new streaming pipeline on same test suite
- Compare resulting DB state for equivalence
- Benchmark both on 100, 1000, 5000, 15000 resource counts
- Profile with Dart DevTools to verify I/O overlap across Upload/DB Commit stages

## Phase 6: Advanced Optimizations

### 6.1: Metadata-Only Decode for Accept-Remote

For initial sync (accept-remote fast path), when the backend provides Jelly bytes, explore extracting only metadata (typeIri, clock, shardIris) without building the full `RdfGraph` object:

```dart
// Current: bytes → full RdfGraph → extract metadata → encode to DB format → save
// Optimization: bytes → extract metadata only → save bytes directly
```

Note: The byte-level pass-through for local-only uploads is already built into the pipeline via `EncodedRdfGraphSource`. For remote-only where the remote format matches the DB format (both Jelly), Merge already skips re-encoding — this optimization would additionally skip the full decode. If a lightweight metadata-only parser for Jelly becomes available, this could eliminate decode entirely for the accept-remote fast path.

### 6.2: Smart Batch Sizing

Dynamically adjust batch size based on throughput:
- If DB writes are fast, use larger batches (fewer transactions)
- If DB writes are slow, use smaller batches (more responsive)
- Measure and adapt during sync

### 6.3: In-Memory Cache (Advanced)

For File-per-Shard/Aggregated backends: optionally keep extracted graphs in memory during sync instead of caching in DB. This avoids an extra DB write/read cycle but uses more memory. Configurable per-backend. Not needed initially — premature optimization.

## Dependency Graph

```
Phase 0 ──────────────────────────────────────────────────────┐
  0.1: Extract primitives                                      │
  0.2: Fix concurrency guards      ─────────────────┐         │
  0.3: Add benchmarks                                │         │
  0.4: Mirror infra (callback + services, write-only)┤         │
  0.5: Register Jelly codec                          │         │
  0.6: Implement RdfGraphSource                      │         │
                                                     │         │
Phase 1 ◀────────────────────────────────────────────┘         │
  1.1: DirBackend downloadMany/uploadMany                      │
  1.2: Re-enable concurrency                                   │
                                                               │
Phase 2 ◀─────────────────────────────────────────────────────┘
  2.1: FastPathMerger (uses RdfGraphSource)
  2.2: Skip redundant downloads for empty remote
  2.3: Integrate into existing orchestrator

Phase 3 (can start after Phase 0)
  3.1: Boundary types (Boundary, ShardComplete, LevelComplete)
  3.2: Remote Discovery stream (single stream, hierarchy internal)
  3.3: Diff Transform (DB lookup + boundary rest-query)
  3.4: Mirror read path (switch from write-only to active use)

Phase 4 (can start after Phase 3)
  4.1: Backend as stream transform
  4.2: Resource Fetch stage (batched I/O via backend transform)

Phase 5 (requires Phases 2, 3, 4)
  5.1: Compose full pipeline (7 stream transforms)
  5.2: Upload Transform (pure Remote I/O)
  5.3: DB Commit Transform (pure DB I/O + backend mirror callback)
  5.4: Shard Finalize Transform (boundary-triggered)
  5.5: Integration testing

Phase 6 (after Phase 5 is stable)
  6.1-6.3: Advanced optimizations
```

## Effort Estimates

| Phase | Complexity | Value | Risk |
|-------|-----------|-------|------|
| Phase 0 | Low | Foundation | Low |
| Phase 1 | Low | **High** (3-5× I/O speedup) | Low |
| Phase 2 | Medium | **High** (2-4× merge speedup) | Low |
| Phase 3 | Medium | Medium (core stream infra) | Medium |
| Phase 4 | Medium | Medium (backend transforms) | Medium |
| Phase 5 | High | **Very High** (full pipeline) | Medium |
| Phase 6 | High | Medium (diminishing returns) | High |

**Recommendation**: Phases 1 and 2 alone should achieve a 4-8× improvement with minimal risk. Phase 5 (full stream composition) is needed for the theoretical maximum but involves more architectural change.

## Files to Create/Modify

### New Files
- `lib/src/sync/pipeline/boundary.dart` — Shared Boundary sealed class
- `lib/src/sync/pipeline/discovery_stream.dart` — Remote Discovery stream
- `lib/src/sync/pipeline/diff_transform.dart` — Diff StreamTransformer
- `lib/src/sync/pipeline/fetch_transform.dart` — Resource Fetch StreamTransformer
- `lib/src/sync/pipeline/merge_transform.dart` — CRDT Merge StreamTransformer
- `lib/src/sync/pipeline/upload_transform.dart` — Upload StreamTransformer (pure Remote I/O)
- `lib/src/sync/pipeline/db_commit_transform.dart` — DB Commit StreamTransformer (pure DB I/O + backend callback)
- `lib/src/sync/pipeline/finalize_transform.dart` — Shard Finalize StreamTransformer
- `lib/src/sync/pipeline/events.dart` — Per-stage event sealed classes (incl. UploadEvent)
- `lib/src/sync/pipeline/streaming_sync_function.dart` — Pipeline composition (7 stages)
- `lib/src/sync/fast_path_merger.dart` — Fast-path CRDT merge
- `lib/src/sync/sync_candidate.dart` — SyncCandidate sealed class
- `lib/src/sync/rdf_graph_source.dart` — RdfGraphSource sealed class
- `lib/src/storage/remote_mirror_services.dart` — Convenience mirror services (RemoteIndexMirrorService, RemoteContentMirrorService)

### Modified Files
- `lib/src/storage/storage_interface.dart` — Add `CommitCallback` typedef
- `lib/src/storage/remote_storage.dart` — Add backend transform factory method + `onCommit` callback
- `packages/locorda_dir/` — Backend-as-transform implementation + mirror callback
- `packages/locorda_solid/` — Backend-as-transform implementation + mirror callback
- `packages/locorda_gdrive/` — Backend-as-transform implementation + mirror callback (with content mirror)
- `packages/locorda_drift/` — Implement mirror tables in Drift schema (remote_index_entries + remote_content_mirror)
- `lib/src/sync/remote_document_merger.dart` — Extract fast-path logic
- `lib/src/standard_sync_engine.dart` — Wire up streaming pipeline option
- `lib/src/sync_engine.dart` — Configuration for streaming vs. legacy sync
- `lib/src/sync_engine_init.dart` — Register Jelly codec at init
