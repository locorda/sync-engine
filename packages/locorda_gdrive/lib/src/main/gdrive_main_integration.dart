/// Google Drive storage plugin - main thread implementation.
library;

import 'package:flutter/material.dart';
import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_flutter_core/locorda_flutter_core.dart';
import 'package:locorda_gdrive/locorda_gdrive.dart';
import 'package:locorda_worker/worker_main.dart';

import 'gdrive_auth_connector.dart';
import 'gdrive_config_connector.dart';

/// Main-thread [RemoteMainHandler] implementation for Google Drive backend.
///
/// Encapsulates all Google Drive integration:
/// - Authentication via [GDriveAuth] (created internally)
/// - Configuration via [GDriveConfig]
/// - Login UI with Google OAuth2 flow
/// - Worker thread communication bridge
///
/// ## Usage
///
/// ```dart
/// final gdriveHandler = await GDriveMainIntegration.create(
///   config: GDriveConfig(), // Default: appDataFolder
/// );
///
/// final locorda = await Locorda.create(
///   remotes: [gdriveHandler],
///   // ... other config
/// );
/// ```
///
/// ## Lifecycle
///
/// The handler creates and manages [GDriveAuth] internally.
/// Call [dispose] when done to clean up resources.
class GDriveMainIntegration implements RemoteIntegration {
  final GDriveConfig _config;
  final GDriveAuth _gdriveAuth;

  GDriveMainIntegration._({
    required GDriveConfig config,
    required GDriveAuth gdriveAuth,
  })  : _config = config,
        _gdriveAuth = gdriveAuth;

  /// Creates a new [GDriveMainIntegration] with the given configuration.
  ///
  /// Initializes [GDriveAuth] with the correct OAuth scopes based on [config].
  static Future<GDriveMainIntegration> create({
    GDriveConfig config = const GDriveConfig(),
    String? clientId,
  }) async {
    final auth = await GDriveAuth.create(
      clientId: clientId,
      scopes: config.requiredScopes,
    );

    return GDriveMainIntegration._(
      config: config,
      gdriveAuth: auth,
    );
  }

  @override
  String get id => 'gdrive';

  @override
  String get displayName => 'Google Drive';

  @override
  IconData get icon => Icons.cloud;

  @override
  Auth get auth => _gdriveAuth;

  @override
  List<MainHandlerFactory> get workerConnectors => [
        GDriveAuthConnector.sender(_gdriveAuth),
        GDriveConfigConnector.sender(_config),
      ];

  @override
  Future<bool> showLogin(BuildContext context) async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => GDriveLoginScreen(
          onSignIn: _gdriveAuth.authenticate,
        ),
      ),
    );
    return result ?? false;
  }

  /// Clean up resources.
  Future<void> dispose() async {
    _gdriveAuth.dispose();
  }
}
