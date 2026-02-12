/// Repository for Task CRUD with sync integration.
library;

import 'dart:async';
import 'package:locorda/locorda.dart';
import 'task.dart';

// #docregion repository
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

// #enddocregion repository
