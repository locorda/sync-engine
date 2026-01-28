/// Locorda Google Drive - Google Drive backend and authentication for locorda.
///
/// This library provides Google Drive integration for offline-first applications
/// using the locorda CRDT synchronization framework.
///
/// ## Main Thread Usage
///
/// ```dart
/// import 'package:locorda_gdrive/locorda_gdrive.dart';
///
/// // Initialize Google Drive auth (silent sign-in automatic)
/// final gdriveAuth = await GDriveAuth.create(
///   clientId: 'your-client-id.apps.googleusercontent.com', // Optional
///   scopes: [
///     'https://www.googleapis.com/auth/drive.file',
///     'https://www.googleapis.com/auth/userinfo.email',
///   ],
/// );
///
/// // Create sync system with worker
/// final locorda = await Locorda.createWithWorker(
///   engineParamsFactory: createEngineParams,
///   jsScript: 'worker.dart.js',
///   plugins: [
///     GDriveAuthConnector.sender(gdriveAuth),
///   ],
///   // ... other config
/// );
///
/// // Use in UI
/// AppBar(
///   actions: [
///     GDriveStatusWidget(
///       gdriveAuth: gdriveAuth,
///       syncManager: locorda.syncManager,
///     ),
///   ],
/// )
/// ```
library locorda_gdrive;

// Core backend
export 'src/gdrive_backend.dart' show /*GDriveBackend,*/ GDriveClientException;

// Authentication
export 'src/auth/gdrive_auth_provider.dart' show GDriveAuthProvider;
export 'src/gdrive_auth.dart' show GDriveAuth;

// Worker integration
//export 'src/main/gdrive_auth_connector.dart' show GDriveAuthConnector;

// UI components
export 'src/ui/gdrive_login_screen.dart' show GDriveLoginScreen;
export 'src/ui/gdrive_status_widget.dart' show GDriveStatusWidget;
export 'src/ui/gdrive_status_defaults.dart' show GDriveStatusDefaults;

// Plugin integration
export 'src/main/gdrive_main_remote.dart' show GDriveMainHandler;

// Localizations
export 'l10n/gdrive_localizations.dart';
