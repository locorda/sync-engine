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
///     web: LocordaDriftWebOptions(
///       sqlite3Wasm: Uri.parse('sqlite3.wasm'),
///       driftWorker: Uri.parse('drift_worker.js'),
///     ),
///   ),
///   // ...
/// );
/// ```
///
/// ## Native path resolution
///
/// Database and temporary directory paths are resolved automatically via
/// `path_provider` (`getApplicationDocumentsDirectory` /
/// `getTemporaryDirectory`). No path configuration is required for the vast
/// majority of apps. The [native] parameter is therefore optional and only
/// needed for performance tuning (see [LocordaDriftNativeOptions]).
///
/// ## Web configuration — [web]
///
/// Required on web platforms. Provides the URIs to the compiled
/// `sqlite3.wasm` module and the Drift web worker script. Omit on
/// native-only apps.
///
/// ## Native performance tuning — [native]
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
  final LocordaDriftWebOptions? _webOptions;
  final LocordaDriftNativeOptions? _nativeOptions;

  DriftMainHandler({
    this.id = driftStorageHandlerId,

    /// Web platform configuration. Required on web; omit on native-only apps.
    LocordaDriftWebOptions? web,

    /// Native performance tuning. Optional — paths are resolved automatically.
    /// Set `readPool: 2` for large sync workloads (>50 shards); leaves
    /// `readPool = 0` (default) for small datasets to avoid 3-isolate overhead.
    LocordaDriftNativeOptions? native,
  })  : _webOptions = web,
        _nativeOptions = native;

  @override
  List<MainHandlerFactory> create() {
    return [
      DriftNativeOptionsConnector.sender(
        id: id,
        enableWal: _nativeOptions?.enableWal ?? false,
        readPool: _nativeOptions?.readPool ?? 0,
      ),
      DriftConfigConnector.sender(_webOptions, id),
    ];
  }
}
