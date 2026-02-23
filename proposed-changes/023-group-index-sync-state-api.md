# 023 — Group Index Sync State API

## Summary

Add a first-class, per-index-instance sync-state model to the core sync runtime and expose
it through both `SyncEngine` and `ObjectSyncEngine` APIs.

This proposal introduces:

1. Core (`SyncEngine`) reactive and imperative APIs for index-instance sync state.
2. Object (`ObjectSyncEngine`) typed facade APIs over the same core primitives.
3. Auto-subscribe-on-write behavior for group-indexed resources.
4. A dedicated persisted tracking model for index-instance sync lifecycle
   (instead of inferring this indirectly from unrelated tables).

---

## Why this revision

The previous draft mixed correct product requirements with brittle implementation guidance.
In particular, deriving “initial sync completion” from
`RemoteSyncState.lastSyncedAt > GroupIndexSubscriptions.createdAt` is not robust enough
as a long-term contract.

This revised proposal defines explicit sync-state tracking in core, with storage-backed
watch APIs and a clean `Storage` abstraction (no downcasts to Drift in higher layers).

---

## Background and terminology

**Index instance** — the unit of sync state.

- Full-index type: exactly one index instance.
- Group-index type: one index instance per subscribed group key.

Examples:

- Full index: one instance for all `Note` items.
- Group index: one instance per `(channelId, yearMonth)`.

**Initial sync completion (normative definition)**

For a given `(indexInstanceId, remoteId)`, initial sync is complete once at least one
successful sync cycle has finished for that pair and this success has been persisted in
index-instance sync state.

This is represented by a non-null `lastSuccessfulSyncAt`.

`IndexInstanceSyncState.hasCompletedInitialSync` is true iff **every configured remote**
for this index instance has completed initial sync at least once.

If there are no configured remotes (`perRemote.isEmpty`),
`hasCompletedInitialSync` is vacuously true.

---

## Scope

### Package-level scope

- `locorda_core`
  - Introduce index-instance sync state persistence + watcher primitives.
  - Extend `Storage` API so higher layers can observe and query this state.
  - Expose canonical sync-state APIs on `SyncEngine`.
  - Update sync orchestration to emit lifecycle updates.
  - Move auto-subscribe-on-write to `SyncEngine.save(...)` (core layer).
- `locorda_objects`
  - Add typed facade APIs and value objects.
  - Delegate to core, no storage implementation assumptions.

### Compatibility scope

- Keep `configureGroupIndexSubscription(...)` available.
- It may be marked as deprecated in object-facing APIs:
  `@Deprecated('Use ensureGroupIndexSubscription instead.')`.

---

## Task 0 — Correctness bug fix (required)

### 0a. Preserve original subscription creation timestamp

`saveGroupIndexSubscription` currently uses `insertOnConflictUpdate`, which can overwrite
`createdAt` for existing subscriptions.

That is incorrect for lifecycle semantics and can break temporal reasoning.

**Required behavior**:

- On first insert: set `createdAt`.
- On conflict update: update mutable fields (for example `itemFetchPolicy`) but **do not**
  overwrite `createdAt`.

Even after introducing explicit index-instance sync tracking, this remains the correct
behavior for subscription metadata.

---

## Task 1 — Data model (object-facing)

Create immutable value objects in `locorda_objects`, for example:

- `RemoteSyncPhase`
- `RemoteSyncEntry`
- `IndexInstanceSyncState`

The existing shape from the previous draft is valid and should be kept, including:

- `hasCompletedInitialSync`
- `hasStaleError`
- `hasInitialSyncError`

### Requirements

- `@immutable`, `const` where possible.
- Implement `==` and `hashCode`.
- Export from public barrels.
- Keep dependency footprint minimal.

---

## Task 2 — Core tracking model (new, required)

Add explicit persisted sync-state tracking for `(indexInstanceId, remoteId)`.

### 2a. Storage-level state shape

Introduce a storage representation equivalent to:

- `indexInstanceId` (stable identifier; e.g. index IRI)
- `remoteId`
- `phase` (`notSynced | syncPlanned | syncing | ready | error`)
- `lastSuccessfulSyncAt` (nullable)
- `lastAttemptStartedAt` (nullable)
- `lastAttemptFinishedAt` (nullable)
- `lastErrorMessage` (nullable)

Optional but recommended:

- `lastCycleId` for dedup/debugability.

### 2b. Storage API additions (core abstraction)

Add methods to `Storage` (or a dedicated sub-interface owned by core) so upper layers stay
backend-agnostic:

- `Future<void> upsertIndexInstanceSyncState(...)`
- `Future<IndexInstanceSyncStateSnapshot?> getIndexInstanceSyncState(...)`
- `Stream<IndexInstanceSyncStateSnapshot> watchIndexInstanceSyncState(...)`
- `Future<List<String /*remoteId*/>> getConfiguredRemoteIds()`

Also add a stream for configured remotes, if not already available via existing infra:

