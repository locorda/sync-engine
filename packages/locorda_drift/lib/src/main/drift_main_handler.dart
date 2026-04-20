import 'package:locorda_worker/worker_main.dart';

import '../shared/consts.dart';

import '../drift_options.dart';
import 'drift_config_connector.dart';
import 'drift_native_options_connector.dart';

/// Main-thread plugin handler for the Drift (SQLite) sync storage backend.
///
/// Registers the connectors that the sync worker isolate needs to obtain
/// platform-specific configuration from the main thread. Must be included in
/// the Locorda worker setup for the Drift storage backend to function.
///
/// ## Integration
///
/// The worker-side counterpart is registered automatically when
/// `locorda_drift` is a dependency — no manual worker registration needed.
/// On the main thread, add this handler to your worker setup:
///
/// ```dart
/// final syncEngine = await Locorda.createWithWorker(
///   storageHandler: DriftMainHandler(
///     options: LocordaDriftOptions(
///       web: LocordaDriftWebOptions(
///         sqlite3Wasm: Uri.parse('sqlite3.wasm'),
///         driftWorker: Uri.parse('drift_worker.js'),
///       ),
///     ),
///   ),
///   // ...
/// );
/// ```
///
/// The flat [web] and [native] parameters are a convenience shorthand and
/// are equivalent to wrapping them in a [LocordaDriftOptions] with default
/// storage settings (`deduplicateOnLoad = false`).
///
/// ## Native path resolution
///
/// Database and temporary directory paths are resolved automatically via
/// `path_provider` (`getApplicationDocumentsDirectory` /
/// `getTemporaryDirectory`). No path configuration is required for the vast
/// majority of apps. The [native] parameter is therefore optional and only
/// needed for performance tuning (see [LocordaDriftNativeOptions]).
///
/// ## Web configuration — [web] / [LocordaDriftOptions.web]
///
/// Required on web platforms. Provides the URIs to the compiled
/// `sqlite3.wasm` module and the Drift web worker script. Omit on
/// native-only apps.
///
/// ## Native performance tuning — [native] / [LocordaDriftOptions.native]
///
/// Optional. Pass a [LocordaDriftNativeOptions] to enable WAL journal mode
/// and/or a read connection pool for large sync workloads. Both settings are
/// documented in detail on [LocordaDriftNativeOptions]. Quick reference:
///
/// | Setting | Default | When to change |
/// |---------|---------|----------------|
/// | [LocordaDriftNativeOptions.readPool] | `0` | Set to `2` when syncing >50 shards and pipeline decoupling is active |
/// | [LocordaDriftNativeOptions.enableWal] | `false` | Implied by `readPool > 0`; set explicitly only if you want WAL without a pool |
///
/// **Why `readPool` is not on by default:**
/// Setting `readPool = 2` spawns **3 Dart isolates** (1 writer + 2 readers)
/// instead of 1, opens **3 SQLite connections**, and activates **WAL mode**
/// (3 database files instead of 1). Isolate startup adds ~50–100 ms to the
/// very first sync. For small datasets this overhead costs more than it saves:
/// the benefit of concurrent reads only materialises when read stages (S04,
/// S05) and write stages (S09) are actually running simultaneously, which
/// requires both a large number of shards and an active pipeline decoupling
/// point. In all other cases `readPool = 0` is faster.
///
/// ```dart
/// // Enable read pool for large sync workloads (also activates WAL):
/// DriftMainHandler(
///   native: LocordaDriftNativeOptions(readPool: 2),
/// )
/// ```
class DriftMainHandler extends StorageMainHandler {
  @override
  final String id;
  final LocordaDriftOptions _options;

  /// Creates a [DriftMainHandler] with a unified [LocordaDriftOptions] object.
  ///
  /// The flat [web] and [native] parameters are a convenience shorthand;
  /// they are mapped to [LocordaDriftOptions] with `deduplicateOnLoad = false`.
  /// Use [options] directly when you need to configure [LocordaDriftOptions.deduplicateOnLoad]
  /// or any future storage-level setting.
  DriftMainHandler({
    this.id = driftStorageHandlerId,

    /// Full options object. Takes precedence over the flat [web] and [native] params.
    LocordaDriftOptions? options,

    /// Web platform configuration. Convenience shorthand for [LocordaDriftOptions.web].
    LocordaDriftWebOptions? web,

    /// Native performance tuning. Convenience shorthand for [LocordaDriftOptions.native].
    LocordaDriftNativeOptions? native,
  }) : _options = options ?? LocordaDriftOptions(web: web, native: native);

  @override
  List<MainHandlerFactory> create() {
    return [
      DriftNativeOptionsConnector.sender(
        id: id,
        enableWal: _options.native?.enableWal ?? false,
        readPool: _options.native?.readPool ?? 0,
      ),
      DriftConfigConnector.sender(_options, id),
    ];
  }
}
