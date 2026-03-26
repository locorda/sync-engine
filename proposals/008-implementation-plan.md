# 008: Implementation Plan — Streaming Sync Pipeline

**Status**: Active  
**Created**: 2026-03-26  
**Context**: Implementation plan for [007 — Feedback-Loop Sync Pipeline](007-two-pass-sync-pipeline.md). Defines phases, ordering, testing strategy, and coexistence with the existing sync code.

---

## Guiding Principles

1. **Coexistence**: The new pipeline is an alternative `SyncFunction` implementation. The existing sync code remains as reference implementation and fallback. Both run against the same `Storage` and produce identical results.
2. **Shared business logic**: Refactor existing code only enough to extract reusable logic (CRDT merge, index management, shard determination). No unnecessary rewrites.
3. **New backend interfaces**: New `SyncBackend` / `SyncSupport` interfaces for the streaming pipeline. Only the directory backend implements them initially.
4. **File-per-resource first**: Shard-dataset, single-file, and delta-file modes are deferred until file-per-resource works correctly end-to-end.
5. **Directory backend supports all modes**: The directory backend is our development and test workhorse. Its implementation must cleanly support switching between storage modes (file-per-resource, shard-dataset, single-file) via configuration.
6. **Highest coding standards**: Clean, idiomatic Dart. KISS, YAGNI, DRY, SOLID. No over-engineering.

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

### 0.3: Verify meta-sync order

The meta-sync must process IoI first (to discover IoGI and IoGIT), then IoGI and IoGIT (to discover GroupIndex and GroupIndexTemplate documents), before the content phase can process data shards. Verify the existing `RemoteSyncOrchestrator` handles IoGI documents in the correct order — this validates the meta-sync dependency chain independently of the streaming pipeline.

> **KK** really? Actually, I would argue that we have no ordering requirements.  Or did you mean that we have to add IoGI syncing to the meta part of the existing sync implementation? I agree to that. But in our new pipeline, we just do the meta phase with IoI and IoGI , no IoGIT and no need for ordering constraints - all that could happen here is already covered by the feedback loop stage.
---

## Phase 1: Extract Shared Business Logic

Refactor the existing sync code to expose reusable components that both the old and new pipeline can use. **No behavior change** — all existing tests must continue to pass.

> **KK**  Does this make sense as a phase? Shouldn't we rather do those type of refactorings on demand as we go? You could leave this framed as "watch for refactoring potentials where we want to extract reusable components from the current implementation, for example in the following areas"

### 1.1: CRDT merge primitives

Extract from `RemoteSyncOrchestrator` / `_DocumentSyncHelper`:

- **`RemoteDocumentMerger`** (likely already extracted): Takes local graph + remote graph + merge contract → produces `MergeResult` with merged graph, needsUpload, encodedForDb
- **`FastPathDetector`**: Detects trivial cases (null local → accept remote; null remote → upload local; same clockHash → skip) without full CRDT merge

### 1.2: Change detection logic

Extract shard-entry comparison:

- **`ShardEntryDiff`**: Compares local `index_entries` for a shard against remote shard entries. Produces classified candidates: `remoteOnly`, `localOnly`, `conflictCandidate`, `unchanged`

### 1.3: Shard document merge

Extract shard-level CRDT merge (index document + shard entries → merged shard document). This is the shard counterpart to the resource-level CRDT merge.

---

## Phase 2: New Backend Interface

Define new interfaces for the streaming pipeline's backend interactions. These are **separate** from the existing `RemoteSyncStorage` — the old interface continues to work for the old sync path.

