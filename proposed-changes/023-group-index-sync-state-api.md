# 023 — Group Index Sync State API

## Summary

Add three APIs to `ObjectSyncEngine` and one behavioral change to `save()` that allow
applications to observe per-index-instance sync state reactively and to subscribe to / await
group index instances.

These four changes are required by `locorda/chat-essence` and formally specified in
`docs/sync/group-index-subscription-lifecycle.md` and
`docs/tmp-group-index-discussions.md` (section 4) in that repository.

---

## Background and Terminology

**Index instance** — the unit of sync state. A full-index type has exactly one index
instance. A group-index type has one index instance per subscribed group key (one per
`(channelId, yearMonth)` combination, for example). `RemoteSyncState` tracks sync state
per *document × remote*, so deriving per-index-instance state requires joining
`GroupIndexSubscriptions` + `RemoteSyncState` + `RemoteSettings`.

**Initial sync completion** — an index instance has completed its initial sync for a
remote when at least one `RemoteSyncState` row for a document belonging to that index
instance (and that remote) has `lastSyncedAt > groupIndexSubscriptions.createdAt`. More
practically: after the first successful sync cycle that covers this index instance, a
`lastSyncedAt` timestamp exists for that remote. The predicate
`IndexInstanceSyncState.hasCompletedInitialSync` is vacuously true when `perRemote` is
empty (no backends configured) — correct, because local data is authoritative in that
case.

**Why this does not live in app code** — `ensureGroupIndexSubscription` must check
`hasCompletedInitialSync` and trigger sync atomically without a race condition. Any app
implementing this externally re-implements the same logic with the same race. Both
`ensureGroupIndexSubscription` and `ensureGroupIndexSynced` belong inside the engine
where the primitives live.

---

## Scope

All changes are in the `locorda_objects` package (`ObjectSyncEngine`), with supporting
data-model classes either in `locorda_objects` or a new file in `locorda_core` (your
choice — keep the dependency direction unchanged: `locorda_objects` may depend on
`locorda_core`, not the other way around).

The existing low-level method `configureGroupIndexSubscription<G>(G, ItemFetchPolicy)`
remains as an internal/deprecated method. Do **not** remove it — it may be called
internally by the new APIs. Do **not** expose it in new public DartDoc as the primary
API.

---

## Task 1 — Data Model

Create the following classes in a new file, e.g.
`locorda_objects/lib/src/index/index_instance_sync_state.dart`:

```dart
/// Sync phase for a single remote × index instance combination.
enum RemoteSyncPhase {
  /// Subscribed, but this remote has never synced this index instance.
  /// Covers: (a) newly subscribed group while backend active, (b) new backend
  /// connected after subscription existed, (c) full-index type on first sync.
  notSynced,

  /// Global sync cycle started; this index instance is queued but not yet processing.
  syncPlanned,

  /// Actively transferring this index instance for this remote right now.
  syncing,

  /// Last sync after subscription completed successfully.
  ready,

  /// Last sync attempt failed (network, auth, timeout).
  /// Distinguish sub-cases via [RemoteSyncEntry.lastSyncedAt].
  error,
}

/// Per-remote sync state snapshot for one index instance.
@immutable
class RemoteSyncEntry {
  final String remoteId;
  final RemoteSyncPhase phase;

  /// Set when [phase] == [RemoteSyncPhase.syncing].
  final DateTime? syncStartedAt;

  /// Null: initial sync never completed for this remote (data may be absent).
  /// Non-null: data is present but may be stale if [phase] == [RemoteSyncPhase.error].
  final DateTime? lastSyncedAt;

  /// Set when [phase] == [RemoteSyncPhase.error].
  final String? errorMessage;

  const RemoteSyncEntry({
    required this.remoteId,
    required this.phase,
    this.syncStartedAt,
    this.lastSyncedAt,
    this.errorMessage,
  });
}

/// Aggregate sync state for one index instance across all configured remotes.
///
/// An "index instance" is either a full-index type's single instance or one
/// group key of a group-index type (e.g. one `(channelId, yearMonth)` shard).
@immutable
class IndexInstanceSyncState {
  /// Keyed by remoteId. Empty when no backend is configured.
  final Map<String, RemoteSyncEntry> perRemote;

  const IndexInstanceSyncState({required this.perRemote});

  /// Empty state — no backend configured; data is local-only.
  const IndexInstanceSyncState.local() : perRemote = const {};

  /// Any remote is actively transferring or queued.
  bool get isSyncing => perRemote.values.any(
        (e) =>
            e.phase == RemoteSyncPhase.syncing ||
            e.phase == RemoteSyncPhase.syncPlanned,
      );

  /// All remotes are in the `ready` phase — no errors, no pending work.
  ///
  /// Usually too strict as a display/analysis gate because a transient network
  /// error reverts this to false even though data is still present.
  /// Prefer [hasCompletedInitialSync] for display and analysis gates.
  bool get isReady =>
      perRemote.isNotEmpty &&
      perRemote.values.every((e) => e.phase == RemoteSyncPhase.ready);

  /// Practical gate for data completeness (Rules 1 and 2 in chat-essence):
  /// every configured remote has [RemoteSyncEntry.lastSyncedAt] != null,
  /// meaning the initial sync completed at least once.
  ///
  /// Data is present on this device, though it may be stale if [hasStaleError].
  /// A subsequent sync error does **not** revert this to false — data is still
  /// available, just potentially outdated.
  ///
  /// Vacuously true when [perRemote] is empty (no backend configured) — correct:
  /// local data is authoritative; there is nothing to sync.
  bool get hasCompletedInitialSync =>
      perRemote.values.every((e) => e.lastSyncedAt != null);

  bool get hasError =>
      perRemote.values.any((e) => e.phase == RemoteSyncPhase.error);

  /// Error on a remote that previously completed initial sync — data present but stale.
  bool get hasStaleError => perRemote.values.any(
        (e) => e.phase == RemoteSyncPhase.error && e.lastSyncedAt != null,
      );

  /// Error on a remote that never completed initial sync — data may be absent.
  bool get hasInitialSyncError => perRemote.values.any(
        (e) => e.phase == RemoteSyncPhase.error && e.lastSyncedAt == null,
      );

  /// True if any remote has never successfully synced (inverse of [hasCompletedInitialSync]).
  bool get hasUnsyncedRemote =>
      perRemote.values.any((e) => e.lastSyncedAt == null);
}
```

