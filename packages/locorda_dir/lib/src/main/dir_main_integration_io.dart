/// Local directory storage plugin - main thread implementation.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_dir/src/shared/consts.dart';
import 'package:locorda_flutter_core/locorda_flutter_core.dart';
import 'package:locorda_worker/worker_main.dart';
import 'package:path_provider/path_provider.dart';

import '../auth/dir_auth.dart';
import '../ui/dir_login_screen.dart';
import 'dir_auth_connector.dart';

/// Main-thread integration for local directory backend.
///
/// Provides file-based sync to a local directory on desktop platforms.
/// Users can view and backup synced data directly from the file system.
class DirMainIntegration implements RemoteIntegration {
  /// Platform support flag (desktop platforms only).
  static bool get isPlatformSupported =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  final DirAuth _dirAuth;

  @override
  final String id;

  @override
  final String displayName;

  DirMainIntegration._({
    required DirAuth dirAuth,
    required this.id,
    required this.displayName,
  }) : _dirAuth = dirAuth;

  /// Creates integration with automatic directory path detection.
  ///
  /// Uses platform-appropriate document directory:
  /// - macOS: ~/Documents/<appName>/locorda-sync/
  /// - Linux: ~/Documents/<appName>/locorda-sync/
  /// - Windows: %USERPROFILE%\Documents\<appName>\locorda-sync\
  ///
  /// [appName] is used for the subdirectory (defaults to 'locorda').
  /// [initiallyEnabled] determines if sync is enabled on startup (default: false).
  ///
  /// Note: DirAuth.create() automatically tests directory access on startup
  /// and disables sync if permission is denied.
  static Future<DirMainIntegration> create({
    String appName = 'locorda',
    bool initiallyEnabled = false,
    String id = directoryRemoteHandlerId,
    String displayName = 'Local Directory',
  }) async {
    final syncPath = await _getSyncDirectoryPath(appName, id);

    final dirAuth = await DirAuth.create(
      syncDirectoryPath: syncPath,
      initiallyEnabled: initiallyEnabled,
      id: id,
    );

    return DirMainIntegration._(
      dirAuth: dirAuth,
      id: id,
      displayName: displayName,
    );
  }

  /// Gets platform-appropriate sync directory path.
  static Future<String> _getSyncDirectoryPath(String appName, String id) async {
    // Sanitize ID for filesystem: replace problematic characters
    final sanitizedId = _sanitizeForFilesystem(id);

    if (Platform.isMacOS || Platform.isLinux || Platform.isWindows) {
      final docsDir = await getApplicationDocumentsDirectory();
      return '${docsDir.path}/$appName/$sanitizedId';
    }

    // Fallback for unsupported platforms (mobile)
    final appDir = await getApplicationSupportDirectory();
    return '${appDir.path}/$sanitizedId';
  }

  /// Sanitizes a string for use in filesystem paths.
  ///
  /// Replaces characters that are problematic in file/directory names:
  /// - `:` (colon) - reserved on Windows, problematic on macOS/Unix
  /// - `/` (forward slash) - path separator
  /// - `\` (backslash) - path separator on Windows
  /// - `*`, `?`, `"`, `<`, `>`, `|` - invalid on Windows
  static String _sanitizeForFilesystem(String input) {
    return input
        .replaceAll(':', '_')
        .replaceAll('/', '_')
        .replaceAll('\\', '_')
        .replaceAll('*', '_')
        .replaceAll('?', '_')
        .replaceAll('"', '_')
        .replaceAll('<', '_')
        .replaceAll('>', '_')
        .replaceAll('|', '_');
  }

  @override
  IconData get icon => Icons.folder_copy_outlined;

  @override
  Auth get auth => _dirAuth;

  @override
  List<MainHandlerFactory> get workerConnectors => [
        DirAuthConnector.sender(_dirAuth, id),
      ];

  @override
  Future<bool> showLogin(BuildContext context) async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => DirLoginScreen(dirAuth: _dirAuth),
      ),
    );
    return result ?? false;
  }
}
