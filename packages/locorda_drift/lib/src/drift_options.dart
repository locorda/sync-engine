/// Platform-independent database options for Drift storage.
///
/// These classes replace drift_flutter's DriftWebOptions and DriftNativeOptions
/// to allow usage in pure Dart contexts (like web workers) without Flutter dependencies.
library;

import 'dart:async';
import 'dart:typed_data';

/// Options for web-based Drift databases.
///
/// Platform-independent version of drift_flutter's DriftWebOptions.
/// Used for both Flutter web apps and pure Dart web workers.
final class LocordaDriftWebOptions {
  /// The URI to the sqlite3.wasm file.
  final Uri sqlite3Wasm;

  /// The URI to the drift_worker.js file.
  final Uri driftWorker;

  /// Optional callback for database initialization results.
  ///
  /// The callback receives a dynamic result object from the database initialization.
  /// On web, this is a WasmDatabaseResult from package:drift/wasm.dart.
  final void Function(Object)? onResult;

  /// Optional callback to initialize database from existing data.
  final FutureOr<Uint8List?> Function()? initializeDatabase;

  const LocordaDriftWebOptions({
    required this.sqlite3Wasm,
    required this.driftWorker,
    this.onResult,
    this.initializeDatabase,
  });
}

/// Options for native Drift databases.
///
/// Platform-independent version of drift_flutter's DriftNativeOptions.
/// Used for both Flutter native apps and pure Dart native isolates.
final class LocordaDriftNativeWorkerOptions {
  /// Whether to share database across isolates (native only).
  final bool shareAcrossIsolates;

  /// Enable debug logging for isolate communication (native only).
  final bool isolateDebugLog;

  /// Custom database path provider (native only).
  final Future<String> Function()? databasePath;

  /// Custom database directory provider (native only).
  final Future<Object> Function()? databaseDirectory;
  final Future<String?> Function()? tempDirectoryPath;

  /// Whether to enable WAL (Write-Ahead Logging) journal mode.
  ///
  /// **What is WAL?**
  ///
  /// WAL (Write-Ahead Logging) is a SQLite journal mode where changes are
  /// first written to a separate `.db-wal` file instead of directly modifying
  /// the main database file. The WAL file is periodically checkpointed back
  /// into the main file. This enables MVCC (Multi-Version Concurrency Control):
  /// readers see a consistent snapshot at transaction start, writers never block
  /// readers, and readers never block writers.
  ///
  /// **Why is WAL not on by default?**
  ///
  /// SQLite ships with DELETE journal mode as default for broad compatibility:
  /// - Network file systems (NFS, SMB) lack shared-memory support required for
  ///   the companion `.db-shm` file that WAL needs.
  /// - WAL mode is **persistent**: once activated via `PRAGMA journal_mode = WAL`,
  ///   the database remains in WAL mode across close/reopen cycles, even if the
  ///   option is later removed from the application. A WAL database has three
  ///   files (`.sqlite`, `.sqlite-wal`, `.sqlite-shm`) — all must be deleted
  ///   together; deleting only `.sqlite` leaves a corrupt state.
  /// - Automatic checkpointing (default: every 1000 changed pages) adds
  ///   periodic write overhead.
  /// - In single-connection scenarios (the default Locorda setup) WAL provides
  ///   no throughput benefit and only adds file-management complexity.
  ///
  /// **When to enable:** only when paired with [readPool] > 0, or when you
  /// explicitly want to future-proof the DB for concurrent reader access.
  /// Setting [readPool] > 0 enables WAL automatically via [effectiveEnableWal].
  ///
  /// **Consistency guarantee:** WAL does NOT introduce undefined state for
  /// concurrent reads and writes. SQLite's snapshot isolation ensures each
  /// reader transaction sees a fully consistent database state.
  final bool enableWal;

  /// Number of read-only database connections to maintain in a pool.
  ///
  /// **Architecture:** when > 0, Drift spawns `readPool + 1` isolates total:
  /// one write isolate (handles all INSERT/UPDATE/DELETE) and [readPool]
  /// read-only isolates (share SELECT queries in round-robin). WAL mode is
  /// activated automatically because it is required for concurrent read+write
  /// connections against a single file.
  ///
  /// **Performance context:** This setting is only meaningful when the
  /// database is encapsulated in a single worker isolate (as Locorda's sync
  /// worker does). The benefit is pipeline-internal parallelism: stages that
  /// read (S04 ChangeDetect, S05 LocalLoad) can execute concurrently with
  /// stages that write (S09 DbCommit), provided a decoupling point separates
  /// them in the pipeline.
  ///
  /// **Does not affect UI concurrency:** `locorda_sync.sqlite` is accessed
  /// exclusively by the sync worker isolate. The application's own database
  /// (e.g., your Drift app DB) is a separate file — this setting has no
  /// effect on UI ↔ sync contention.
  ///
  /// **Trade-offs vs default (`readPool = 0`):**
  /// - Each additional isolate costs ~3–5 MB of Dart VM heap and one SQLite
  ///   connection. With `readPool = 2`, that is three isolates total.
  /// - Isolate spawn adds ~50–100 ms to first sync startup.
  /// - WAL introduces three database files instead of one (see [enableWal]).
  /// - Benefit is measurable only with large shard sets (>50 shards) where
  ///   read and write stages actually overlap in the pipeline. For small
  ///   datasets the overhead dominates.
  /// - Recommended value if enabled: `2` (two read isolates saturates the
  ///   typical producer pipeline without excessive connection overhead).
  ///
  /// **Constraint:** [shareAcrossIsolates] is ignored when [readPool] > 0,
  /// because [NativeDatabase.createBackgroundConnection] manages its own
  /// isolate topology and does not register an [IsolateNameServer] port.
  /// This is safe because the sync worker is the sole database owner.
  final int readPool;