### Requirements for Task 1

- All classes are **immutable** (`@immutable`, `const` constructors where possible).
- Override `==` and `hashCode` (or use `package:equatable` if already in the dep tree)
  on both `RemoteSyncEntry` and `IndexInstanceSyncState`.
- Export both classes and the enum from the `locorda_objects` public barrel.
- Do **not** add `freezed` or `json_serializable` unless they are already used elsewhere
  in `locorda_objects` — keep the dependency footprint minimal.

---

## Task 2 — `watchGroupIndexSyncState` and `watchTypeSyncState`

Add two reactive methods to `ObjectSyncEngine` that expose `Stream<IndexInstanceSyncState>`.

### 2a. `watchGroupIndexSyncState<G>`

```dart
/// Reactively observes the sync state of the index instance for [groupKey].
///
/// Emits a new [IndexInstanceSyncState] whenever subscription status, remote
/// sync state, or the running sync cycle changes for this index instance.
///
/// Returns [IndexInstanceSyncState.local()] immediately when no backend is
/// configured (`perRemote` is empty → [hasCompletedInitialSync] is vacuously
/// true). The stream may emit multiple times during a sync cycle as individual
/// phases transition.
///
/// Useful as a driver for loading indicators and data completeness gates.
/// Combine with repository streams via [StreamBuilder] — do not poll.
Stream<IndexInstanceSyncState> watchGroupIndexSyncState<G>(G groupKey,
    {String localName = defaultIndexLocalName});
```

### 2b. `watchTypeSyncState<T>`

```dart
/// Reactively observes the sync state of the index instance for the full-index
/// type [T].
///
/// Semantics identical to [watchGroupIndexSyncState]; applicable to types that
/// use a full index (i.e. do not use `FullIndex.disabled()`).
Stream<IndexInstanceSyncState> watchTypeSyncState<T>();
```

### Implementation guidance for Task 2

Derive `IndexInstanceSyncState` by combining:

1. **`watchSubscribedGroupIndexIris(templateIri)`** (already on `DriftStorage`) —
   emits the set of shard IRIs belonging to this index instance whenever subscriptions
   change. For a full-index type, derive the equivalent IRI set from the type IRI
   without a subscription lookup.

2. **`RemoteSyncStateDao`** — join `RemoteSyncState` × `RemoteSettings` to get, per
   remote: the set of documents that belong to the index instance's shard IRI(s), their
   `lastSyncedAt`, and the `GroupIndexSubscriptions.createdAt` for the instance. A remote
   has completed initial sync for this index instance if it has at least one
   `RemoteSyncState` row with `lastSyncedAt > subscription.createdAt` for a shard
   belonging to this instance. Alternatively, look only at the index shard document
   itself (the `idx:Index` document for the instance) — prefer the simplest query that
   gives a correct answer.

