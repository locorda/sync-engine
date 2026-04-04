/// Web implementation of SyncDatabase factory using drift/wasm.
///
/// This implementation is selected via conditional import on web platforms.
/// It provides pure Dart database access without Flutter dependencies.
library;

import 'package:drift/wasm.dart';

import 'drift_options.dart';
import 'sync_database.dart';

/// Web-specific implementation of SyncDatabase factory.
///
/// Uses drift's WasmDatabase for browser-based SQLite access.
class SyncDatabaseImpl {
  /// Create SyncDatabase for web platform.
  ///
  /// Initializes WasmDatabase with provided web options.
  /// Native options are ignored on web.
  static Future<SyncDatabase> create({
    LocordaDriftWebOptions? web,
    LocordaDriftNativeWorkerOptions? native,
  }) async {
    if (web == null) {
      throw ArgumentError(
        'LocordaDriftWebOptions required for web platform. '
        'Provide sqlite3Wasm and driftWorker URIs.',
      );
    }

    final result = await WasmDatabase.open(
      databaseName: 'locorda_sync',
      sqlite3Uri: web.sqlite3Wasm,
      driftWorkerUri: web.driftWorker,
      initializeDatabase: web.initializeDatabase,
    );

    web.onResult?.call(result);

    return SyncDatabase.forExecutor(result.resolvedExecutor);
  }
}