- `Stream<Set<String>> watchConfiguredRemoteIds()`

Implement in both Drift and in-memory storage.

### 2c. Sync orchestration responsibilities

During sync cycles, orchestration writes phase transitions explicitly:

1. `syncPlanned` when instance is queued for a remote in the current cycle.
2. `syncing` when active processing starts.
3. `ready` with success timestamps on successful completion.
4. `error` with message on failure.

If a previously successful instance errors later, keep
`lastSuccessfulSyncAt` intact.
This preserves `hasCompletedInitialSync == true` while allowing `hasStaleError == true`.

---

## Task 3 — Public reactive APIs (`SyncEngine` + `ObjectSyncEngine`)

Add core-level APIs first, then object-level facade APIs.

### 3a. Core reactive APIs (`SyncEngine`)

Add APIs that identify index instances without Dart object typing, for example:

```dart
Stream<IndexInstanceSyncStateSnapshot> watchGroupIndexSyncState({
  required String indexName,
  required RdfGraph groupKeyGraph,
});

Stream<IndexInstanceSyncStateSnapshot> watchTypeSyncState({
  required IriTerm typeIri,
  String localName = defaultIndexLocalName,
});
```

Exact parameter naming may differ, but the core API must be based on core identifiers
(`typeIri`, `indexName`, `groupKeyGraph`, or a canonical `IndexInstanceId`).

### 3b. Typed facade reactive APIs (`ObjectSyncEngine`)

Add:

```dart
Stream<IndexInstanceSyncState> watchGroupIndexSyncState<G>(
  G groupKey, {
  String localName = defaultIndexLocalName,
});

Stream<IndexInstanceSyncState> watchTypeSyncState<T>();
```

### Semantics (both layers)

- Emits immediately with last known state.
- Broadcast stream.
- Emits on:
  - subscription changes,
  - configured-remote changes,
  - index-instance lifecycle updates.
- `watchTypeSyncState` applies only to full-index resources.

### Clarification for disabled full index

For `watchTypeSyncState` where full index is disabled:

- Throw a dedicated `StateError`/domain exception with actionable message.
- Do not silently emit `local()`.

This avoids masking configuration errors.

---

## Task 4 — Imperative APIs (`SyncEngine` + `ObjectSyncEngine`)

### 4a. Core imperative APIs (`SyncEngine`)

Add APIs for canonical identifiers, for example:

```dart
void ensureGroupIndexSubscription({
  required String indexName,
  required RdfGraph groupKeyGraph,
  bool triggerSync = true,
});

Future<void> ensureGroupIndexSynced({
  required String indexName,
  required RdfGraph groupKeyGraph,
});
```

The concrete shape may also use a single `IndexInstanceId` value object.

### 4b. Typed facade APIs (`ObjectSyncEngine`)

Add:

```dart
void ensureGroupIndexSubscription<G>(
  G groupKey, {
  bool triggerSync = true,
  String localName = defaultIndexLocalName,
});

Future<void> ensureGroupIndexSynced<G>(
  G groupKey, {
  String localName = defaultIndexLocalName,
});
```

Plus exception:

```dart
class GroupIndexSyncFailedException implements Exception {
  final String message;
  final IndexInstanceSyncState lastState;
  const GroupIndexSyncFailedException(this.message, {required this.lastState});
  @override
  String toString() => 'GroupIndexSyncFailedException: $message';
}
```

### Behavior

- `ensureGroupIndexSubscription` is idempotent and returns immediately.
- If `triggerSync == true`, it triggers a sync cycle only if initial sync is not complete.
- `ensureGroupIndexSynced` subscribes and awaits first state satisfying:
  - `hasCompletedInitialSync == true`, or
  - `hasInitialSyncError == true` (then throws `GroupIndexSyncFailedException`).

`ObjectSyncEngine` must implement these by mapping typed inputs to core identifiers and
delegating to `SyncEngine`, not by reimplementing lifecycle logic.

---

## Task 5 — Auto-subscribe-on-write (moved to core)

Implement in `SyncEngine.save(...)` / `StandardSyncEngine.save(...)`, not in
`ObjectSyncEngine.save(...)`.

### Required behavior

When saving a resource with one or more configured `GroupIndex` definitions:

1. Determine all matching group-index instances for the saved object.
2. Ensure subscription exists for **all** matching group-index instances.
3. Do this with `triggerSync = false` semantics (register interest only).
4. Continue with normal save.

This must be done in core so all entry points (object and lower-level graph flows) share
consistent behavior.

---

## Task 6 — Implementation guidance (architecture-safe)

### 6a. No backend downcasts

`locorda_objects` must not downcast to Drift DAOs.
All required operations must be available through core abstractions.

### 6b. State composition strategy

`ObjectSyncEngine` composes from core watchers; it does not infer lifecycle from unrelated
ETag tables.

Preferred architecture:

- Core emits canonical index-instance state into storage.
- Object layer maps core snapshot to `IndexInstanceSyncState` value objects.

