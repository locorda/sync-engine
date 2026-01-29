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

/// No-Op implementation for web:
class DriftNativeOptionsSender implements MainHandler {
  const DriftNativeOptionsSender._();

  static MainHandlerFactory sender({
    final Future<String> Function()? databasePath,
    final Future<Object> Function()? databaseDirectory,
    final Future<String?> Function()? tempDirectoryPath,
  }) {
    return (MainHandlerContext context) {
      return const DriftNativeOptionsSender._();
    };
  }

  @override
  Future<void> initialize() async {
    // nothing to do
  }

  /// No cleanup needed.
  @override
  Future<void> dispose() async {
    // Nothing to clean up
  }
}