3. **`SyncManager.statusStream`** — maps the global `SyncState` to a per-remote phase
   (`syncPlanned` / `syncing`) for the current sync cycle. Merge with the Drift-derived
   state: if the global sync is running **and** this index instance is in `notSynced` or
   `ready`, elevate to `syncPlanned` / `syncing` as appropriate.

Combine the three sources with `Rx.combineLatest` (from `package:rxdart`, already a
dependency) or a manual `switchMap` chain. Ensure the stream:

- Is a **broadcast** stream (multiple listeners, widget rebuilds).
- Emits synchronously with the last known state on new subscription (use
  `BehaviorSubject` or `startWith`).
- Closes cleanly when `ObjectSyncEngine.close()` is called.

> [!NOTE]
> Rough edge — verify before shipping: the `switchMap` in `hydrateStream` for group
> index types may drop previously loaded shards when a new subscription is added
> mid-session. In `watchGroupIndexSyncState` use `combineLatest` or `mergeAll` rather
> than `switchMap` over subscription changes, so existing shard state is not dropped
> when a new shard is subscribed.

---

## Task 3 — `ensureGroupIndexSubscription`

Add to `ObjectSyncEngine`:

```dart
/// Subscribes [groupKey] if not already subscribed.
///
/// With [triggerSync] true (the default), also starts a sync cycle for all
/// active remotes if [IndexInstanceSyncState.hasCompletedInitialSync] is false.
/// Returns immediately — does not wait for sync to complete.
///
/// Observe [watchGroupIndexSyncState] for progress and completion; pair with a
/// [StreamBuilder] in widget contexts to drive loading indicators.
///
/// No-op if the index instance is already fully synced. Safe to call on every
/// widget mount or scroll event without debouncing.
///
/// Pass [triggerSync: false] to register a subscription without starting sync
/// (e.g. background interest registration where sync timing is managed
/// externally).
void ensureGroupIndexSubscription<G>(G groupKey,
    {bool triggerSync = true, String localName = defaultIndexLocalName});
```

### Implementation guidance for Task 3

```
1. Convert groupKey → (indexName, groupKeyGraph) via _groupKeyConverter.convertGroupKey.
2. Call the existing configureGroupIndexSubscription(indexName, groupKeyGraph, ItemFetchPolicy.prefetch)
   — this is idempotent (creates the DB row if absent, updates fetch policy otherwise).
3. If triggerSync == true:
   a. Read the current IndexInstanceSyncState (one-shot, not watching).
   b. If !state.hasCompletedInitialSync, call syncManager.sync() unawaited
      (fire-and-forget — the state stream drives the UI).
```

**Idempotency**: Step 2 is already idempotent per the existing `configureGroupIndexSubscription`
contract. Step 3b must not trigger a redundant sync if `hasCompletedInitialSync` is
already true — the check in step 3a guards this.

**No `async`** on the method signature — it returns `void` synchronously. Internally
schedule the subscription + conditional sync without awaiting them on the call path.
Use `unawaited(Future<void>)` with appropriate error logging for any async steps.

---

## Task 4 — `ensureGroupIndexSynced`

Add to `ObjectSyncEngine`:

```dart
/// Calls [ensureGroupIndexSubscription], then waits until
/// [IndexInstanceSyncState.hasCompletedInitialSync] is true or
/// [IndexInstanceSyncState.hasInitialSyncError] is true.
///
/// Throws [GroupIndexSyncFailedException] if any remote fails an initial sync
/// (offline, timeout, auth error). The caller must catch and handle this.
///
/// Prefer [ensureGroupIndexSubscription] + stream observation in widget contexts
/// (no `await` in `build`). Use this method in button handlers, tests, and
/// sequential setup code where a simple `Future<void>` is cleaner.
Future<void> ensureGroupIndexSynced<G>(G groupKey,
    {String localName = defaultIndexLocalName});
```

Create the exception class:

```dart
/// Thrown by [ObjectSyncEngine.ensureGroupIndexSynced] when the initial sync
/// fails for at least one remote before [hasCompletedInitialSync] is satisfied.
class GroupIndexSyncFailedException implements Exception {
  final String message;
  final IndexInstanceSyncState lastState;
  const GroupIndexSyncFailedException(this.message, {required this.lastState});
  @override
  String toString() => 'GroupIndexSyncFailedException: $message';
}
```

### Implementation guidance for Task 4

