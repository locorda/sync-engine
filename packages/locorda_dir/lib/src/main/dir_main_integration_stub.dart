/// Local directory storage plugin - main thread implementation.
library;

import 'package:flutter/material.dart';
import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_dir/src/shared/consts.dart';
import 'package:locorda_flutter_core/locorda_flutter_core.dart';
import 'package:locorda_worker/worker_main.dart';

class DirMainIntegration implements RemoteIntegration {
  static bool get isPlatformSupported => false;

  final String id;

  DirMainIntegration._({required this.id});

  static Future<DirMainIntegration> create({
    String appName = 'locorda',
    bool initiallyEnabled = false,
    String id = directoryRemoteHandlerId,
    String displayName = 'Local Directory',
  }) async {
    throw UnimplementedError(
        'Local directory integration is not supported on this platform.');
  }

  @override
  String get displayName => 'Local Directory (Disabled)';

  @override
  IconData get icon => Icons.folder_copy_outlined;

  @override
  Auth get auth => throw UnimplementedError(
      'Local directory auth is not supported on this platform.');

  @override
  List<MainHandlerFactory> get workerConnectors => [];

  @override
  Future<bool> showLogin(BuildContext context) async {
    return false;
  }
}
