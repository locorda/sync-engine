/// Google Drive storage plugin - main thread implementation.
library;

import 'package:flutter/material.dart';
import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_flutter_core/locorda_flutter_core.dart';
import 'package:locorda_gdrive/locorda_gdrive.dart';
import 'package:locorda_worker/worker_main.dart';

import 'gdrive_auth_connector.dart';

/// Main-thread [RemoteMainHandler] implementation for Google Drive backend.
///
/// Encapsulates all Google Drive integration:
/// - Authentication via [GDriveAuth]
/// - Login UI with Google OAuth2 flow
/// - Worker thread communication bridge
///
/// ## Usage
///
/// ```dart
/// final gdriveAuth = await GDriveAuth.create(
///   clientId: 'your-client-id.apps.googleusercontent.com',
/// );
///
/// final gdrivePlugin = GDrivePlugin(
///   gdriveAuth: gdriveAuth,
/// );
///
/// // Register in plugin registry
/// final registry = StoragePluginRegistry([gdrivePlugin]);
/// ```
///
/// ## Lifecycle
///
/// The caller is responsible for disposing [gdriveAuth] when done.
/// The plugin does not take ownership of the auth instance.
class GDriveMainHandler implements RemoteIntegration {
  final GDriveAuth _gdriveAuth;

  GDriveMainHandler({
    required GDriveAuth gdriveAuth,
  }) : _gdriveAuth = gdriveAuth;

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
}
