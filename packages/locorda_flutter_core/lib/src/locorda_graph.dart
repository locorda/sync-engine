/// Graph-based facade for the CRDT sync system.
///
/// This is an alternative to the high-level [Locorda] class for applications
/// that prefer working directly with RDF graphs instead of Dart domain objects.
///
/// **When to use LocordaGraph:**
/// - You want direct control over RDF data structures
/// - Your application works with dynamic/runtime-defined schemas
/// - You're building tools that manipulate arbitrary RDF data
///
/// **When to use Locorda instead:**
/// - You want to work with type-safe Dart domain classes
/// - You prefer automatic RDF mapping via annotations
/// - You want compile-time safety and IDE support for your data model
///
/// ## Key Differences from Locorda
///
/// | Feature | Locorda | LocordaGraph |
/// |---------|---------|--------------|
/// | Data model | Dart classes (`Note`, `Category`) | `RdfGraph` |
/// | Mapping | Automatic via `@LocordaResource` | Manual |
/// | Configuration | `LocordaConfig` with resource types | `SyncEngineConfig` with IRIs |
/// | Type safety | Compile-time | Runtime |
/// | API | `save<Note>(note)` | `save(typeIri, graph)` |
library;

import 'dart:async';

import 'integration.dart';

import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:locorda_ui/locorda_ui.dart';
import 'package:locorda_worker/worker_main.dart';

/// Graph-based facade for CRDT sync with direct RDF access.
///
/// Provides low-level RDF graph operations without automatic object mapping.
/// See [Locorda] for the high-level, object-oriented alternative.
class LocordaGraph {
  final SyncEngine _syncSystem;
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
  /// Provides access to configured remotes (Solid, GDrive, etc.) for
  /// UI widgets like authentication dialogs and sync status displays.
  UiAdapterRegistry get uiAdapterRegistry => _uiAdapterRegistry;

  /// Direct access to the underlying SyncEngine for advanced operations.
  ///
  /// Provides graph-level operations:
  /// - `save(typeIri, graph)`: Save RDF graph with CRDT processing
  /// - `deleteDocument(typeIri, documentIri)`: Delete document
  /// - `hydrateStream(typeIri, ...)`: Stream of RDF graph updates
  /// - `ensure(typeIri, documentIri, ...)`: Ensure resource availability
  SyncEngine get syncEngine => _syncSystem;
  LocordaGraph._({
    required SyncEngine syncEngine,
    required UiAdapterRegistry uiAdapterRegistry,
  })  : _syncSystem = syncEngine,
        _uiAdapterRegistry = uiAdapterRegistry;