  const LocordaDriftNativeWorkerOptions({
    this.shareAcrossIsolates = true,
    this.isolateDebugLog = false,
    this.databasePath,
    this.databaseDirectory,
    this.tempDirectoryPath,
    this.enableWal = false,
    this.readPool = 0,
  });

  /// Whether WAL mode is effectively enabled (explicitly or via [readPool]).
  bool get effectiveEnableWal => enableWal || readPool > 0;
}

final class LocordaDriftNativeOptions {
  /// Whether to enable WAL (Write-Ahead Logging) journal mode.
  ///
  /// **What is WAL?**
  ///
  /// WAL (Write-Ahead Logging) is a SQLite journal mode where changes are
  /// first written to a separate `.db-wal` file instead of directly modifying
  /// the main database file. The WAL file is periodically checkpointed back
  /// into the main file. This enables MVCC (Multi-Version Concurrency Control):
  /// readers see a consistent snapshot at transaction start, writers never block
  /// readers, and readers never block writers.
  ///
  /// **Why is WAL not on by default?**
  ///
  /// SQLite ships with DELETE journal mode as default for broad compatibility:
  /// - Network file systems (NFS, SMB) lack shared-memory support required for
  ///   the companion `.db-shm` file that WAL needs.
  /// - WAL mode is **persistent**: once activated via `PRAGMA journal_mode = WAL`,
  ///   the database remains in WAL mode across close/reopen cycles, even if the
  ///   option is later removed from the application. A WAL database has three
  ///   files (`.sqlite`, `.sqlite-wal`, `.sqlite-shm`) — all must be deleted
  ///   together; deleting only `.sqlite` leaves a corrupt state.
  /// - Automatic checkpointing (default: every 1000 changed pages) adds
  ///   periodic write overhead.
  /// - In single-connection scenarios (the default Locorda setup) WAL provides
  ///   no throughput benefit and only adds file-management complexity.
  ///
  /// **When to enable:** only when paired with [readPool] > 0, or when you
  /// explicitly want to future-proof the DB for concurrent reader access.
  /// Setting [readPool] > 0 enables WAL automatically via [effectiveEnableWal].
  ///
  /// **Consistency guarantee:** WAL does NOT introduce undefined state for
  /// concurrent reads and writes. SQLite's snapshot isolation ensures each
  /// reader transaction sees a fully consistent database state.
  final bool enableWal;

  /// Number of read-only database connections to maintain in a pool.
  ///
  /// **Architecture:** when > 0, Drift spawns `readPool + 1` isolates total:
  /// one write isolate (handles all INSERT/UPDATE/DELETE) and [readPool]
  /// read-only isolates (share SELECT queries in round-robin). WAL mode is
  /// activated automatically because it is required for concurrent read+write
  /// connections against a single file.
  ///
  /// **Performance context:** This setting is only meaningful when the
  /// database is encapsulated in a single worker isolate (as Locorda's sync
  /// worker does). The benefit is pipeline-internal parallelism: stages that
  /// read (S04 ChangeDetect, S05 LocalLoad) can execute concurrently with
  /// stages that write (S09 DbCommit), provided a decoupling point separates
  /// them in the pipeline.
  ///
  /// **Does not affect UI concurrency:** `locorda_sync.sqlite` is accessed
  /// exclusively by the sync worker isolate. The application's own database
  /// (e.g., your Drift app DB) is a separate file — this setting has no
  /// effect on UI ↔ sync contention.
  ///
  /// **Trade-offs vs default (`readPool = 0`):**
  /// - Each additional isolate costs ~3–5 MB of Dart VM heap and one SQLite
  ///   connection. With `readPool = 2`, that is three isolates total.
  /// - Isolate spawn adds ~50–100 ms to first sync startup.
  /// - WAL introduces three database files instead of one (see [enableWal]).
  /// - Benefit is measurable only with large shard sets (>50 shards) where
  ///   read and write stages actually overlap in the pipeline. For small
  ///   datasets the overhead dominates.
  /// - Recommended value if enabled: `2` (two read isolates saturates the
  ///   typical producer pipeline without excessive connection overhead).
  ///
  /// **Constraint:** [shareAcrossIsolates] is ignored when [readPool] > 0,
  /// because [NativeDatabase.createBackgroundConnection] manages its own
  /// isolate topology and does not register an [IsolateNameServer] port.
  /// This is safe because the sync worker is the sole database owner.
  final int readPool;

  const LocordaDriftNativeOptions({
    this.enableWal = false,
    this.readPool = 0,
  });
}
