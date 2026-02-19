/// Repository for Task CRUD with sync integration.
library;

import 'dart:async';
import 'package:locorda/locorda.dart';
import 'task.dart';

// #docregion repository
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
    await _syncEngine.deleteDocument<Task>(id);
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

// #enddocregion repository
