/// Main facade for the CRDT sync system.
library;

import 'dart:async';

import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:locorda_worker/worker_main.dart';
import 'package:locorda_ui/locorda_ui.dart';
import 'package:locorda_flutter_core/locorda_flutter_core.dart';
import 'package:locorda_objects/locorda_objects.dart';

/// Main facade for the locorda system.
///
/// Provides a simple, high-level API for offline-first applications with
/// optional Solid Pod synchronization. Handles RDF mapping, storage,
/// and sync operations transparently.
class Locorda {
  final ObjectSyncEngine _syncSystem;
  final UiAdapterRegistry _uiAdapterRegistry;

  /// Access the sync manager for manual sync triggering and status monitoring.
  ///
  /// Use this to:
  /// - Trigger manual sync: `syncManager.sync()`
  /// - Monitor sync status: `syncManager.statusStream`
  /// - Access current state: `syncManager.currentState`
  /// - Control automatic sync: `syncManager.enableAutoSync()` / `disableAutoSync()`
  SyncManager get syncManager => _syncSystem.syncManager;

  /// Access the remote plugin registry for multi-backend UI integration.
  ///
  /// Only available when using [create] with [uiAdapterRegistry].
  /// Provides:
  /// - Active and authenticated plugins
  /// - Plugin query and lookup methods
  /// - UI integration via [MultiBackendStatusWidget]
  ///
  UiAdapterRegistry get uiAdapterRegistry => _uiAdapterRegistry;

  ObjectSyncEngine get syncEngine => _syncSystem;

  Locorda._({
    required ObjectSyncEngine syncEngine,
    required UiAdapterRegistry uiAdapterRegistry,
  })  : _syncSystem = syncEngine,
        _uiAdapterRegistry = uiAdapterRegistry;

