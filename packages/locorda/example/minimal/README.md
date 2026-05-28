# Minimal Locorda Example

A minimal task sync app demonstrating Locorda's core concepts.

## What this shows

- **Automatic sync** - Changes sync across devices without backend code
- **Offline-first** - App works fully offline, syncs when connected
- **Conflict-free** - Multiple devices can edit simultaneously, conflicts resolve automatically
- **Plain Dart objects** - No special base classes or complex model definitions
- **Repository pattern** - Clean separation: UI ↔ local storage ↔ sync engine

## Getting started

Add dependencies:

```bash
# Core package (includes annotations)
dart pub add locorda

# Testing remote (replace with Solid Pods or Google Drive in production)
dart pub add locorda_dir

# Development tools for code generation
dart pub add --dev build_runner locorda_dev
```

Annotate your models, then run code generation:

```bash
dart run build_runner build
```

## Architecture

```
UI Layer (Flutter)
    ↓
TaskRepository (sync-aware storage)
    ↓
Locorda SyncEngine
    ↓ 
 Worker Thread  ←→  Local Dir Remote (testing only)
```

## Key files

### Task model for sync

<?code-excerpt "lib/task.dart (task-model)"?>
```dart
/// A simple task that syncs across devices.
@RootResource(AppVocab(appBaseUri: 'https://locorda.dev/example/minimal'))
class Task {
  /// Unique ID for this task
  @RdfIriPart()
  final String id;

  /// Task title
  final String title;

  /// Completion status
  final bool completed;

  /// Creation timestamp
  final DateTime createdAt;

  Task({
    required this.id,
    required this.title,
    this.completed = false,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  Task copyWith({String? title, bool? completed}) => Task(
        id: id,
        title: title ?? this.title,
        completed: completed ?? this.completed,
        createdAt: createdAt,
      );
}

```

**What the annotations do:**
- `@RootResource(AppVocab(...))` - Makes this class syncable across devices
- `@RdfIriPart()` - Marks `id` as the unique identifier for sync
- Conflict resolution rules are auto-generated from these annotations (see "Understanding Conflicts" below)

### Repository: connecting sync to your app

<?code-excerpt "lib/task_repository.dart (repository)"?>
```dart
/// Repository integrating local storage with Locorda sync.
///
/// This example uses a simple Map as a mock database. In a real app,
/// you'd use your preferred storage solution (Drift, Hive, Isar, etc.)
/// and connect it to sync via the same callback pattern.
class TaskRepository {
  final ObjectSyncEngine _syncEngine;
  final Map<String, Task> _tasks =
      {}; // Mock DB - use Drift/Hive/etc. in real apps
  final StreamController<List<Task>> _controller = StreamController.broadcast();
  StreamSubscription? _hydrationSubscription;

  TaskRepository._(this._syncEngine);

  /// Create and initialize repository with sync.
  static Future<TaskRepository> create(ObjectSyncEngine syncEngine) async {
    final repo = TaskRepository._(syncEngine);

    // Connect your local storage to sync via callbacks.
    //
    // IMPORTANT: These callbacks are your "single source of truth" for data updates.
    // ALL changes (local saves, remote sync, conflict resolution) flow through these
    // callbacks. This ensures your UI always shows the merged, conflict-free state.
    //
    // - onUpdate: Save/update items in your local database
    // - onDelete: Remove deleted items from your local database
    // - getCurrentCursor: Track last sync position (for efficient incremental sync)
    repo._hydrationSubscription = await syncEngine.hydrateWithCallbacks<Task>(
      getCurrentCursor: () async => null, // Simple: no cursor persistence
      onUpdate: (task) async {
        repo._tasks[task.id] = task; // In real app: await db.upsert(task)
        repo._notifyListeners();
      },
      onDelete: (id) async {
        repo._tasks.remove(id); // In real app: await db.delete(id)
        repo._notifyListeners();
      },
      onCursorUpdate:
          (cursor) async {}, // Skipped for simplicity in minimal example
    );

    return repo;
  }

  /// Watch all tasks reactively
  Stream<List<Task>> watchAll() => _controller.stream;

  /// Get all tasks (snapshot)
  List<Task> getAll() => _tasks.values
      .toList() // In real app: query your database however you want
    ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  /// Save task (create or update) - queued for sync to other devices.
  ///
  /// IMPORTANT: Do NOT update _tasks directly here!
  ///
  /// The sync engine will call our onUpdate callback, which updates _tasks.
  /// This ensures all updates (local saves, remote changes, merged conflicts)
  /// flow through the same code path, keeping everything consistent.
  Future<void> save(Task task) async {
    await _syncEngine.save<Task>(task);
    // ↓ onUpdate callback will be triggered ↓
    // ↓ which updates _tasks and notifies listeners ↓
  }

  /// Delete task - queued for sync to other devices.
  ///
  /// Like save(), the actual removal from _tasks happens via onDelete callback.
  /// This ensures deletions from any source are handled consistently.
  Future<void> delete(String id) async {
    await _syncEngine.delete<Task>(id);
    // ↓ onDelete callback will be triggered ↓
    // ↓ which removes from _tasks and notifies listeners ↓
  }

  void _notifyListeners() {
    _controller.add(getAll());
  }

  void dispose() {
    _hydrationSubscription?.cancel();
    _controller.close();
  }
}

```

