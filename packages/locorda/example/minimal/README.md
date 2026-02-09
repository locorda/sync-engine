# Minimal Locorda Example

A minimal task sync app demonstrating Locorda's core concepts in ~150 lines.

## What this shows

- **Worker architecture** - Heavy operations isolated from UI thread
- **Object sync** - Work with plain Dart classes, not RDF
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

### Task model with CRDT annotations

<?code-excerpt "lib/task.dart (task-model)"?>
```dart
/// A simple task with CRDT sync.
@RdfGlobalResource(
  IriTerm('https://locorda.dev/example/minimal/Task'),
  IriStrategy(),
)
class Task {
  /// Unique ID for this task
  @RdfIriPart()
  final String id;

  /// Task title - LWW (Last Writer Wins)
  @RdfProperty(SchemaActionEvent.name)
  @LwwRegister()
  final String title;

  /// Completion status - LWW
  @RdfProperty(SchemaAction.actionStatus)
  @LwwRegister()
  final bool completed;

  /// Creation timestamp - Immutable
  @RdfProperty(SchemaAction.startTime)
  @Immutable()
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
- `@LwwRegister()` - Last Writer Wins for title/completed
- `@Immutable()` - createdAt never changes

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
      onCursorUpdate: (cursor) async {}, // Skip cursor persistence for minimal example
    );

    return repo;
  }

  /// Watch all tasks reactively
  Stream<List<Task>> watchAll() => _controller.stream;

  /// Get all tasks (snapshot)
  List<Task> getAll() => _tasks.values.toList()
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
Future<Locorda> setupLocorda() async {
  return Locorda.create(
    // Worker handles heavy operations (CRDT, HTTP, storage)
    workerSetup: setupWorkerEngine,

    // Local Dir for testing/debugging (not for production!)
    remotes: [
      await DirMainIntegration.create(
        id: 'local_dir',
        displayName: 'Local Directory (Testing)',
      ),
    ],

    // InMemoryStorage - data lost on app restart
    storage: InMemoryMainHandler(),

    // RDF mapper for Task model (generated)
    mapperInitializer: (context) => initRdfMapper(
      rdfMapper: context.baseRdfMapper,
      $resourceIriFactory: context.resourceIriFactory,
      $resourceRefFactory: context.resourceRefFactory,
    ),

    // Configure Task resource with CRDT mapping
    config: LocordaConfig(
      resources: [
        ResourceConfig(
          type: Task,
          crdtMapping: Uri.parse('https://locorda.dev/example/minimal/mappings/task-v1.ttl'),
          indices: [FullIndex()], // Simple: fetch all tasks
        ),
      ],
    ),
  );
}
```

**Configuration:**
- `workerSetup` creates isolated compute thread
- `remotes` - Local Dir for testing (replace with Solid/GDrive in production)
- `storage` - InMemoryStorage (data lost on restart)
- `mapperInitializer` - generated RDF converter
- `resources` - Task type with CRDT mapping

### Worker thread: heavy lifting

<?code-excerpt "lib/worker.dart (worker-setup)"?>
```dart
/// Worker entry point (runs in isolate/web worker).
void main() {
  workerMain(setupWorkerEngine);
}

/// Configure SyncEngine in the worker.
Future<WorkerParams> setupWorkerEngine() async => WorkerParams(
      // Must match main thread remotes
      remotes: [DirWorkerHandler(id: 'local_dir')],

      // InMemoryStorage for worker
      storage: InMemoryWorkerHandler(),
    );
```

Worker mirrors main thread choices for remotes/storage but runs in separate isolate.

### UI: simple task list

<?code-excerpt "lib/main.dart (ui)"?>
```dart
class TaskListScreen extends StatefulWidget {
  final TaskRepository repository;
  const TaskListScreen({required this.repository, super.key});

  @override
  State<TaskListScreen> createState() => _TaskListScreenState();
}

class _TaskListScreenState extends State<TaskListScreen> {
  final _controller = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Tasks')),
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
                widget.repository.save(Task(
                  id: 'task_${DateTime.now().millisecondsSinceEpoch}',
                  title: title,
                ));
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

See [../README.md](../README.md) for detailed architecture guide.