```dart
Future<void> ensureGroupIndexSynced<G>(G groupKey,
    {String localName = defaultIndexLocalName}) async {
  ensureGroupIndexSubscription(groupKey,
      triggerSync: true, localName: localName);
  await watchGroupIndexSyncState<G>(groupKey, localName: localName)
      .firstWhere((state) =>
          state.hasCompletedInitialSync || state.hasInitialSyncError)
      .then((state) {
    if (state.hasInitialSyncError) {
      throw GroupIndexSyncFailedException(
        'Initial sync failed for one or more remotes.',
        lastState: state,
      );
    }
  });
}
```

---

## Task 5 — Auto-subscribe-on-write in `save()`

Modify the existing `save<T>(T object)` method in `ObjectSyncEngine`:

**Before returning**, check whether `T` is a group-indexed resource. If it is, derive
the group key from the object being saved and call
`ensureGroupIndexSubscription(groupKey, triggerSync: false)` imperatively before (or
immediately after) delegating to `_syncSystem.save(typeIri, graph)`.

### Implementation guidance for Task 5

1. After encoding `object` to `graph`, check if the resource config for `T` has a
   `GroupIndex` configured (via `_config.getResourceConfig(T)?.indices` — filter for
   `GroupIndex` entries).
2. If yes, decode the group key value from the object using `_groupKeyConverter` or
   directly via the mapper (the group key properties are declared in `GroupIndex`).
3. Call `ensureGroupIndexSubscription(derivedGroupKey, triggerSync: false)`.
4. Proceed with `_syncSystem.save(typeIri, graph)` as before.

**Important**: use `triggerSync: false` — the `save()` call itself is not the right
place to trigger sync; the caller controls that. Auto-subscribe-on-write only ensures
the subscription DB row exists so that the saved record will be included in the next
sync cycle, whenever that happens.

> [!NOTE]
> If deriving the group key from the object proves complex (multiple group index
> configs, polymorphic group key types), it is acceptable to fall back to calling
> `configureGroupIndexSubscription` at the lower level with the index name and RDF
> graph directly. The key invariant is: after `save()` returns, the index instance for
> the saved object's group key is subscribed.

---

## Task 6 — Exports and Barrel Updates

- Export `IndexInstanceSyncState`, `RemoteSyncEntry`, `RemoteSyncPhase`,
  `GroupIndexSyncFailedException` from `locorda_objects/lib/locorda_objects.dart` (or
  whatever the package barrel is).
- Update `locorda/lib/locorda.dart` (the top-level package) to re-export the new types
  if it re-exports from `locorda_objects`.
- Do **not** remove `configureGroupIndexSubscription` from the public barrel yet — it
  may stay as a lower-level escape hatch for advanced callers. Mark it
  `@Deprecated('Use ensureGroupIndexSubscription instead.')` if you prefer to signal
  the migration direction.

---

## Task 7 — Unit Tests

Write tests in `locorda_objects/test/`. All tests must follow the DI pattern used by
the rest of the package: create dependencies manually, never use `setUp`/global
singletons that leak between tests, and call `dispose()`/`close()` in `tearDown`.

### 7a. `IndexInstanceSyncState` unit tests (pure Dart, no DB)

Test all computed getters with known `perRemote` maps:

| Scenario | `hasCompletedInitialSync` | `isSyncing` | `isReady` | `hasStaleError` | `hasInitialSyncError` |
|---|---|---|---|---|---|
| Empty map (no backend) | true | false | false | false | false |
| One remote, `ready`, `lastSyncedAt` set | true | false | true | false | false |
| One remote, `syncing`, no `lastSyncedAt` | false | true | false | false | false |
| One remote, `error`, `lastSyncedAt` set | true | false | false | true | false |
| One remote, `error`, no `lastSyncedAt` | false | false | false | false | true |
| Two remotes: one `ready` (synced), one `notSynced` (not synced) | false | false | false | false | false |
| Two remotes: both `ready`, both synced | true | false | true | false | false |

### 7b. `watchGroupIndexSyncState` integration tests (with fake SyncEngine)

Use a fake or in-memory `SyncEngine` (check whether `locorda_core/test/` already has a
`FakeSyncEngine` or `InMemorySyncEngine` — use whatever pattern the existing tests use
for integration tests).

Scenarios to cover:

1. **No backend configured**: stream immediately emits `IndexInstanceSyncState.local()`
   with `hasCompletedInitialSync == true`.
2. **Backend configured, group not yet subscribed**: calling
   `ensureGroupIndexSubscription(groupKey)` causes the stream to emit a state with
   `hasCompletedInitialSync == false` and `isSyncing == true` (sync triggered).
