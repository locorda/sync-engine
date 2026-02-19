/// Offline-first CRDT synchronization with Solid Pods.
///
/// This is the main entry point package that provides documentation,
/// examples, and convenient access to the locorda ecosystem.
///
/// ## Quick Start
///
/// ```dart
/// import 'package:locorda/locorda.dart';
/// import 'package:locorda_drift/locorda_drift.dart';
///
/// // Set up offline-first sync system
/// final storage = DriftStorage(path: 'app.db');
/// final sync = await Locorda.setup(storage: storage);
///
/// // Use your annotated models
/// final note = Note(
///   id: 'note-1',
///   title: 'My first note',
///   content: 'Offline-first with optional Solid sync!',
/// );
///
/// await sync.save(note);
/// final notes = await sync.getAll<Note>();
///
/// // Optionally connect to Solid Pod
/// final auth = SolidAuthProvider(/* config */);
/// await sync.connectToSolid(auth);
/// await sync.sync(); // Sync to pod
/// ```
///
/// ## Package Architecture
///
/// - `locorda_core` - Core sync engine and interfaces
/// - `locorda_annotations` - CRDT merge strategy annotations
/// - `locorda_drift` - SQLite storage backend
/// - `locorda_solid_auth` - Solid authentication
/// - `locorda_solid_ui` - Flutter UI components
library locorda;

// Re-export the main API from core
export 'package:locorda_flutter_core/locorda_flutter_core.dart'
    show LocordaGraph;
export 'package:locorda_flutter/locorda_flutter.dart' show Locorda;
export 'package:locorda_drift/locorda_drift.dart'
    show DriftMainHandler, LocordaDriftWebOptions;
export 'package:locorda_gdrive/locorda_gdrive.dart'
    show
        GDriveMainIntegration,
        GDriveAuth,
        GDriveAuthProvider,
        GDriveLocalizations,
        GDriveConfig,
        GDriveFolderMode,
        GDriveLocalMirrorConfig;
export 'package:locorda_solid/locorda_solid.dart'
    show SolidMainIntegration, SolidConfig;
export 'package:locorda_solid_auth/locorda_solid_auth.dart'
    show SolidAuthLocalizations;
export 'package:locorda_objects/locorda_objects.dart'
    show
        CrdtIndexConfig,
        FullIndexConfig,
        GroupIndexConfig,
        GroupingPropertyData,
        IndexItemConfig,
        ItemFetchPolicy,
        LocordaConfig,
        ObjectSyncEngine,
        RegexTransformData,
        ResourceConfig,
        defaultIndexLocalName,
        MapperInitializerFunction,
        TypedHydrationBatch;
export 'package:locorda_core/locorda_core.dart'
    show SyncManager, ItemFetchPolicy, SyncEngine, SyncEngineConfig;
export 'package:locorda_ui/locorda_ui.dart'
    show
        LocordaUILocalizations,
        LocordaStatusDefaults,
        LocordaStatusWidget,
        LocordaStatusState,
        MultiBackendStatusWidget,
        RemoteUiAdapter,
        UiAdapterRegistry,
        SyncRefreshIndicator;
export 'package:locorda_worker/worker_main.dart'
    show
        RemoteMainHandler,
        StorageMainHandler,
        MainHandler,
        MainHandlerFactory,
        InMemoryStorageMainHandler;
export 'package:locorda_annotations/locorda_annotations.dart'
    show
        CrdtImmutable,
        CrdtLwwRegister,
        CrdtOrSet,
        IndexItemIriStrategy,
        GroupKey,
        IndexItem,
        RootResource,
        RootResourceRef,
        SubResource,
        MergeIdentifying,
        RootIriStrategy,
        SubIriStrategy;
