# Minimal Locorda Example

A minimal task sync app demonstrating Locorda's core concepts.

## What this shows

- **Worker architecture** - Heavy operations isolated from UI thread
- **Object sync** - Work with plain Dart classes (RDF handled internally)
- **CRDT merge** - Automatic conflict resolution (LWW strategy)
- **Repository pattern** - Clean separation: sync ↔ storage ↔ UI

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
/// A simple task with CRDT sync.
@RootResource(AppVocab(appBaseUri: 'https://locorda.dev/example/minimal'))
class Task {
  /// Unique ID for this task
  @RdfIriPart()
  final String id;

  /// Task title - LWW (Last Writer Wins) is the default merge strategy
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

**Annotations explained:**
- `@RootResource(AppVocab(...))` - Defines this class as an RDF resource type
- `@RdfIriPart()` - Uses `id` field as the unique identifier in URIs
- CRDT merge strategies are configured separately in the CRDT mapping file (generated)

### Repository: the sync integration point

<?code-excerpt "lib/task_repository.dart (repository)"?>
```dart
/// Repository integrating local storage with Locorda sync.
class TaskRepository {
  final ObjectSyncEngine _syncEngine;
  final Map<String, Task> _tasks = {}; // In-memory storage
  final StreamController<List<Task>> _controller = StreamController.broadcast();
  StreamSubscription? _hydrationSubscription;

  TaskRepository._(this._syncEngine);

  /// Create and initialize repository with hydration.
  static Future<TaskRepository> create(ObjectSyncEngine syncEngine) async {
    final repo = TaskRepository._(syncEngine);

    // Setup hydration: remote changes → local storage
    repo._hydrationSubscription = await syncEngine.hydrateWithCallbacks<Task>(
      getCurrentCursor: () async => null, // Simple: no cursor persistence
      onUpdate: (task) async {
        repo._tasks[task.id] = task;
        repo._notifyListeners();
      },
      onDelete: (id) async {
        repo._tasks.remove(id);
        repo._notifyListeners();
      },
      onCursorUpdate:
          (cursor) async {}, // Skip cursor persistence for minimal example
    );

    return repo;
  }

  /// Watch all tasks reactively
  Stream<List<Task>> watchAll() => _controller.stream;

  /// Get all tasks (snapshot)
  List<Task> getAll() =>
      _tasks.values.toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  /// Save task (create or update) - triggers sync
  Future<void> save(Task task) async {
    await _syncEngine.save<Task>(task);
    // Local update happens via hydration callback
  }

  /// Delete task - triggers sync
  Future<void> delete(String id) async {
    await _syncEngine.deleteDocument<Task>(id);
    // Local delete happens via hydration callback
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

**Key pattern:**
1. `hydrateWithCallbacks` syncs remote → local
2. `save()`/`delete()` go through `syncEngine`
3. Local updates happen via hydration callbacks (no double-write!)

### Main thread: Locorda setup

<?code-excerpt "lib/main.dart (locorda-setup)"?>
```dart
/// Initialize Locorda with worker architecture.

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
- `onWorkerSpawn` - Optional callback when worker thread starts (useful for logging setup)
- `remotes` - Storage backends (here: Local Dir for testing; use Solid/GDrive in production)
- `storage` - Local storage handler (here: InMemoryStorage - data lost on restart)

All other configuration (RDF mapping, CRDT merge strategies, resource types) is automatically generated from your `@RootResource` annotations.

**Generated files** (created by `dart run build_runner build`):
- `init_locorda.g.dart` - Locorda initialization
- `init_rdf_mapper.g.dart` - RDF object mapping
- `locorda_config.g.dart` - Resource configuration with CRDT mappings
- `task.rdf_mapper.g.dart` - Task-specific RDF serialization
- `worker_generated.g.dart` - Worker thread setup
- `vocab.g.ttl` - RDF vocabulary definition

### Worker thread: heavy lifting

The worker code is **automatically generated** by `build_runner` in `lib/worker_generated.g.dart`. The generator creates:

- Worker entry point that runs in an isolate (native) or web worker (web)
- Storage and remote handlers matching your main thread configuration
- All necessary setup code

No manual worker configuration needed! The `initLocorda()` function handles the worker setup automatically.

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

UI only knows about `TaskRepository` - no sync/CRDT awareness needed.

## Running this example

From the main example directory:

```bash
# Generate RDF mappers
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
2. **Add production remote**: Replace Local Dir with Solid/GDrive
3. **Add cursor tracking**: Persist sync position for efficient catch-up
4. **Add error handling**: Handle network failures gracefully

