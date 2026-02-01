/// Locorda Google Drive - Google Drive backend and authentication for locorda.
///
/// This library provides Google Drive integration for offline-first applications
/// using the locorda CRDT synchronization framework.
///
/// ## Quick Start
///
/// ```dart
/// import 'package:locorda_gdrive/locorda_gdrive.dart';
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
/// import 'package:locorda_gdrive/worker.dart';
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
library locorda_gdrive;

// Core backend
export 'src/gdrive_backend.dart' show /*GDriveBackend,*/ GDriveClientException;
export 'src/shared/gdrive_config.dart' show GDriveConfig, GDriveFolderMode;

// Authentication (internal use only, managed by GDriveMainIntegration)
export 'src/auth/gdrive_auth_provider.dart' show GDriveAuthProvider;
export 'src/gdrive_auth.dart' show GDriveAuth;

// Worker integration
//export 'src/main/gdrive_auth_connector.dart' show GDriveAuthConnector;

// UI components
export 'src/ui/gdrive_login_screen.dart' show GDriveLoginScreen;
export 'src/ui/gdrive_status_widget.dart' show GDriveStatusWidget;
export 'src/ui/gdrive_status_defaults.dart' show GDriveStatusDefaults;

// Plugin integration
export 'src/main/gdrive_main_integration.dart' show GDriveMainIntegration;

// Localizations
export 'l10n/gdrive_localizations.dart';
