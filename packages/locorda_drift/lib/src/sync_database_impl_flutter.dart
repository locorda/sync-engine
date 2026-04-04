/// Flutter implementation of SyncDatabase factory using drift_flutter.
///
/// This implementation is selected via conditional import on native platforms.
/// It uses drift_flutter for automatic Flutter platform detection, and falls
/// back to direct NativeDatabase usage when read pool support is needed.
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:sqlite3_flutter_libs/sqlite3_flutter_libs.dart';

import 'package:logging/logging.dart';

import 'drift_options.dart';
import 'sync_database.dart';

final _log = Logger('SyncDatabaseImpl');

/// Extension methods to convert Locorda options to drift_flutter options.
extension LocordaDriftWebOptionsX on LocordaDriftWebOptions {
  /// Convert to drift_flutter's DriftWebOptions.
  DriftWebOptions toDriftWebOptions() => DriftWebOptions(
        sqlite3Wasm: sqlite3Wasm,
        driftWorker: driftWorker,
        onResult: onResult,
        initializeDatabase: initializeDatabase,
      );
}

extension LocordaDriftNativeOptionsX on LocordaDriftNativeWorkerOptions {
  /// Convert to drift_flutter's DriftNativeOptions.
  ///
  /// Resolves all closures to their actual values before conversion,
  /// because drift_flutter will spawn a new isolate for database operations,
  /// and closures cannot cross isolate boundaries.
  Future<DriftNativeOptions> toDriftNativeOptions() async {
    // Resolve all closures to actual values before passing to drift_flutter
    final resolvedDatabasePath =
        databasePath != null ? await databasePath!() : null;
    final resolvedDatabaseDirectory =
        databaseDirectory != null ? await databaseDirectory!() : null;
    final resolvedTempDirectoryPath =
        tempDirectoryPath != null ? await tempDirectoryPath!() : null;

    return DriftNativeOptions(
      shareAcrossIsolates: shareAcrossIsolates,
      isolateDebugLog: isolateDebugLog,
      // Pass resolved values, not closures
      databasePath: resolvedDatabasePath != null
          ? () => Future.value(resolvedDatabasePath)
          : null,
      databaseDirectory: resolvedDatabaseDirectory != null
          ? () => Future.value(resolvedDatabaseDirectory)
          : null,
      tempDirectoryPath: resolvedTempDirectoryPath != null
          ? () => Future.value(resolvedTempDirectoryPath)
          : null,
      setup: effectiveEnableWal
          ? (db) => db.execute('PRAGMA journal_mode = WAL')
          : null,
    );
  }
}

/// Flutter-specific implementation of SyncDatabase factory.
///
/// Uses drift_flutter's driftDatabase() for automatic platform selection.
/// When [LocordaDriftNativeWorkerOptions.readPool] > 0, bypasses driftDatabase()
/// to use [NativeDatabase.createBackgroundConnection] directly, which
/// supports read pool isolates for parallel SELECT execution.
class SyncDatabaseImpl {
  /// Create SyncDatabase with Flutter platform detection.
  ///
  /// Converts Locorda options to drift_flutter options and uses
  /// driftDatabase() for automatic platform selection.
  /// Returns Future for API consistency with web implementation.
  static Future<SyncDatabase> create({
    LocordaDriftWebOptions? web,
    LocordaDriftNativeWorkerOptions? native,
  }) async {
    if (native != null && native.readPool > 0) {
      _log.info(
          'Creating database with background connection pool: readPool=${native.readPool}, wal=true');
      return _createWithReadPool(native);
    }
    _log.fine(
        'Creating standard database connection: wal=${native?.effectiveEnableWal ?? false}');

    // Resolve native options closures before passing to drift_flutter
    final resolvedNativeOptions =
        native != null ? await native.toDriftNativeOptions() : null;

    final executor = driftDatabase(
      name: 'locorda_sync',
      web: web?.toDriftWebOptions(),
      native: resolvedNativeOptions,
    );
    return SyncDatabase.forExecutor(executor);
  }

  /// Creates a database connection with WAL mode and a read pool.
  ///
  /// Bypasses drift_flutter's [driftDatabase] because it doesn't expose
  /// the [readPool] parameter of [NativeDatabase.createBackgroundConnection].
  /// Replicates essential platform setup (Android workarounds, temp directory).
  static Future<SyncDatabase> _createWithReadPool(
    LocordaDriftNativeWorkerOptions native,
  ) async {
    final file = await _resolveDatabaseFile(native);
    _log.info(
        'NativeDatabase.createBackgroundConnection: file=${file.path}, readPool=${native.readPool}');

    // Resolve temp directory before crossing isolate boundary
    final resolvedTempDir = native.tempDirectoryPath != null
        ? await native.tempDirectoryPath!()
        : await getTemporaryDirectory().then((d) => d.path);

    final connection = NativeDatabase.createBackgroundConnection(
      file,
      readPool: native.readPool,
      isolateDebugLog: native.isolateDebugLog,
      isolateSetup: () async {
        if (Platform.isAndroid) {
          await applyWorkaroundToOpenSqlite3OnOldAndroidVersions();
        }
        if (resolvedTempDir != null) {
          sqlite3.tempDirectory = resolvedTempDir;
        }
      },
      setup: (db) {
        db.execute('PRAGMA journal_mode = WAL');
      },
    );
    return SyncDatabase.forExecutor(connection);
  }

  /// Resolves the database file path, replicating drift_flutter's logic.
  static Future<File> _resolveDatabaseFile(
    LocordaDriftNativeWorkerOptions native,
  ) async {
    if (native.databasePath != null) {
      return File(await native.databasePath!());
    }
    final dir = native.databaseDirectory != null
        ? await native.databaseDirectory!()
        : await getApplicationDocumentsDirectory();
    final dirPath = switch (dir) {
      Directory(:final path) => path,
      final String path => path,
      _ => throw ArgumentError.value(
          dir,
          'databaseDirectory',
          'must resolve to a Directory or a path string',
        ),
    };
    return File(p.join(dirPath, 'locorda_sync.sqlite'));
  }
}
