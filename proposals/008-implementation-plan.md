# 008: Implementation Plan — Streaming Sync Pipeline

**Status**: Active  
**Created**: 2026-03-26  
**Context**: Implementation plan for [007 — Feedback-Loop Sync Pipeline](007-two-pass-sync-pipeline.md). Defines phases, ordering, testing strategy, and coexistence with the existing sync code.

---

## Guiding Principles

1. **Coexistence**: The new pipeline is an alternative `SyncFunction` implementation. The existing sync code remains as reference implementation and fallback. Both run against the same `Storage` and produce identical results.
2. **Shared business logic**: Refactor existing code only enough to extract reusable logic (CRDT merge, index management, shard determination). No unnecessary rewrites.
3. **Extend `RemoteSyncStorage`**: A new optional interface (e.g. `RemoteSyncPipelineSupport`) extends the existing `RemoteSyncStorage` contract with the four streaming transformers required by the pipeline. `DirSyncStorage` implements both. No new top-level factory hierarchy needed.
4. **File-per-resource first**: Shard-dataset, single-file, and delta-file modes are deferred until file-per-resource works correctly end-to-end.
5. **Directory backend supports all modes**: The directory backend is our development and test workhorse. Its implementation must cleanly support switching between storage modes (file-per-resource, shard-dataset, single-file) via configuration.
6. **Highest coding standards**: Clean, idiomatic Dart. KISS, YAGNI, DRY, SOLID. No over-engineering.
7. **Always read first**: Always first read the existing codebase before implementing changes, make sure to not break existing semantics that were not supposed to be changed.
8. **Use batching** When doing potentially slow operations like db calls that could be sped up by batching, never iterate over single calls but instead use batching. For example: do not fetch documents individually in  stage 1, but collect all iris and then always do a batch query. If in doubt, chunk the batches to avoid db limits.
---

## Phase 0: IoGI (Index of Group Indices)

**Must be implemented and tested first** — the streaming pipeline's meta-sync phase depends on IoGI to discover GroupIndex documents before the content phase.

### 0.1: Add IoGI to effective config

Add `IdxGroupIndex.classIri` as a new auto-generated meta-index in `buildEffectiveConfig()`, following the exact pattern of IoI and IoGIT:

```dart
// In build_effective_config.dart — alongside existing IoI and IoGIT entries:
ResourceConfigData(
    typeIri: IdxGroupIndex.classIri,
    indices: [
      FullIndexData(
          localName: 'lcrd-group-indices',
          rootResourceFetchPolicy: RootResourceFetchPolicy.prefetch)
    ]),
```

GroupIndex documents are automatically added to this index by the existing `IndexManager` machinery — the same mechanism that adds FullIndex documents to the IoI and GroupIndexTemplate documents to the IoGIT.

### 0.2: Verify IoGI population

Verify (via existing test infrastructure or a new test case in `all_tests.json`) that:
- IoGI index document is created on initialization
- GroupIndex documents created by `IndexManager._createMissingGroupIndex()` are added as entries in IoGI shards
- IoGI shards sync correctly between installations (existing sync handles FullIndex resources without changes)

### 0.3: Add IoGI to existing meta-sync

The existing `RemoteSyncOrchestrator` has a dedicated meta-sync phase that processes FullIndex and GroupIndexTemplate resources. Extend it to also sync IoGI shards, so both the old and new pipeline benefit from IoGI being up to date after meta-sync.

The new pipeline has no ordering requirements here — the feedback loop stage in 007 handles any instability discovered during the meta phase. IoGIT is also not needed in the new pipeline's meta phase (it only seeds IoI + IoGI).

---

## Note: Opportunistic Refactoring (no separate phase)

Do not pre-emptively refactor existing code before it is needed. As the new pipeline stages are built, extract shared logic on demand when a stage needs it. Likely candidates to watch for:

