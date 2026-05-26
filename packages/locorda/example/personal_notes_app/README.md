# Personal Notes App

**Bring your own persistence layer and make it syncable.**

This example demonstrates how to build an offline‑first Flutter app with Locorda as a **sync layer**. Your application owns its storage. Locorda only participates when you **save** or **delete** and when you **hydrate** remote changes into that storage.

---

## 1) Architecture at a glance

Locorda is intentionally *not* a persistence framework. This is the architecture of the example app (recommended, not enforced):

1. **Local storage** (Drift in this example)
2. **Repository layer** (sync‑aware storage)
3. **Service layer** (business rules)
4. **UI layer** (pure presentation)

Only the repository layer touches Locorda. UI and services remain free of sync details.

Locorda does not require this layering. It simply plays very well with it because it keeps sync concerns isolated and storage choices flexible.

---

## 2) The core contract: Locorda is a sync layer

### What you do
- Save *only* through Locorda: `syncEngine.save<T>(value)`
- Delete *only* through Locorda: `syncEngine.deleteDocument<T>(id)`
- Hydrate remote changes into your local storage: `hydrateWithCallbacks<T>()`

### What you own
- Data storage, schema, migrations
- Query performance and indexing strategy
- Domain modeling and business logic

This separation keeps your architecture clean, testable, and storage‑agnostic.

---

## 3) Main thread: initialize Locorda

In [lib/main.dart](lib/main.dart), the app creates Locorda with:

- `workerSetup` + `onWorkerSpawn` (for isolates / web workers)
- `remotes` (Solid, GDrive, local dir for testing/debugging only)
- `storage` (Drift main handler)
- `mapperInitializer` (generated RDF mapper)
- `LocordaConfig` (resources, indices, CRDT mappings)

Key excerpt (conceptual):

1. Provide remotes (must match worker setup)
2. Provide storage (local DB integration)
3. Provide resource config (CRDT mapping + indices)

Locorda setup happens once; after that, your UI never calls remote APIs (Solid/GDrive) or performs CRDT merges directly.

---

## 4) Worker thread: isolate heavy work

In [lib/worker.dart](lib/worker.dart), the worker creates the runtime for sync, HTTP, and local storage.

The worker setup mirrors main thread choices:

- Remote handlers (Solid / GDrive / local dir for testing/debugging only)
- Storage handler (Drift worker storage, web options)

This keeps the UI thread lean and avoids expensive operations on the main isolate.

---

## 5) Repository layer: the sync integration point

The repository layer is the **only** place where Locorda is used. It performs two responsibilities:

1. **Hydration**: listen to remote changes and store them locally
2. **Write‑through**: save or delete via Locorda, not via direct DB writes

### Hydration

In [lib/storage/repositories.dart](lib/storage/repositories.dart), each repository calls:

- `syncEngine.hydrateWithCallbacks<T>()`
- `getCurrentCursor()` reads the last sync cursor
- `onUpdate()` writes to local DB
- `onDelete()` removes from local DB
- `onCursorUpdate()` persists the cursor

This is how your local database is kept in sync with remote changes.

### Write‑through

Every mutation goes through Locorda:

- `syncEngine.save<Note>(note)`
- `syncEngine.deleteDocument<Note>(id)`

Local DB updates are handled by hydration callbacks. You never “double‑write” manually.

---

## 6) Service layer: business logic only

In [lib/services](lib/services), services handle domain rules (filtering, grouping, ID generation) but have no sync logic.

Example flow:

1. UI requests an update
2. Service validates or enriches
3. Repository saves through Locorda

This makes it easy to test and refactor business rules without touching sync code.

---

## 7) UI layer: integration without sync coupling

The UI receives:

- repositories/services for data
- `uiAdapterRegistry` for Locorda UI components
- `syncManager` for sync status actions

See [lib/main.dart](lib/main.dart) where `NotesListScreen` gets those dependencies. The UI stays free of CRDT details.

---

## 8) Indices and fetch: two independent dimensions

Locorda fetch behavior is defined by two orthogonal choices:

### What to fetch (selection)

- **FullIndex**: all items of a resource type
- **GroupIndex**: a subset of items, grouped by a key (e.g. by month)

