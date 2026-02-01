/// Locorda Google Drive - Google Drive backend and authentication for locorda.
///
/// This library provides Google Drive integration for offline-first applications
/// using the locorda CRDT synchronization framework.
///
/// ## Quick Start
///
/// ```dart
/// import 'package:locorda_gdrive_slow/locorda_gdrive_slow.dart';
///
/// // Create GDrive handler (uses recommended defaults)
/// final gdriveHandler = await GDriveMainIntegration.create();
///
/// // Create Locorda with handler
/// final locorda = await Locorda.create(
///   remotes: [gdriveHandler],
///   config: LocordaConfig(
///     resources: [/* your resources */],
///   ),
/// );
///
/// // Use in UI
/// AppBar(
///   actions: [
///     MultiBackendStatusWidget(
///       registry: locorda.uiAdapterRegistry,
///       syncManager: locorda.syncManager,
///     ),
///   ],
/// )
/// ```
///
/// ## Worker Thread
///
/// ```dart
/// // worker.dart
/// import 'package:locorda_gdrive_slow/worker.dart';
///
/// Future<WorkerParams> setupWorkerEngine() async => WorkerParams(
///   remotes: [
///     GDriveWorkerHandler(), // Config received automatically
///   ],
/// );
/// ```
///
/// ## Storage Modes
///
/// - **App Data Folder** (default): Private, invisible to user, better performance
/// - **Visible Folder**: User can see and manage files in My Drive
///
/// Configuration is defined once in main thread and automatically synchronized:
///
/// ```dart
/// // App Data Folder (default) - simplest setup
/// await GDriveMainIntegration.create()
///
/// // Visible Folder
/// await GDriveMainIntegration.create(
///   config: GDriveConfig.visibleFolder(appFolderName: 'MyApp'),
/// )
/// ```
///
/// OAuth client IDs are configured per-platform (Info.plist, google-services.json, etc).
/// Scopes are set automatically based on configuration.
library locorda_gdrive_slow;

// Core backend
export 'src/gdrive_backend.dart'
    show /*GDriveBackend,*/ GDriveSlowClientException;
export 'src/gdrive_type_index_manager.dart'
    show GDriveSlowConfig, GDriveSlowFolderMode;

// Authentication (internal use only, managed by GDriveMainIntegration)
export 'src/auth/gdrive_auth_provider.dart' show GDriveSlowAuthProvider;
export 'src/gdrive_auth.dart' show GDriveSlowAuth;

// Worker integration
//export 'src/main/gdrive_auth_connector.dart' show GDriveAuthConnector;

// UI components
export 'src/ui/gdrive_login_screen.dart' show GDriveSlowLoginScreen;
export 'src/ui/gdrive_status_widget.dart' show GDriveSlowStatusWidget;
export 'src/ui/gdrive_status_defaults.dart' show GDriveSlowStatusDefaults;

// Plugin integration
export 'src/main/gdrive_main_integration.dart' show GDriveSlowMainIntegration;

// Localizations
export 'l10n/gdrive_localizations.dart';
