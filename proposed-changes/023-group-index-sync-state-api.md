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

### Migration scope (no compatibility layer)

- Remove the old low-level `configureGroupIndexSubscription(...)` API from public
  `SyncEngine` and `ObjectSyncEngine` surfaces.
- Migrate all in-repo call sites to the new `ensure*` API set.
- Update tests/docs/examples to use only the new APIs.

---

## Task 0 — Correctness bug fix (required)

### 0a. Preserve original subscription creation timestamp

`saveGroupIndexSubscription` currently uses `insertOnConflictUpdate`, which can overwrite
`createdAt` for existing subscriptions.

That is incorrect for lifecycle semantics and can break temporal reasoning.

**Required behavior**:

- On first insert: set `createdAt`.
- On conflict update: update mutable fields (for example `rootResourceFetchPolicy`) but **do not**
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

### 6d. Worker/proxy stream lifecycle (required)

`SyncEngine` may run in a worker (`StandardSyncEngine`) while the app uses
`ProxySyncEngine` on the main thread. Therefore `watch**State` must be fully supported
across the worker boundary.

Required protocol/behavior:

1. **Explicit subscribe + explicit unsubscribe**
  - Add worker messages for watch registration and cancellation.
  - Main-thread stream cancellation must propagate to worker and cancel the worker-side
    subscription.
2. **Initial state delivery without race**
  - `watch**State` must deliver a current snapshot immediately after subscription.
  - Subscription establishment and initial snapshot must be atomic from API perspective
    (no lost transition between subscribe and first event).
3. **Broadcast semantics on main thread**
  - Proxy-exposed streams must support multiple listeners safely.
  - Re-listeners should receive the latest known state synchronously (or via a documented
    immediate first async event) without requiring a new worker subscription per listener.
4. **Deterministic cleanup**
  - Worker must cancel all active watch subscriptions on engine close/dispose.
  - Proxy must clear controllers/subscriptions and complete pending listeners with close,
    not leaks.
5. **Request correlation and isolation**
  - Stream update messages must be correlated by watch/request ID.
  - Updates for unknown/cancelled request IDs must be ignored safely.

This is mandatory to avoid stale listeners, memory leaks, and hidden worker load in
long-running Flutter sessions.

### 6e. Worker protocol mini-spec (normative)

Define and document explicit worker protocol messages for index-instance watch streams.
Exact names may differ, but semantics are mandatory.

#### Required message families

1. **Subscribe request (Main → Worker)**
  - Fields:
    - `requestId` (unique per active watch)
    - `watchKind` (`groupIndex` | `typeIndex`)
    - watch parameters (canonical core identifiers)
2. **State update event (Worker → Main)**
  - Fields:
    - `requestId`
    - serialized index-instance sync state snapshot
    - `isInitial` flag (true for first event after subscription)
3. **Unsubscribe request (Main → Worker)**
  - Fields:
    - `requestId`
4. **Optional unsubscribe ack/error (Worker → Main)**
  - Recommended for diagnostics and deterministic tests.

#### Required behavioral guarantees

1. **Atomic subscribe+initial snapshot**
  - After subscribe is accepted, worker must emit one initial snapshot (`isInitial=true`)
    representing current known state.
  - No state transition between registration and first emission may be lost.
2. **Monotonic per-request ordering**
  - Worker must send updates in source order for a given `requestId`.
3. **Idempotent unsubscribe**
  - Unsubscribe for unknown/already-closed `requestId` is a no-op.
4. **No post-cancel deliveries**
  - After unsubscribe processing, worker stops emitting for that `requestId`.
  - Main ignores late in-flight events safely.
5. **Error delivery contract**
  - Watch errors are delivered as terminal stream error (or explicit error event followed
    by completion), never silently dropped.

#### Multiplexing and deduplication rules

- Proxy may deduplicate equivalent watch keys across multiple local listeners.
- If deduplicated:
  - maintain exactly one worker subscription per canonical watch key,
  - fan out updates to all local listeners,
  - send unsubscribe to worker only when the last local listener cancels.
- If no deduplication is implemented, behavior must still be correct and leak-free.

#### Close/dispose contract

- On `ProxySyncEngine.close()`:
  - cancel all local watch controllers,
  - send unsubscribe for all active worker watches (best effort),
  - clear watch registries.
- On worker context dispose:
  - cancel all active watch subscriptions before closing `SyncEngine`.

#### Testability requirements

Add protocol-level tests that validate:

- initial snapshot emission,
- no lost first update under rapid subscribe/sync transitions,
- unsubscribe propagation,
- no events after cancel,
- dedup correctness (if enabled).

---

## Task 7 — Exports and barrels

- Export `IndexInstanceSyncState`, `RemoteSyncEntry`, `RemoteSyncPhase`,
  `GroupIndexSyncFailedException` from `locorda_objects` barrel.
- Re-export from top-level `locorda` barrel where appropriate.
- Do not export `configureGroupIndexSubscription` as part of the public API.

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

### 8f. Worker/proxy stream lifecycle tests

- Cancelling a main-thread `watch**State` subscription sends unsubscribe to worker and
  stops worker-side updates.
- New subscription receives current state immediately (no missing initial emission).
- Multiple UI listeners on proxy stream do not create duplicate worker subscriptions.
- Closing `ProxySyncEngine`/worker context cancels all active watch subscriptions cleanly.
- Late events for cancelled watch IDs are ignored without exceptions.

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
6. Old `configureGroupIndexSubscription(...)` public API is removed and all usages are
  migrated to new APIs.
7. Group subscription `createdAt` is stable across updates.
8. Tests and analysis pass without regressions.
9. Worker/proxy execution path supports `watch**State` with explicit unsubscribe and no
  subscription leaks.

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
| `packages/locorda_worker/lib/src/shared/worker_messages.dart` | **Modify** — add watch/subscribe/unsubscribe message types |
| `packages/locorda_worker/lib/src/worker/worker_entry_point.dart` | **Modify** — manage worker-side watch subscriptions and cleanup |
| `packages/locorda_worker/lib/src/main/proxy_sync_engine.dart` | **Modify** — bridge watch streams with broadcast + cancellation |
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
