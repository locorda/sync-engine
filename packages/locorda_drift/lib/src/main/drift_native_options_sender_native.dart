/// Main thread implementation of the sender WorkerPlugin for Drift native database options.
///
/// This plugin listens for RequestDriftOptions messages from workers and responds
/// with resolved database and temp directory paths using path_provider.
///
/// Has Flutter dependencies (path_provider) - isolated to main thread only.
///
/// Uses Request/Response pattern to avoid race conditions with broadcast streams.
library;

import 'dart:async';

import 'package:locorda_worker/worker_main.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';

import '../shared/messages.dart';

final _log = Logger('DriftNativeOptionsSender');

/// Main thread implementation of the sender WorkerPlugin.
///
/// Listens for path requests from worker and responds with resolved paths
/// from path_provider (or custom providers for testing).
class DriftNativeOptionsSender implements WorkerPlugin {
  final LocordaWorker _workerHandle;
  final Future<Object> Function()? _databaseDirectoryProvider;
  final Future<String?> Function()? _tempDirectoryPathProvider;
  final Future<String> Function()? _databasePathProvider;

  DriftNativeOptionsSender._(
    this._workerHandle, {
    final Future<String> Function()? databasePath,
    Future<Object> Function()? databaseDirectory,
    Future<String?> Function()? tempDirectoryPath,
  })  : _databaseDirectoryProvider = databaseDirectory,
        _tempDirectoryPathProvider = tempDirectoryPath,
        _databasePathProvider = databasePath;

  /// Creates a plugin factory for this connector.
  ///
  /// The returned factory will be called by the worker framework with the [LocordaWorker].
  ///
  /// By default, uses [getApplicationDocumentsDirectory] and [getTemporaryDirectory].
  /// For testing or custom paths, provide custom provider functions.
  static WorkerPluginFactory sender({
    final Future<String> Function()? databasePath,
    final Future<Object> Function()? databaseDirectory,
    final Future<String?> Function()? tempDirectoryPath,
  }) {
    return (LocordaWorker workerHandle) {
      return DriftNativeOptionsSender._(
        workerHandle,
        databasePath: databasePath,
        databaseDirectory: databaseDirectory,
        tempDirectoryPath: tempDirectoryPath,
      );
    };
  }

  /// Listens for path requests from worker and responds with resolved paths.
  ///
  /// Worker uses Request/Response pattern to avoid race conditions.
  @override
  Future<void> initialize() async {
    _log.info('Plugin initialized, listening for requests...');

    // Listen for requests from worker (filter __channel messages)
    _workerHandle.messages.listen((message) async {
      if (message is! Map<String, dynamic>) return;

      // Only process __channel messages
      if (message['__channel'] != true) return;

      final channelData = message['data'];
      _log.fine(
          'Received __channel message: ${channelData is Map ? channelData['type'] : channelData.runtimeType}');

      if (channelData is Map<String, dynamic> &&
          channelData['type'] == 'RequestDriftOptions') {
        _log.info('Processing RequestDriftOptions...');

        // Resolve paths when requested
        final databasePath = _databasePathProvider != null
            ? await _databasePathProvider()
            : null;
        _log.fine('Database path: $databasePath');

        // Resolve database directory (default: application documents)
        final databaseDir = databasePath != null
            ? null
            : (_databaseDirectoryProvider != null
                ? await _databaseDirectoryProvider()
                : (await getApplicationDocumentsDirectory()).path);
        _log.fine('Database directory: $databaseDir');

        // Resolve temp directory (default: system temp)
        final tempDir = _tempDirectoryPathProvider != null
            ? await _tempDirectoryPathProvider()
            : (await getTemporaryDirectory()).path;
        _log.fine('Temp directory: $tempDir');

        // Send response back to worker
        final response = ResponseDriftOptionsMessage(
          databaseDirectory: switch (databaseDir) {
            String s => s,
            _ => databaseDir?.toString(),
          },
          tempDirectoryPath: tempDir,
          databasePath: databasePath,
        );

        _log.info('Sending response via __channel: ${response.toJson()}');
        _workerHandle.sendMessage({
          '__channel': true,
          'data': response.toJson(),
        });
        _log.info('Response sent successfully');
      }
    });
  }

  /// No cleanup needed.
  @override
  Future<void> dispose() async {
    // Nothing to clean up
  }
}