- **CRDT merge primitives**: `RemoteDocumentMerger` (may already be extracted) — takes local + remote graph + merge contract → `MergeResult`. Pull it out when Stage 7 needs it.
- **Change detection**: Shard-entry comparison (local `index_entries` vs. remote shard entries) → classified candidates (`remoteOnly`, `localOnly`, `conflictCandidate`, `unchanged`). Extract when Stage 4 needs it.
- **Shard document merge**: Shard-level CRDT merge for index documents. Extract when Stage 11 needs it.

All existing tests must continue to pass after any such extraction.

---

## Phase 2: Streaming Pipeline Support Interface

The existing sync lifecycle (in `SyncFunction`) is:

1. For each `RemoteStorage` in each backend's `remotes`: call `remote.createSyncStorage(config)` to obtain a per-sync-session `RemoteSyncStorage`.
2. Run `RemoteSyncOrchestrator.sync()` with that storage.
3. Call `syncStorage.finalizeSync()`.

The streaming pipeline reuses this exact lifecycle. The only addition: `RemoteSyncStorage` implementations that support the streaming pipeline additionally implement a new interface providing the four backend-owned stream transformers (Stages 2, 5, 8, 12 in 007).

### 2.1: `RemoteSyncPipelineSupport` interface

Defined in `locorda_core`. Optional — backends only implement it if they support the streaming pipeline:

```dart
/// Optional extension of [RemoteSyncStorage] for the streaming sync pipeline.
///
/// Provides the four backend-owned stream transformers for Stages 2, 5, 8, 12.
/// Implementations may share internal state across transformers (e.g. a
/// per-shard resource cache populated in Stage 2, consumed in Stage 5).
abstract interface class RemoteSyncPipelineSupport {
  /// Stage 2: Shard Fetch — conditionally download shard documents.
  StreamTransformer<ShardRef, FetchedShard> shardFetch();

  /// Stage 5: Resource Fetch — download resource graphs.
  StreamTransformer<SyncCandidate, FetchedCandidate> resourceFetch();

  /// Stage 8: Resource Upload — upload merged resources.
  StreamTransformer<MergeResult, UploadResult> resourceUpload();

  /// Stage 12: Shard Upload — upload merged shard documents.
  StreamTransformer<MergedShard, UploadedShard> shardUpload();
}
```

### 2.2: `DirSyncStorage` implementation

`DirSyncStorage` (in `locorda_dir`) implements both `RemoteSyncStorage` and `RemoteSyncPipelineSupport`. File-per-resource mode first:

- **Stage 2**: Conditional file read for shard documents (ETag-based)
- **Stage 5**: File read per resource
- **Stage 8**: File write per resource (concurrent pool with backpressure)
- **Stage 12**: File write per shard document (concurrent pool)

The implementation must be structured so shard-dataset and single-file modes can be added cleanly later (Phase 6).

### 2.3: `IriTranslatingRemoteSyncStorage` (if needed)

When a `RemoteStorage` wraps its `RemoteSyncStorage` in `IriTranslatingRemoteSyncStorage` (for IRI translation), the translator also needs to implement `RemoteSyncPipelineSupport` by delegating to its inner storage if the inner implements it. Defer this until a backend that uses `IriTranslator` needs streaming support.

---

## Phase 3: Pipeline Event Types

Define the typed events that flow through the pipeline. Each stage has its own input/output event type. Boundary events (`ShardComplete`, `PhaseComplete`) flow inline.

### 3.1: Core event types

Working from 007's stage definitions, define sealed event hierarchies:

- `ShardRef` / `FetchedShard` / `ShardContent` / `ShardNotModified` / `ShardGone`
- `ParsedShard` / `SyncCandidate` (with `remoteOnly` / `localOnly` / `conflictCandidate` / `unchanged`)
- `FetchedCandidate` / `LoadedCandidate` / `MergeResult` / `UploadResult` / `CommitResult`
- `LoadedShardEntries` / `MergedShard` / `UploadedShard` / `ShardCommitResult`
- `SyncInput` / `PhaseComplete` / `ShardComplete`

### 3.2: RdfGraphSource hierarchy

Implement the lazy-decode graph source:

```
RdfGraphSource
├── EncodedRdfGraphSource (raw bytes)
│   ├── TextGraphSource
│   └── BinaryGraphSource
└── DecodedGraphSource (decoded, optionally preserves original)
```