> **KK**  Did you do your homework? You need to make sure you fully understand the codebase and then update this entire implementation plan. Your instruction here is basically what we said in the concept, but backend actually is not the right abstraction for this. Our existing Backend contains RemoteStorage and AFAIR for each sync we create a specific RemoteSyncStorage from that RemoteStorage, so that would be the perfect integration point - RemoteSyncStorage probably already is what we meant with SyncSupport. So just add a SyncSupport (or whatever) interface and inmplement it in the dir backends implementation of RemoteSyncStorage (and possibly also in cross-cutting implementations like the profiling implementations or such, but maybe we do not need that). And the name SyncSupport sucks - maybe RemoteSyncPipelineFactory or such?

### 2.1: SyncBackend interface

```dart
/// Factory for creating sync-session-scoped support objects.
/// One implementation per backend type (directory, Solid, GDrive).
abstract interface class SyncBackend {
  /// Create a sync-scoped support object that provides the four
  /// backend-owned stream transformers (Stages 2, 5, 8, 12).
  SyncSupport createSyncSupport();
}
```

### 2.2: SyncSupport interface

```dart
/// Sync-scoped backend support — provides the four stream transformers
/// that 007's pipeline delegates to the backend.
///
/// Implementations may share internal state across transformers
/// (e.g. a per-shard resource cache populated in Stage 2, consumed in Stage 5).
abstract interface class SyncSupport {
  /// Stage 2: Shard Fetch — download shard documents from remote.
  StreamTransformer<ShardRef, FetchedShard> shardFetch();

  /// Stage 5: Resource Fetch — download resource graphs from remote.
  StreamTransformer<SyncCandidate, FetchedCandidate> resourceFetch();

  /// Stage 8: Resource Upload — upload merged resources to remote.
  StreamTransformer<MergeResult, UploadResult> resourceUpload();

  /// Stage 12: Shard Upload — upload merged shard documents to remote.
  StreamTransformer<MergedShard, UploadedShard> shardUpload();
}
```

### 2.3: Directory backend implementation

Implement `SyncBackend` + `SyncSupport` for the directory backend (`locorda_dir`). File-per-resource mode first:

- **Stage 2**: Conditional file read for shard documents
- **Stage 5**: File read per resource
- **Stage 8**: File write per resource (concurrent pool with backpressure)
- **Stage 12**: File write per shard document (concurrent pool)

The directory implementation must be structured so shard-dataset and single-file modes can be added cleanly later (Phase 5).

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

### 5.2: New SyncFunction

Create `StreamingSyncFunction` as an alternative implementation alongside `SyncFunction`. It constructs the pipeline, seeds the `inputController` with the initial meta-index `SyncInput`, and awaits pipeline completion.

```dart
class StreamingSyncFunction {
  final Storage db;
  final SyncBackend backend;
  // ...

  Future<void> call(DateTime syncTime) async {
    final syncSupport = backend.createSyncSupport();
    final inputController = StreamController<SyncInput>();

    final pipeline = inputController.stream
        .asyncExpand(shardResolution(db))
        .transform(syncSupport.shardFetch())
        // ... (all 14 stages)
        .transform(feedback(inputController, db));

    inputController.add(SyncInput.metaIndex(/* IoI + IoGI + IoGIT */));
    await pipeline.drain();
  }
}
```

### 5.3: Integration with SyncEngine

Add a configuration option or factory method to `StandardSyncEngine` to select between `SyncFunction` (existing) and `StreamingSyncFunction` (new). Both share the same `Storage`, `CrdtDocumentManager`, `IndexManager`, etc.

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
Phase 1: Extract shared logic ─────────────┐
    │                                       │
Phase 2: New backend interface              │
    │                                       │
Phase 3: Pipeline event types               │
    │                                       │
Phase 4: Pipeline stages (uses Phase 1) ◄───┘
    │
Phase 5: End-to-end composition (uses Phase 2, 3, 4)
    │
Phase 6: Additional storage modes (extends Phase 5)
    │
Phase 7: Performance validation
```

Phases 1, 2, 3 can proceed in parallel once Phase 0 is complete.  
Phase 4 depends on Phases 1 and 3.  
Phase 5 depends on all of 2, 3, 4.

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
