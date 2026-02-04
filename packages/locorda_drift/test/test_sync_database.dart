/// Test-specific database implementation for in-memory testing.
library;

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:locorda_drift/src/sync_database.dart';

/// Test database class that extends SyncDatabase with in-memory support.
///
/// This class is only used in tests and provides an in-memory database
/// without requiring platform-specific dependencies in the main codebase.
class TestSyncDatabase extends SyncDatabase {
  /// Create an in-memory test database with foreign key constraints enabled.
  TestSyncDatabase.memory() : super.forExecutor(_createMemoryExecutor());

  /// Create an in-memory database executor with proper test configuration.
  static QueryExecutor _createMemoryExecutor() {
    return NativeDatabase.memory(setup: (database) {
      // Enable foreign key constraints to match production behavior
      database.execute('PRAGMA foreign_keys = ON;');
    });
  }
}