3. **Subscription + sync completes**: after the fake sync cycle completes, stream emits
   `hasCompletedInitialSync == true`.
4. **Sync error on first attempt (no `lastSyncedAt`)**: stream emits
   `hasInitialSyncError == true`; `ensureGroupIndexSynced` throws
   `GroupIndexSyncFailedException`.
5. **Sync error after initial success (`lastSyncedAt` set)**: stream emits
   `hasStaleError == true` but `hasCompletedInitialSync` remains `true`.
6. **Second subscription on already-complete instance**: `ensureGroupIndexSynced` returns
   without triggering another sync.

### 7c. `ensureGroupIndexSubscription` tests

- Verify that calling it twice with the same group key does not create duplicate
  subscriptions in the DB.
- Verify that `triggerSync: false` does not call `syncManager.sync()`.
- Verify that `triggerSync: true` (default) calls `syncManager.sync()` exactly once when
  `!hasCompletedInitialSync`, and zero times when already synced.

### 7d. `ensureGroupIndexSynced` tests

- Happy path: resolves when `hasCompletedInitialSync` becomes true.
- Error path: throws `GroupIndexSyncFailedException` when `hasInitialSyncError` is true.
- Timeout: if the sync engine hangs indefinitely (all remotes stuck in `syncing`),
  `ensureGroupIndexSynced` must not hang the test — inject a timeout or document that
  callers are responsible for wrapping with `Future.timeout`.

### 7e. Auto-subscribe-on-write tests

- Saving a group-indexed object via `save()` creates the subscription in the DB even
  though `ensureGroupIndexSubscription` was never called explicitly.
- Saving a full-index object via `save()` does **not** create a spurious group
  subscription.
- Two saves for the same group key do not create duplicate subscriptions.

---

## Code Quality Requirements

- **Zero tolerance for code duplication**: if `watchGroupIndexSyncState` and
  `watchTypeSyncState` share more than trivially similar logic, extract the shared
  stream-building logic into a private method `_watchIndexInstanceSyncState(...)`.
- **No `print` statements** — use `package:logging` with a named logger
  (`Logger('Locorda.groupIndex')`).
- **DartDoc on all public symbols** — explain *why*, not *what*. Target audience: expert
  Dart/Flutter developers who understand CRDT sync.
- **Immutable value objects** — `IndexInstanceSyncState` and `RemoteSyncEntry` must be
  `@immutable`. No mutable state; derive everything from DB queries.
- **File size**: if `object_sync_engine.dart` grows beyond ~900 lines, extract the
  group-index stream logic into a separate mixin or helper class.
- Run `dart analyze` and `dart test` before considering the implementation complete.
  Zero warnings, zero failing tests.

---

## Acceptance Criteria

1. `ObjectSyncEngine` exposes `watchGroupIndexSyncState<G>`, `watchTypeSyncState<T>`,
   `ensureGroupIndexSubscription<G>`, and `ensureGroupIndexSynced<G>` with the exact
   signatures specified above.
2. `IndexInstanceSyncState.hasCompletedInitialSync` returns `true` immediately when no
   backend is configured.
3. `ensureGroupIndexSynced` throws `GroupIndexSyncFailedException` (not a generic
   `Exception`) on initial sync failure.
4. Calling `save<T>(obj)` on a group-indexed object implicitly subscribes the group
   index instance (with `triggerSync: false`).
5. All tests in Task 7 pass.
6. `dart analyze` reports zero issues.
7. The existing `configureGroupIndexSubscription` method continues to work and existing
   tests continue to pass (no regression).

---

## Files to Create or Modify

| File | Change |
|---|---|
| `locorda_objects/lib/src/index/index_instance_sync_state.dart` | **Create** — data model (Task 1) |
| `locorda_objects/lib/src/index/group_index_sync_failed_exception.dart` | **Create** — exception (Task 4) |
| `locorda_objects/lib/src/object_sync_engine.dart` | **Modify** — add Tasks 2–5 |
| `locorda_objects/lib/locorda_objects.dart` | **Modify** — export new types (Task 6) |
| `locorda_objects/test/index/index_instance_sync_state_test.dart` | **Create** — Task 7a |
| `locorda_objects/test/index/watch_group_index_sync_state_test.dart` | **Create** — Tasks 7b–7d |
| `locorda_objects/test/index/auto_subscribe_on_write_test.dart` | **Create** — Task 7e |

If `locorda/lib/locorda.dart` re-exports `locorda_objects` types, update it accordingly.