**How it works:**
1. **Callbacks connect your storage to sync**: `onUpdate`/`onDelete` let you save synced data to your database (Drift, Hive, etc.)
2. **You control local storage**: Query, index, and structure your data however you want
3. **`save()`/`delete()` register changes**: Your changes are saved locally (via callbacks) and queued for sync
4. **Sync happens automatically**: When connected, changes sync to other devices; offline changes sync later
5. **Single source of truth**: ALL updates (local, remote, merged) flow through the same callbacks, keeping everything consistent

### How sync works behind the scenes

**When you make a local change** (`repository.save(task)`):

```
1. 📱 Your app calls save(task)
   ↓
2. 🔧 SyncEngine merges & stores in Locorda's local storage
   ↓  
3. 📞 onUpdate callback → your app saves to its own database (_tasks Map)
   ↓
4. 🎨 UI updates via StreamBuilder
   ↓
   [Change is queued for sync when connected]
```

**Sync process** (runs automatically in background on all devices):

```
1. 🔄 Worker thread checks remote storage for changes
   ↓
2. 📥 Downloads new/updated data
   ↓
3. 🔧 SyncEngine merges with local storage (resolves conflicts automatically)
   ↓
4. � Uploads merged state + queued local changes to remote
   ↓
5. 📞 onUpdate callback → your app saves to its database (same as step 3 above!)
   ↓
6. 🎨 UI updates via StreamBuilder (same callback flow!)
```

**The key insight**: Whether changes come from your device or from sync, they flow through the **same callbacks**. This is why you never update `_tasks` directly - all updates (local and remote) go through `onUpdate`, keeping everything consistent.

**Two separate storage layers:**
- **Locorda storage**: Tracks sync metadata, clocks, merge state. You configure this in `initLocorda()` (InMemoryStorage, DriftStorage, etc.)
- **Your app storage**: Your database (`_tasks`, Drift, Hive, Isar, etc.). You control queries, structure, and access.

**What about offline?**  
Local changes are queued automatically. When you reconnect, the sync process runs and uploads your queued changes while downloading and merging changes from other devices.

**Why InMemoryStorage in this example?**  
It demonstrates the power of sync! Even though Locorda's sync metadata doesn't persist across app restarts, your data reappears as soon as the sync process runs and downloads from the remote. This shows that sync truly works - your data lives in the remote storage and syncs reliably across all devices.

### Main thread: Locorda setup

The `initLocorda()` function is **generated by build_runner** from your model annotations. You just configure which storage and remotes to use:

<?code-excerpt "lib/main.dart (locorda-setup)"?>
```dart
/// Initialize Locorda for automatic sync.

final locorda = await initLocorda(
  onWorkerSpawn: () => setupLogging(
    level: kDebugMode ? Level.ALL : Level.WARNING,
    threadName: 'WORKER',
  ),

  // Local Dir for testing/debugging (not for production!)
  remotes: [
    await DirMainIntegration.create(
        displayName: 'Local Directory (Testing)'),
  ],

  // InMemoryStorage demonstrates sync power: Even though local storage
  // doesn't persist across restarts, your data comes back automatically
  // as soon as you reconnect to a remote! Perfect for testing sync.
  storage: InMemoryStorageMainHandler(),
);

```

**What you configure:**
- `storage` - Where to store sync metadata locally (here: InMemoryStorage for simplicity)
- `remotes` - Which backends to sync with (here: Local Dir for testing; use Solid Pods, Google Drive, etc. in production)
- `onWorkerSpawn` - Optional callback when worker thread starts (useful for logging setup)

**What's generated for you:**
- Full `initLocorda()` function with all your models configured
- Object serialization/deserialization logic
- Sync protocols and conflict resolution strategies
- Worker thread setup and communication
- See "Generated files" section below for details

### Worker thread: keeping the UI responsive

Heavy tasks (network requests, sync processing) run in a background worker **automatically generated** by `build_runner`. The generator creates:

- Background thread setup (isolate on mobile/desktop, web worker on web)
- Sync handlers matching your main thread configuration
- All communication plumbing

No manual worker configuration needed! Your UI stays smooth while sync happens in the background.

### UI: sync-unaware and simple

The UI layer has no sync awareness - it just uses the `TaskRepository`. Here's how to save changes:

<?code-excerpt "lib/main.dart (repository-usage)"?>
```dart
onChanged: (val) => widget.repository.save(
  tasks[i].copyWith(completed: val ?? false),
),
```

Deletions work the same way: `repository.delete(taskId)` - both trigger automatic sync.

**Sync control center** - Locorda provides a ready-to-use widget for remote management:

<?code-excerpt "lib/main.dart (status-widget)"?>
```dart
child: MultiBackendStatusWidget(
  registry: widget.uiAdapterRegistry,
  syncManager: widget.syncManager,
),
```

