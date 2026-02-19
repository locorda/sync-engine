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
    ↓ ↓
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
- Merge strategies (how conflicts are resolved) are auto-generated from these annotations

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

    // Connect your local storage to sync via callbacks:
    // - onUpdate: save synced items to your database
    // - onDelete: remove synced items from your database
    // - getCurrentCursor: provide last sync position (for efficient catch-up)
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

  /// Save task (create or update) - queued for sync to other devices
  Future<void> save(Task task) async {
    await _syncEngine.save<Task>(task);
    // Local update happens via sync callback
  }

  /// Delete task - queued for sync to other devices
  Future<void> delete(String id) async {
    await _syncEngine.deleteDocument<Task>(id);
    // Local delete happens via sync callback
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
5. **One source of truth**: Callbacks keep your local database up-to-date automatically

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

  // InMemoryStorage for simplicity - data won't persist across app restarts
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

**Generated files** (created by `dart run build_runner build`):
- `init_locorda.g.dart` - Locorda initialization code
- `init_rdf_mapper.g.dart` - Object ↔ sync format conversion
- `locorda_config.g.dart` - Sync configuration
- `task.rdf_mapper.g.dart` - Task-specific conversion logic
- `worker_generated.g.dart` - Background worker setup
- `vocab.g.ttl` - Data vocabulary definition

### Worker thread: keeping the UI responsive

Heavy tasks (network requests, sync processing) run in a background worker **automatically generated** by `build_runner`. The generator creates:

- Background thread setup (isolate on mobile/desktop, web worker on web)
- Sync handlers matching your main thread configuration
- All communication plumbing

No manual worker configuration needed! Your UI stays smooth while sync happens in the background.

### UI: simple task list

<?code-excerpt "lib/main.dart (ui)"?>
```dart
class TaskListScreen extends StatefulWidget {
  final TaskRepository repository;
  final UiAdapterRegistry uiAdapterRegistry;
  final SyncManager syncManager;
  const TaskListScreen({
    required this.repository,
    required this.uiAdapterRegistry,
    required this.syncManager,
    super.key,
  });

  @override
  State<TaskListScreen> createState() => _TaskListScreenState();
}

class _TaskListScreenState extends State<TaskListScreen> {
  final _controller = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tasks'),
        actions: [
          Padding(
            padding: EdgeInsets.only(
              right: kDebugMode ? 60.0 : 0.0, // Space for debug banner
            ),
            child: MultiBackendStatusWidget(
              registry: widget.uiAdapterRegistry,
              syncManager: widget.syncManager,
            ),
          ),
        ],
      ),
      body: StreamBuilder<List<Task>>(
        stream: widget.repository.watchAll(),
        initialData: widget.repository.getAll(),
        builder: (context, snapshot) {
          final tasks = snapshot.data ?? [];
          return ListView.builder(
            itemCount: tasks.length,
            itemBuilder: (context, i) => CheckboxListTile(
              value: tasks[i].completed,
              title: Text(tasks[i].title),
              onChanged: (val) => widget.repository.save(
                tasks[i].copyWith(completed: val ?? false),
              ),
              secondary: IconButton(
                icon: const Icon(Icons.delete),
                onPressed: () => widget.repository.delete(tasks[i].id),
              ),
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        child: const Icon(Icons.add),
        onPressed: () => _showAddDialog(),
      ),
    );
  }

  void _showAddDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New Task'),
        content: TextField(controller: _controller),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              final title = _controller.text.trim();
              if (title.isNotEmpty) {
                widget.repository.save(
                  Task(
                    id: 'task_${DateTime.now().millisecondsSinceEpoch}',
                    title: title,
                  ),
                );
              }
              _controller.clear();
              Navigator.pop(context);
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}

```

UI only knows about `TaskRepository` - no sync awareness needed. Edit tasks, the repository handles the rest.

## Running this example

From the main example directory:

```bash
# Generate sync code
dart run build_runner build

# Run the app
flutter run
```

## Limitations (by design for minimal example)

- ❌ No cursor persistence (full re-sync on restart)
- ❌ InMemoryStorage (not persistent)
- ❌ Local Dir remote (testing only)
- ❌ No error handling

See the full Personal Notes App for production patterns.

## Next steps

1. **Add persistence**: Replace InMemoryStorage with DriftStorage
2. **Add production remote**: Replace Local Dir with Solid Pods or Google Drive
3. **Add cursor tracking**: Persist sync position for efficient catch-up
4. **Add error handling**: Handle network failures gracefully

---

## Under the hood

Locorda uses two technologies to power sync:

- **RDF (Resource Description Framework)**: Your objects are stored as semantic web data, enabling:
  - Interoperability between different apps
  - Flexible storage backends (Solid Pods, Google Drive, etc.)
  - Standard vocabularies for common data types

- **CRDTs (Conflict-free Replicated Data Types)**: Automatic conflict resolution using:
  - LWW (Last Writer Wins) for simple fields like `title` and `completed`
  - Timestamp-based merge strategies
  - Guaranteed convergence across devices

You don't need to understand these to use Locorda, but you can customize merge strategies and vocabularies for advanced use cases.