---

## Phase 4: Pipeline Stages (Core)

Implement the 10 Core-owned stages as composable `StreamTransformer`s (or `stream.map()` / `asyncExpand` where appropriate).

### Implementation order

Build and test stages in **data-flow order** — each stage can be tested in isolation with mock input streams, then composed incrementally:

1. **Stage 1: Shard Resolution** (`asyncExpand`) — resolve `SyncInput` → `ShardRef`s via DB queries
2. **Stage 3: Shard Parse** (`stream.map()`) — parse shard document → `ParsedShard` with entries
3. **Stage 4: Change Detection** (`StreamTransformer`) — diff local vs remote entries → `SyncCandidate`s. Emit `localOnly` candidates on `ShardComplete`.
4. **Stage 6: Local Content Load** (`StreamTransformer`) — load local graph from DB for merge
5. **Stage 7: CRDT Merge** (`stream.map()`) — uses extracted merge primitives from Phase 1
6. **Stage 9: DB Commit** (`StreamTransformer`) — chunked transaction writes (500 per tx)
7. **Stage 10: Shard Entry Load** (`StreamTransformer`) — load shard entries + shard document from DB on `ShardComplete`
8. **Stage 11: Shard CRDT Merge** (`stream.map()`) — shard-level merge
9. **Stage 13: Shard DB Commit** (`StreamTransformer`) — parallel to Stage 9 for shard documents
10. **Stage 14: Feedback Stage** — listener on Stage 13 output, controls `inputController`

### Testing strategy per stage

Each stage gets its own unit test file. Tests create a mock input stream, pipe it through the stage, and assert on the output stream. Use `StreamController` + `Stream.fromIterable` for test inputs. No backend or database needed for CPU stages (3, 7, 11).

---

## Phase 5: End-to-End Pipeline Composition

### 5.1: Compose the full pipeline

Wire all stages together as described in 007's "Pipeline Composition" section. The pipeline is a single Dart expression — no orchestrator class.

### 5.2: New `StreamingRemoteSyncOrchestrator`

Create `StreamingRemoteSyncOrchestrator` alongside the existing `RemoteSyncOrchestrator`. It takes a `RemoteSyncStorage` (which is also a `RemoteSyncPipelineSupport`) and runs the streaming pipeline for one sync session against one remote.

The existing `SyncFunction` already creates an orchestrator per remote via `_orchestratorFactory`. Extend this factory to check the type of `syncStorage` and select the appropriate orchestrator:

```dart
// Inside SyncFunction._syncRemote() — only the orchestrator selection changes:
final syncStorage = await remote.createSyncStorage(config);
try {
  final orchestrator = syncStorage is RemoteSyncPipelineSupport
      ? StreamingRemoteSyncOrchestrator(db, syncStorage, remote.remoteId, ...)
      : _orchestratorFactory(syncStorage, remote.remoteId, ...);
  await orchestrator.sync(syncTime, lastSyncTimestamp, config: config);
} finally {
  await syncStorage.finalizeSync();
}
```

`StreamingRemoteSyncOrchestrator.sync()` constructs and runs the pipeline:

```dart
Future<void> sync(DateTime syncTime, DateTime lastSyncTimestamp, ...) async {
  final inputController = StreamController<SyncInput>();
  final pipeline = inputController.stream
      .asyncExpand(shardResolution(db))
      .transform(_pipelineSupport.shardFetch())
      // ... (all stages)
      .transform(feedback(inputController, db));

  inputController.add(SyncInput.metaIndex(ioiIri, iogiIri));
  await pipeline.drain();
}
```

No new `SyncFunction` subclass needed. `_prepareSync()`, backend/remote iteration, `finalizeSync()`, and all surrounding machinery remain in `SyncFunction` unchanged.

### 5.3: Integration with SyncEngine

No changes to `StandardSyncEngine` or `SyncEngine` interface are required. The orchestrator selection is entirely internal to `SyncFunction`. Both orchestrators share the same `Storage`, `CrdtDocumentManager`, `IndexManager`, etc.

