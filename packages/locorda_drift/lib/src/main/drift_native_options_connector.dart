/// Main thread connector for Drift native database options in worker architecture.
///
/// Provides both sender() and receiver() methods:
/// - sender(): Creates WorkerPlugin for main thread (uses path_provider, has Flutter deps)
/// - receiver(): Delegates to DriftNativeOptionsReceiver (Pure Dart, no Flutter deps)
///
/// Uses Request/Response pattern to avoid race conditions with broadcast streams.
/// Worker requests paths when needed, main thread responds with resolved values.
library;

import 'dart:async';

import 'package:locorda_worker/worker_main.dart';

import 'drift_native_options_sender_native.dart'
    if (dart.library.html) 'drift_native_options_sender_web.dart';

/// Main thread API for Drift native database options connector.
///
/// Provides sender() to create a WorkerPlugin for the main thread, and receiver()
/// for workers (though workers typically import via worker.dart instead).
///
/// The sender plugin:
/// 1. Listens for RequestDriftOptions from worker
/// 2. Resolves database and temp directory paths using path_provider
/// 3. Sends ResponseDriftOptionsMessage back to worker via WorkerChannel
///
/// ## Usage
///
/// Register as plugin during sync system setup:
///
/// ```dart
/// final sync = await Locorda.createWithWorker(
///   engineParamsFactory: createEngineParams,
///   jsScript: 'worker.dart.js',
///   plugins: [
///     DriftNativeOptionsConnector.sender(),
///   ],
///   // ... other config
/// );
/// ```
///
/// For testing or custom paths:
///
/// ```dart
/// plugins: [
///   DriftNativeOptionsConnector.sender(
///     databaseDirectory: () async => '/custom/db/path',
///     tempDirectoryPath: () async => '/custom/temp/path',
///   ),
/// ],
/// ```
///
/// In worker, receive the options:
///
/// ```dart
/// // Import worker-specific export (recommended for workers):
/// import 'package:locorda/worker.dart';
///
/// Future<EngineParams> createEngineParams(
///   SyncEngineConfig config,
///   WorkerContext context,
/// ) async {
///   final nativeOptions = await DriftNativeOptionsConnector.receiver(context);
///   final storage = await DriftStorage.create(
///     web: LocordaDriftWebOptions(...),
///     native: nativeOptions,
///   );
///   // ... return EngineParams
/// }
/// ```
class DriftNativeOptionsConnector {
  /// Creates a plugin factory for this connector.
  ///
  /// The returned factory will be called by the worker framework with the [LocordaWorker].
  ///
  /// By default, uses [getApplicationDocumentsDirectory] and [getTemporaryDirectory].
  /// For testing or custom paths, provide custom provider functions.
  static MainHandlerFactory sender({
    final Future<String> Function()? databasePath,
    final Future<Object> Function()? databaseDirectory,
    final Future<String?> Function()? tempDirectoryPath,
  }) =>
      DriftNativeOptionsSender.sender(
        databasePath: databasePath,
        databaseDirectory: databaseDirectory,
        tempDirectoryPath: tempDirectoryPath,
      );
}