### When to fetch (timing)

- `RootResourceFetchPolicy.prefetch`: fetch automatically
- `RootResourceFetchPolicy.onRequest`: fetch only when requested (see section 9 for required app patterns)

In this example:

- Notes use a `GroupIndex` grouped by month
- Categories use a `FullIndex` with `RootResourceFetchPolicy.prefetch`

Repository method `ensureMonthGroupSubscription()` applies the timing policy based on UI filters.

---

## 9) Advanced: on‑request fetch and index header data

This is optional and only needed when your backend stores **each item as its own resource** (e.g. Solid). If your backend stores **whole shards as a single file** (e.g. GDrive), this is usually not necessary.

### On‑request fetch requires `ensure()`

If a resource (or group) is configured with `RootResourceFetchPolicy.onRequest`, you must **not** read it directly from local storage. Wrap the read in `syncEngine.ensure<T>()` so Locorda can fetch missing data on demand.

Example pattern (see `NoteRepository.getNote`):

1. Call `syncEngine.ensure<Note>(id, loadFromLocal: ...)`
2. Provide a local‑DB loader for the fast path
3. Let Locorda fetch if the item is not available locally

### Index header data (why `NoteIndexEntry` exists)

Group/Full indices can expose **header data**: a lightweight projection of a resource that is always available even when full items are not.

In this example:

- `NoteIndexEntry` duplicates selected `Note` fields
- `watchAllNoteIndexEntries()` reads that lightweight index data
- The UI can list notes without fetching every full `Note`

Use this when listing needs to be fast and full items are expensive to load, especially with per‑item storage backends.

---

## 10) Practical checklist for a new app

1. **Choose storage** (Drift, Isar, Hive, custom)
2. **Create repositories** that:
   - hydrate via `hydrateWithCallbacks<T>()`
   - save/delete via Locorda only
3. **Create services** for business logic
4. **Configure Locorda**:
   - remotes and storage handlers
   - `mapperInitializer` for RDF mapping
   - `LocordaConfig` with CRDT mappings and indices
5. **Inject into UI**: pass services + `syncManager`

---

## 11) Security note

This example includes secure OAuth/OIDC redirect URI configuration. See [spec/docs/SECURITY.md](../../../spec/docs/SECURITY.md) for platform‑specific guidance.

---

## 12) Running the example

Prerequisites:

- Flutter 3.24.0+
- Dart 3.6.0+

### Google Drive Setup (Optional)

Google Drive credentials are configured differently per platform.

#### Windows & Linux

1. Copy the template secrets file:
   ```bash
   cp secrets.json.example secrets.json
   ```
2. Populate `secrets.json` with your Google Cloud Console credentials (type **Desktop application**).
3. `secrets.json` is in `.gitignore` so your keys will never be committed.

#### Android, iOS, macOS, Web

Credentials come from platform-native config files — do **not** use `--dart-define-from-file=secrets.json` on these platforms. That would inject a Desktop-type client ID which the native auth flow doesn't use and could interfere with.

See the [locorda_gdrive OAuth2 Setup](https://pub.dev/packages/locorda_gdrive) guide for platform-specific instructions (bundle ID / package name / SHA-1 fingerprint / web meta tag).

### Run on Native Desktop/Mobile:

- `flutter pub get`
- `dart run build_runner build`
- Linux/Windows (Google Drive requires `secrets.json`):
  ```bash
  flutter run -d linux --dart-define-from-file=secrets.json
  ```
  *(replace `linux` with `windows` as needed)*
- macOS/mobile (Google Drive uses native credentials):
  ```bash
  flutter run -d macos
  ```
  *(replace `macos` with `android` or `ios` as needed)*

### Web:

- `flutter pub get`
- `dart run build_runner build`
- `./setup_web.sh`
- `flutter run -d chrome --web-port=8080`

---

## 13) Key takeaways

1. **Locorda is a sync layer** — not a database.
2. **Repositories are the integration point** — hydrate + write‑through.
3. **UI stays clean** — no CRDT or remote logic in widgets.
4. **Storage is your choice** — Locorda adapts to it.

If you understand these principles, you can scale this pattern from a tiny app to a complex multi‑resource product without changing your storage stack.