### 5.4: Black-box integration tests

Use the existing test infrastructure (`sync_engine_test.dart` + `all_tests.json`) to validate the streaming pipeline produces identical results to the existing implementation:

- Run the same `all_tests.json` test suites against the streaming pipeline
- Add new test cases covering:
  - Multi-installation sync (2+ installations, conflicts)
  - Initial sync both directions (empty local, empty remote)
  - Incremental sync (small delta)
  - GroupIndex subscription and IoGI discovery
  - Meta-index stability detection (IoI changes mid-sync)

The JSON test case format already supports multi-installation scenarios, sequential steps, sync actions, and the `generate_shard_documents` action — perfect for pipeline validation.

---

## Phase 6: Directory Backend — Additional Storage Modes

Only after file-per-resource is working and tested end-to-end.

### 6.1: Shard-dataset mode

Extend the directory `SyncSupport` implementation:

- **Stage 2**: Read entire TriG dataset file per shard, split into resource graphs, set `allResourcesAvailable = true`
- **Stage 5**: Serve from internal cache (no file I/O)
- **Stage 8**: Accumulate `mergedGraph` into `syncSupport` (no file write)
- **Stage 12**: On `PhaseComplete`, assemble TriG datasets from accumulator + Core DB query, write one file per shard

### 6.2: Single-file mode

- **Stage 2**: Read one TriG file, split by shard graph and resource graphs, emit `ShardContent` per shard with proactive injection for non-requested shards (content phase only)
- **Stage 5**: Serve from internal cache
- **Stage 8**: Accumulate into `syncSupport`
- **Stage 12**: On `PhaseComplete`, assemble one full file from accumulator + Core DB, write one file

### 6.3: Mode switching

The directory backend's `SyncSupport` factory selects the mode based on configuration. Internal implementation uses strategy pattern or mode-specific transformer factories — clean separation, no mode-checking conditionals littered across the code.

---

## Phase 7: Performance Validation

### 7.1: Benchmark harness

Create a benchmark that exercises the pipeline against a directory backend with N resources (100, 1000, 5000, 15000). Measure:
- Initial sync (empty local ← full remote)
- Initial push (full local → empty remote)
- Incremental sync (K changed resources out of N)
- No-change sync (everything up to date)

### 7.2: Target validation

Verify the 3-second target from 007 for 15K resources against a local directory backend. Profile to identify remaining bottlenecks.

---

## Dependency Graph

```
Phase 0: IoGI
    │
    ├── Phase 2: RemoteSyncPipelineSupport interface
    │
    └── Phase 3: Pipeline event types
          │
          └── Phase 4: Pipeline stages (Core)
                │
                └── Phase 5: End-to-end composition (uses Phase 2, 3, 4)
                      │
                      └── Phase 6: Additional storage modes
                            │
                            └── Phase 7: Performance validation
```

Phases 2 and 3 can proceed in parallel once Phase 0 is complete.  
Phase 4 depends on Phase 3 (event types). Refactorings from existing code happen on demand during Phase 4.  
Phase 5 depends on Phases 2, 3, and 4.

---

## Rollback Strategy

At every phase, the existing `SyncFunction` + `RemoteSyncOrchestrator` remain fully operational. If the streaming pipeline has issues:

1. Switch back to the old `SyncFunction` via configuration
2. All data in `Storage` is shared — no migration needed
3. The old backend interfaces (`RemoteSyncStorage`) are untouched

The streaming pipeline is additive — it introduces new code paths without modifying existing ones.

---

## What This Plan Does *Not* Cover

- **Non-directory backends** (Solid, GDrive): Implement once the pipeline + directory backend are solid. Each backend implements `SyncBackend` + `SyncSupport`.
- **Delta-file mode**: Designed in 007 but deferred beyond Phase 6.
- **Worker isolate architecture** (proposal 012): Orthogonal to the pipeline design — can be layered on later.
- **Concrete Dart type definitions**: Types emerge during implementation. This plan describes *what* each phase produces, not the exact `class` definitions.
