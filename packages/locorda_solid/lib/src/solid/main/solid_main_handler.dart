/// Solid Pod storage plugin - main thread implementation.
library;

import 'package:flutter/material.dart';
import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_flutter_core/locorda_flutter_core.dart';
import 'package:locorda_solid_auth/locorda_solid_auth.dart';
import 'package:locorda_solid_auth_worker/locorda_solid_auth_worker.dart';
import 'package:locorda_worker/worker_main.dart';
import 'package:solid_auth/solid_auth.dart';

/// Main-thread [RemoteMainHandler] implementation for Solid Pod backend.
///
/// Encapsulates all Solid Pod integration:
/// - Authentication via [SolidAuth]
/// - Login UI with provider selection
/// - Worker thread communication bridge
///
/// ## Usage
///
/// ```dart
/// final solidAuth = await SolidAuth.create();
///
/// final solidPlugin = SolidMainHandler(
///   solidAuth: solidAuth,
///   // Optional: custom provider service
///   providerService: SolidProviderService(),
/// );
///
/// // Register in plugin registry
/// final registry = MainRemoteRegistry([solidPlugin]);
/// ```
///
/// ## Lifecycle
///
/// The caller is responsible for disposing [solidAuth] when done.
/// The plugin does not take ownership of the auth instance.
class SolidMainHandler implements RemoteIntegration {
  final SolidAuth _solidAuth;
  final SolidProviderService _providerService;
  late final SolidAuthBridge _authBridge;

  SolidMainHandler({
    required SolidAuth solidAuth,
    SolidProviderService? providerService,
  })  : _solidAuth = solidAuth,
        _providerService =
            providerService ?? const DefaultSolidProviderService(),
        _authBridge = SolidAuthBridge(solidAuth);

  @override
  String get id => 'solid';

  @override
  String get displayName => 'Solid Pod';

  @override
  IconData get icon => Icons.cloud_sync_rounded;

  @override
  Auth get auth => _authBridge;

  @override
  List<MainHandlerFactory> get workerConnectors => [
        SolidAuthConnector.sender(_solidAuth),
      ];

  @override
  Future<bool> showLogin(BuildContext context) async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => SolidLoginScreen(
          solidAuth: _solidAuth,
          providerService: _providerService,
        ),
      ),
    );
    return result ?? false;
  }
}