  /// Creates LocordaGraph with SyncEngine running in a separate worker thread.
  ///
  /// This is the graph-based alternative to [Locorda.create()], providing
  /// direct RDF graph access without automatic object mapping.
  ///
  /// ## Complete Example
  ///
  /// **1. Main thread:**
  ///
  /// ```dart
  /// import 'package:locorda_flutter_core/locorda_flutter_core.dart';
  /// import 'package:locorda_rdf_core/core.dart';
  ///
  /// // Initialize auth
  /// final solidAuth = SolidAuth(...);
  /// await solidAuth.init();
  ///
  /// // Create LocordaGraph with worker architecture
  /// final locordaGraph = await LocordaGraph.create(
  ///   workerSetup: setupWorkerEngine,
  ///   onWorkerSpawn: setupWorkerLogging,
  ///
  ///   // Main thread handlers
  ///   remotes: [SolidMainIntegration(solidAuth: solidAuth)],
  ///   storage: DriftMainHandler(),
  ///
  ///   // Low-level configuration with RDF IRIs
  ///   config: SyncEngineConfig(
  ///     resources: [
  ///       ResourceTypeConfig(
  ///         typeIri: IriTerm.validated('https://example.org/Note'),
  ///         crdtMapping: Uri.parse('https://example.org/mappings/note-v1.ttl'),
  ///         indices: [
  ///           IndexConfig(
  ///             name: 'notes_by_month',
  ///             type: IndexType.group,
  ///             rootResourceFetchPolicy: RootResourceFetchPolicy.prefetch,
  ///           ),
  ///         ],
  ///       ),
  ///     ],
  ///   ),
  /// );
  ///
  /// // Work with RDF graphs directly
  /// final noteGraph = RdfGraph.fromTriples([
  ///   Triple(
  ///     subject: IriTerm.validated('https://example.org/notes/123#it'),
  ///     predicate: IriTerm.validated('http://schema.org/name'),
  ///     object: LiteralTerm.string('My Note'),
  ///   )]);
  ///
  /// // Save to sync system
  /// final noteTypeIri = IriTerm.validated('https://example.org/Note');
  /// locordaGraph.syncEngine.save(noteTypeIri, noteGraph);
  ///
  /// // Stream graph updates
  /// locordaGraph.syncEngine.hydrateStream(
  ///   typeIri: noteTypeIri,
  /// ).listen((batch) {
  ///   for (final (iri, graph) in batch.updates) {
  ///     // Process RdfGraph directly
  ///     print('Updated: $iri');
  ///     for (final triple in graph.triples) {
  ///       print('  $triple');
  ///     }
  ///   }
  /// });
  /// ```
  ///
  /// **2. Worker thread** (same as Locorda):
  ///
  /// ```dart
  /// import 'package:locorda/worker.dart';
  ///
  /// void main() {
  ///   workerMain(setupWorkerEngine, onWorkerSpawn: setupWorkerLogging);
  /// }
  ///
  /// Future<WorkerParams> setupWorkerEngine() async => WorkerParams(
  ///   remotes: [SolidWorkerHandler()],
  ///   storage: DriftWorkerHandler(...),
  /// );
  /// ```
  ///
  /// ## Architecture
  ///
  /// Same worker architecture as [Locorda], but without object mapping layer:
  ///
  /// ```
  /// Main Thread:                    Worker Thread:
  ///   ├─ LocordaGraph                 ├─ SyncEngine
  ///   │  ├─ RdfGraph operations       │  ├─ CRDT merge
  ///   │  │  (manual)                  │  ├─ Database I/O
  ///   │  └─ ProxySyncEngine ─────────>│  ├─ HTTP requests
  ///   │     (forwards calls)          │  └─ DPoP signing
  ///   └─ UI                           └─ (heavy work here)
  /// ```
  ///
  /// ## Key Differences from Locorda.create()
  ///
  /// - **No `mapperInitializer`**: You work with raw RDF graphs
  /// - **Uses `SyncEngineConfig`**: Direct IRI-based configuration instead of `LocordaConfig`
  /// - **Manual serialization**: You control RDF graph creation and parsing
  /// - **Lower-level API**: More control, less convenience
  ///
  /// ## When to Use
  ///
  /// - Building RDF tools or editors
  /// - Dynamic schemas determined at runtime
  /// - Working with non-standard RDF patterns
  ///
  /// For most applications, prefer [Locorda.create()] for type-safe Dart objects.
  ///
  /// ## Parameters
  ///
  /// - [workerSetup]: Function that configures worker-side handlers
  /// - [onWorkerSpawn]: Optional callback for worker initialization
  /// - [remotes]: Main thread handlers for remote backends (Solid, GDrive, etc.)
  /// - [storage]: Main thread handler for storage backend
  /// - [config]: Low-level sync engine configuration with RDF IRIs
  /// - [jsScript]: Web worker JS filename (default: 'worker.dart.js')
  /// - [plugins]: Additional worker plugins for custom functionality
  /// - [debugName]: Optional name for debugging worker communication
  ///
  /// Throws [SyncConfigValidationException] if the configuration is invalid.
  static Future<LocordaGraph> create({
    required WorkerSetup workerSetup,
    void onWorkerSpawn()?,
    required SyncEngineConfig config,
    required StorageMainHandler storage,
    String jsScript = 'worker.dart.js',
    List<RemoteIntegration> remotes = const [],
    List<MainHandlerFactory> plugins = const [],
    IriTermFactory? iriTermFactory,
    RdfCore? rdfCore,
    String? debugName,
  }) async {
    final syncEngine = await SyncEngineWithWorker.create(
      jsScript: jsScript,
      workerSetup: workerSetup,
      remotes: remotes,
      storage: storage,
      plugins: plugins,
      syncEngineConfig: config,
      debugName: debugName,
      onWorkerSpawn: onWorkerSpawn,
    );
    return LocordaGraph._(
      syncEngine: syncEngine,
      uiAdapterRegistry: UiAdapterRegistry.withRemotes(remotes),
    );
  }

  /// Close the sync system and free resources.
  Future<void> close() async {
    await _syncSystem.close();
  }
}