### 6c. Lifecycle ownership

`SyncManager.statusStream` remains global progress signal and is **not** sufficient for
per-index-instance lifecycle.

Per-index-instance status comes from the new tracking model.

---

## Task 7 — Exports and barrels

- Export `IndexInstanceSyncState`, `RemoteSyncEntry`, `RemoteSyncPhase`,
  `GroupIndexSyncFailedException` from `locorda_objects` barrel.
- Re-export from top-level `locorda` barrel where appropriate.
- Keep `configureGroupIndexSubscription` available (optionally deprecated).

---

## Task 8 — Tests

### 8a. Pure value-object tests

Keep the previous matrix for getters (`hasCompletedInitialSync`, `isReady`, errors, etc.).

### 8b. Integration tests (core + object)

Cover:

1. No backend configured ⇒ immediate `local()` semantics.
2. New subscription with trigger sync ⇒ phase progression emits expected states.
3. Initial success ⇒ `hasCompletedInitialSync == true`.
4. Initial failure ⇒ `hasInitialSyncError == true`, `ensureGroupIndexSynced` throws.
5. Failure after success ⇒ `hasStaleError == true`, completion remains true.
6. Idempotent repeated ensure on already-synced instance.

### 8c. `createdAt` regression test

- Updating fetch policy for existing group subscription does not change `createdAt`.

### 8d. Auto-subscribe-on-write tests (core)

- Saving group-indexed object subscribes all matching group instances.
- Saving full-index-only object creates no group subscriptions.
- Repeated saves do not duplicate subscriptions.

### 8e. Storage abstraction tests

- Drift and in-memory implementations both satisfy new `Storage` sync-state APIs.

---

## Code quality requirements

- Extract shared watch logic into private helper(s), avoid duplication.
- No `print`, use structured logging.
- Public APIs fully documented for expert audience.
- Keep object layer thin; orchestration logic belongs in core.
- Run `dart analyze` and `dart test` with zero failures.

---

## Acceptance criteria

1. `SyncEngine` exposes core index-instance sync APIs (reactive + imperative)
  using core identifiers.
2. `ObjectSyncEngine` exposes typed facade APIs:
   - `watchGroupIndexSyncState<G>`
   - `watchTypeSyncState<T>`
   - `ensureGroupIndexSubscription<G>`
   - `ensureGroupIndexSynced<G>`
3. Per-index-instance lifecycle is tracked explicitly in core/storage
   (not inferred from ETag tables).
4. `SyncManager.statusStream` is not used as the canonical source for per-index-instance
   phase.
5. `save(...)` auto-subscribes all matching group-index instances in core (`SyncEngine`),
   with no implicit sync trigger.
6. Existing `configureGroupIndexSubscription(...)` remains functional.
7. Group subscription `createdAt` is stable across updates.
8. Tests and analysis pass without regressions.

---

## Files to create or modify

| File | Change |
|---|---|
| `packages/locorda_core/lib/src/storage/storage_interface.dart` | **Modify** — add index-instance sync-state API |
| `packages/locorda_core/lib/src/sync_engine.dart` | **Modify** — add core watch/ensure index-instance APIs |
| `packages/locorda_core/lib/src/standard_sync_engine.dart` | **Modify** — implement core watch/ensure APIs + auto-subscribe-on-write in save path |
| `packages/locorda_core/lib/src/storage/in_memory_storage.dart` | **Modify** — implement new storage API |
| `packages/locorda_drift/lib/src/sync_database.dart` | **Modify** — add persistence schema + preserve subscription `createdAt` |
| `packages/locorda_drift/lib/src/drift_storage.dart` | **Modify** — implement new storage API |
| `packages/locorda_core/lib/src/sync/remote_sync_orchestrator.dart` | **Modify** — write lifecycle transitions |
| `packages/locorda_objects/lib/src/index/index_instance_sync_state.dart` | **Create** — object-facing value model |
| `packages/locorda_objects/lib/src/index/group_index_sync_failed_exception.dart` | **Create** — exception |
| `packages/locorda_objects/lib/src/object_sync_engine.dart` | **Modify** — add object-facing watch/ensure APIs |
| `packages/locorda_objects/lib/locorda_objects.dart` | **Modify** — exports |
| `packages/locorda/lib/locorda.dart` | **Modify** — optional re-export |
| `packages/locorda_objects/test/index/index_instance_sync_state_test.dart` | **Create** |
| `packages/locorda_objects/test/index/watch_group_index_sync_state_test.dart` | **Create** |
| `packages/locorda_objects/test/index/ensure_group_index_subscription_test.dart` | **Create** |
| `packages/locorda_core/test/...` | **Modify/Create** — core lifecycle + save auto-subscribe tests |
| `packages/locorda_drift/test/...` | **Modify/Create** — drift storage/state + createdAt regression tests |

If test placement differs by current package conventions, adapt paths but keep coverage scope.
