library locorda;

// Re-export the main API from core
export 'package:locorda_flutter_core/locorda_flutter_core.dart'
    show LocordaGraph;
export 'package:locorda_flutter/locorda_flutter.dart' show Locorda;
export 'package:locorda_drift/locorda_drift.dart'
    show DriftMainHandler, LocordaDriftWebOptions, LocordaDriftNativeOptions;
export 'package:locorda_objects/locorda_objects.dart'
    show
        CrdtIndexConfig,
        FullIndexConfig,
        GroupIndexConfig,
        GroupingPropertyData,
        IndexItemConfig,
        RootResourceFetchPolicy,
        LocordaConfig,
        ObjectSyncEngine,
        RegexTransformData,
        ResourceConfig,
        defaultIndexLocalName,
        MapperInitializerFunction,
        TypedHydrationBatch;
export 'package:locorda_core/locorda_core.dart'
    show
        SyncManager,
        RootResourceFetchPolicy,
        SyncEngine,
        SyncEngineConfig,
        StandardSyncManager,
        StandardSyncEngine,
        SimpleConfigService,
        AuthValueListenable,
        Auth,
        RemoteStorageLayout,
        FilePerResource,
        ShardDataset,
        SingleFile;
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