  /// Creates Locorda with SyncEngine running in a separate worker thread.
  ///
  /// This is the recommended way to use Locorda in production applications.
  /// It keeps the main thread responsive by offloading all heavy operations
  /// (CRDT merge, database I/O, HTTP requests, DPoP signing) to a worker thread.
  ///
  /// ## Complete Working Example
  ///
  /// See the Personal Notes App in `packages/locorda/example/personal_notes_app` for a full implementation.
  ///
  /// **1. Main thread** (lib/main.dart):
  ///
  /// ```dart
  /// import 'package:locorda/locorda.dart';
  /// import 'package:personal_notes_app/worker.dart';
  ///
  /// // Initialize auth (runs on main thread for UI access)
  /// final solidAuth = SolidAuth(
  ///   oidcClientId: '$appBaseUrl/auth/client-config.json',
  ///   appUrlScheme: 'dev.locorda.example.personalNotesApp',
  ///   frontendRedirectUrl: Uri.parse('$appBaseUrl/redirect.html'),
  /// );
  /// await solidAuth.init();
  ///
  /// final gdriveAuth = await GDriveAuth.create();
  ///
  /// // Create Locorda with worker architecture
  /// final locorda = await Locorda.create(
  ///   // Worker setup function (defined in worker.dart)
  ///   workerSetup: setupWorkerEngine,
  ///   onWorkerSpawn: setupWorkerLogging,  // Optional: configure worker logging
  ///
  ///   // Main thread handlers (bridge between UI and worker)
  ///   remotes: [
  ///     SolidMainIntegration(solidAuth: solidAuth),
  ///     GDriveMainIntegration(gdriveAuth: gdriveAuth),
  ///   ],
  ///   storage: DriftMainHandler(),
  ///
  ///   // RDF mapper configuration (runs on main thread)
  ///   mapperInitializer: (context) => initRdfMapper(
  ///     rdfMapper: context.baseRdfMapper,
  ///     $indexItemIriFactory: context.indexItemIriFactory,
  ///     $resourceIriFactory: context.resourceIriFactory,
  ///     $resourceRefFactory: context.resourceRefFactory,
  ///   ),
  ///
  ///   // Resource configuration
  ///   config: LocordaConfig(
  ///     resources: [
  ///       ResourceConfig(
  ///         type: Note,
  ///         crdtMapping: Uri.parse('$appBaseUrl/mappings/note-v1.ttl'),
  ///         indices: [GroupIndexConfig(NoteGroupKey, item: IndexItemConfig(...))],
  ///       ),
  ///       ResourceConfig(
  ///         type: Category,
  ///         crdtMapping: Uri.parse('$appBaseUrl/mappings/category-v1.ttl'),
  ///         indices: [FullIndexConfig(rootResourceFetchPolicy: RootResourceFetchPolicy.prefetch)],
  ///       ),
  ///     ],
  ///   ),
  /// );
  ///
  /// // Use in UI
  /// NotesListScreen(
  ///   notesService: notesService,
  ///   categoriesService: categoriesService,
  ///   uiAdapterRegistry: locorda.uiAdapterRegistry,  // For auth UI widgets
  ///   syncManager: locorda.syncManager,              // For sync status
  /// );
  /// ```
  ///
  /// **2. Worker thread** (lib/worker.dart):
  ///
  /// ```dart
  /// import 'package:locorda/worker.dart';
  ///
  /// // Worker entry point
  /// void main() {
  ///   workerMain(setupWorkerEngine, onWorkerSpawn: setupWorkerLogging);
  /// }
  ///
  /// // Configure worker-side sync engine
  /// Future<WorkerParams> setupWorkerEngine() async => WorkerParams(
  ///   // Worker handlers (perform actual operations: HTTP, DB, CRDT)
  ///   remotes: [
  ///     SolidWorkerHandler(),
  ///     GDriveWorkerHandler(
  ///       config: GDriveConfig(appFolderName: 'LocordaPersonalNotes'),
  ///     ),
  ///   ],
  ///
  ///   // Storage backend configuration
  ///   storage: DriftWorkerHandler(
  ///     web: LocordaDriftWebOptions(
  ///       sqlite3Wasm: Uri.parse('sqlite3.wasm'),
  ///       driftWorker: Uri.parse('drift_worker.js'),
  ///     ),
  ///   ),
  /// );
  /// ```
  ///
  /// ## Architecture
  ///
  /// ```
  /// Main Thread:                    Worker Thread:
  ///   ├─ Locorda                      ├─ SyncEngine
  ///   │  ├─ RDF mapping               │  ├─ CRDT merge
  ///   │  ├─ Dart objects              │  ├─ Database I/O
  ///   │  └─ ProxySyncEngine ─────────>│  ├─ HTTP requests
  ///   │     (forwards calls)          │  └─ DPoP signing
  ///   ├─ MainHandlers                 ├─ WorkerHandlers
  ///   │  └─ Auth UI bridges           │  └─ Backend operations
  ///   └─ UI (stays responsive!)       └─ (heavy work here)
  /// ```
  ///
  /// ## Key Concepts
  ///
  /// **Main/Worker Handler Pairs**: Each backend (Solid, GDrive) and storage
  /// (Drift) has two handlers:
  /// - `*MainHandler`: Runs on main thread, handles UI (auth dialogs) and
  ///   forwards operations to worker
  /// - `*WorkerHandler`: Runs in worker, performs actual backend operations
  ///
  /// **Communication**: JSON messages with Turtle-serialized RDF graphs.
  /// ~1-2ms overhead per operation (negligible vs actual work).
  ///
  /// **UI Integration**: Use `locorda.uiAdapterRegistry` with UI widgets for
  /// multi-backend auth status and controls.
  ///
  /// ## Platform Support
  ///
  /// - **Native (iOS/Android/Desktop)**: Dart isolates via `Isolate.spawn()`
  /// - **Web**: Web Workers (compile with: `dart compile js lib/worker.dart`)
  ///
  /// ## Parameters
  ///
  /// - [workerSetup]: Function that configures worker-side handlers (see worker.dart example)
  /// - [onWorkerSpawn]: Optional callback for worker initialization (e.g., logging setup)
  /// - [remotes]: Main thread handlers for remote backends (Solid, GDrive, etc.)
  /// - [storage]: Main thread handler for storage backend (typically Drift)
  /// - [config]: Resource configuration with types, CRDT mappings, and indices
  /// - [mapperInitializer]: Function to configure RDF mapping
  /// - [jsScript]: Web worker JS filename (default: 'worker.dart.js' for manual worker,
  ///   use 'worker_generated.dart.js' for generated worker)
  /// - [plugins]: Additional worker plugins for custom functionality
  /// - [debugName]: Optional name for debugging worker communication
  ///
  /// Throws [SyncConfigValidationException] if the configuration is invalid.
  static Future<Locorda> create({
    required WorkerSetup workerSetup,
    void onWorkerSpawn()?,
    required LocordaConfig config,
    required MapperInitializerFunction mapperInitializer,
    required StorageMainHandler storage,
    String jsScript = 'worker.dart.js',
    List<RemoteIntegration> remotes = const [],
    List<MainHandlerFactory> plugins = const [],
    IriTermFactory? iriTermFactory,
    RdfCore? rdfCore,
    String? debugName,
    Perflog? perflog,
  }) async {
    perflog ??= Perflog.root();
    // Create storage plugin registry if plugins provided
    final uiAdapterRegistry = UiAdapterRegistry.withRemotes(remotes);

    final ObjectSyncEngine syncEngine = await ObjectSyncEngine.create(
      config: config,
      mapperInitializer: mapperInitializer,
      iriTermFactory: iriTermFactory,
      rdfCore: rdfCore,
      perflog: perflog,
      syncEngineFactory: (config) => SyncEngineWithWorker.create(
        jsScript: jsScript,
        workerSetup: workerSetup,
        remotes: remotes,
        storage: storage,
        plugins: plugins,
        syncEngineConfig: config,
        debugName: debugName,
        onWorkerSpawn: onWorkerSpawn,
      ),
    );

    return Locorda._(
      syncEngine: syncEngine,
      uiAdapterRegistry: uiAdapterRegistry,
    );
  }

  /// Close the sync system and free resources.
  Future<void> close() async {
    await _syncSystem.close();
  }
}