This widget gives users full control over sync:
- **Select remotes** - Choose from the remotes you configured in `initLocorda`
- **Connect** - Triggers authentication flows automatically (e.g., OAuth for Google Drive, WebID for Solid Pods)
- **Manual sync** - Force sync on demand
- **Monitor status** - See connection state and ongoing sync operations

**Customization**: This widget is provided for quick start and convenience. You can build your own sync UI in your app's style using the same `SyncManager` and `UiAdapterRegistry` APIs.

The complete UI code is standard Flutter - see `lib/main.dart` for the full implementation.

## Running this example

This example comes **preconfigured for macOS**. To run on other platforms:

```bash
# Generate sync code
dart run build_runner build

# Run on macOS (default)
flutter run

# Or enable and run on other platforms:
flutter create --platforms=windows,linux,android,ios .
flutter run -d <your-device>
```

**Note about platform compatibility:**  
The Local Directory remote (`locorda_dir`) used in this example works best on desktop platforms (macOS, Linux, Windows). For mobile platforms (iOS, Android) or web, consider using Solid Pods or Google Drive instead, which work across all platforms.

## Understanding conflicts

What happens when two devices edit the same task while offline? Locorda automatically resolves conflicts using **Hybrid Logical Clocks** (HLC) - a system that combines:

- **Causality tracking**: Knows which edit came "after" another, even across devices
- **Timestamp-based tie-breaking**: When edits are truly concurrent (neither came "after" the other), the most recent one wins

**Key behaviors:**

- **Same field, different values**: Most recent edit wins
- **Different fields changed**: Both changes are kept (conflicts are per-field, not per-object)
- **Deletion vs. edit**: Deletion wins (deleted items don't "zombie back")

**The bottom line**: You don't need to think about conflicts during development. The framework handles them automatically with sensible defaults. For advanced use cases, you can customize merge strategies per field using annotations.

## Limitations (by design for minimal example)

- ❌ No cursor persistence (full re-sync on restart)
- ❌ Local Dir remote (testing only - use Solid Pods or Google Drive in production)
- ❌ Minimal error handling

See the full Personal Notes App for production patterns.

## Generated files (after running build_runner)

The `dart run build_runner build` command generates these files:

- `init_locorda.g.dart` - Initialization code with all your models configured
- `init_rdf_mapper.g.dart` - Object ↔ RDF conversion logic
- `locorda_config.g.dart` - Sync configuration
- `mapping_bootstrap.g.dart` - Merge rules for conflict resolution
- `task.rdf_mapper.g.dart` - Task-specific serialization
- `worker_generated.g.dart` - Background worker setup
- `worker_generated.dart.js` - Web worker JavaScript (for web platform)
- `vocab.g.ttl` - Vocabulary definition (for RDF nerds)

**Should I commit them?**  
Yes! Generated files should be committed to version control. This ensures:
- Faster builds (no need to regenerate on CI/clean checkouts)
- Reproducible builds across team members
- Clear diffs showing how code generation changes

**When to regenerate:**
- After changing annotations on your model classes
- After updating Locorda packages
- If build errors mention generated files

**What if generation fails?**
- Run `dart run build_runner clean` first, then build again
- Check for typos in annotations
- Make sure all dependencies are up to date (`dart pub get`)

## Next steps

1. **Add persistence**: Replace InMemoryStorage with DriftStorage
2. **Add production remote**: Replace Local Dir with Solid Pods or Google Drive
3. **Add cursor tracking**: Persist sync position for efficient catch-up
4. **Add error handling**: Handle network failures gracefully

---

## Under the hood: Why RDF?

Locorda stores your data as **RDF (Resource Description Framework)** instead of JSON. What does this mean for you?

### Interoperability

Your task data can be read and written by other apps, not just yours:

```dart
// Your task app writes:
Task(id: 'task-1', title: 'Buy milk');

// Another calendar app can read the same data:
Event(id: 'task-1', name: 'Buy milk'); // same underlying data!
```

Locorda makes it easy to use standard RDF vocabularies (like schema.org) in your annotations. When you do, different apps can understand each other's data. No API needed!

### Choose your storage backend

- **Solid Pods** - User-owned decentralized storage
- **Google Drive** - Familiar, free storage
- **Local Directory** - For development/testing
- **More coming** - Dropbox, OneDrive, etc.

Your app code stays the same regardless of where data is stored. Users choose their preferred backend.

### Future-proof data

RDF is a W3C web standard that's been stable for 20+ years. Your data will remain readable long after your app is gone. No vendor lock-in, no proprietary formats.

**Do I need to learn RDF?**  
No! The code generator automatically creates RDF vocabularies from your Dart classes (see `vocab.g.ttl`). You work with normal Dart objects - RDF serialization happens invisibly in the background.

**Want cross-app interoperability?**  
Use standard vocabularies (like schema.org) in your annotations. The generated vocabularies can be deployed at their IRI for discoverability, but this is optional - your app works fine without it.

