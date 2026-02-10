/// Simple authentication for local directory backend.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:locorda_core/locorda_core.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shared/consts.dart';
import 'dir_auth_provider.dart';

final _log = Logger('DirAuth');

const _kEnabledKey = 'locorda_dir_enabled';
const _kPathKey = 'locorda_dir_sync_path';

/// ValueListenable implementation for authentication state.
class _AuthValueListenableImpl implements AuthValueListenable {
  final ValueNotifier<bool> _notifier;

  _AuthValueListenableImpl(this._notifier);

  @override
  bool get isAuthenticated => _notifier.value;

  @override
  void addListener(void Function() listener) {
    _notifier.addListener(listener);
  }

  @override
  void removeListener(void Function() listener) {
    _notifier.removeListener(listener);
  }
}

/// Simple boolean-based authentication for local directory backend.
///
/// Provides a toggle to enable/disable local directory sync.
/// When enabled, files are synced to a local directory on disk.
/// This is primarily for desktop platforms where users can access the file system.
class DirAuth implements DirAuthProvider {
  final ValueNotifier<bool> _isAuthenticatedNotifier;
  late final _AuthValueListenableImpl _authListenable;
  String _syncDirectoryPath;
  final String _id;

  DirAuth._({
    required bool initiallyEnabled,
    required String syncDirectoryPath,
    required String id,
  })  : _isAuthenticatedNotifier = ValueNotifier(initiallyEnabled),
        _syncDirectoryPath = syncDirectoryPath,
        _id = id {
    _authListenable = _AuthValueListenableImpl(_isAuthenticatedNotifier);
    _log.info(
        'DirAuth initialized: enabled=$initiallyEnabled, path=$syncDirectoryPath');
  }

  static String _getKPathKey(String id) =>
      id == directoryRemoteHandlerId ? _kPathKey : '${_kPathKey}_$id';
  static String _getKEnabledKey(String id) =>
      id == directoryRemoteHandlerId ? _kEnabledKey : '${_kEnabledKey}_$id';

  /// Creates DirAuth with initial state.
  ///
  /// [syncDirectoryPath] is the directory where sync files will be stored.
  /// [initiallyEnabled] determines if sync is enabled on startup (default: false).
  ///
  /// State is persisted to SharedPreferences and restored on subsequent launches.
  ///
  /// Automatically tests directory access if sync is enabled and disables it
  /// if access is denied (e.g., macOS sandbox permission issues).
  static Future<DirAuth> create({
    required String syncDirectoryPath,
    bool initiallyEnabled = false,
    String id = directoryRemoteHandlerId,
  }) async {
    final prefs = await SharedPreferences.getInstance();

    // Load persisted state, fallback to constructor params
    final savedPath = prefs.getString(_getKPathKey(id)) ?? syncDirectoryPath;
    final savedEnabled = prefs.getBool(_getKEnabledKey(id)) ?? initiallyEnabled;

    final auth = DirAuth._(
      initiallyEnabled: savedEnabled,
      syncDirectoryPath: savedPath,
      id: id,
    );

    // Test directory access if sync is supposed to be enabled
    if (savedEnabled) {
      final hasAccess = await auth.testDirectoryAccess();
      if (!hasAccess) {
        _log.warning('Directory access test failed on startup, disabling sync. '
            'User will need to re-enable and grant permission via file picker.');
        await auth.disable();
      }
    }

    return auth;
  }

  /// Directory path where sync files are stored.
  String get syncDirectoryPath => _syncDirectoryPath;

  /// Update the sync directory path.
  ///
  /// This will disable sync if currently enabled, then update the path.
  /// Call [enable] again after updating to re-enable sync with the new path.
  Future<void> updateSyncDirectoryPath(String newPath) async {
    if (_isAuthenticatedNotifier.value) {
      await disable();
    }
    _log.info('Updating sync directory path: $_syncDirectoryPath -> $newPath');
    _syncDirectoryPath = newPath;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_getKPathKey(_id), newPath);
  }

  /// Test if the app has access to the sync directory.
  ///
  /// Returns true if directory is accessible, false otherwise.
  /// This tests both read and write permissions by attempting to:
  /// 1. Create the directory if it doesn't exist
  /// 2. Create and delete a temporary test file
  ///
  /// Times out after 5 seconds to prevent blocking the app startup.
  Future<bool> testDirectoryAccess() async {
    try {
      // Add timeout to prevent hanging on permission dialogs
      return await Future.any([
        _performAccessTest(),
        Future.delayed(const Duration(seconds: 5), () => false),
      ]);
    } catch (e, stackTrace) {
      _log.warning(
          'Directory access test failed: $_syncDirectoryPath', e, stackTrace);
      return false;
    }
  }

  Future<bool> _performAccessTest() async {
    final dir = Directory(_syncDirectoryPath);

    // Try to create directory
    if (!await dir.exists()) {
      await dir.create(recursive: true);
      _log.fine('Created sync directory: $_syncDirectoryPath');
    }

    // Try to write and read a test file
    final testFile = File('${_syncDirectoryPath}/.locorda_access_test');
    await testFile.writeAsString('test');
    await testFile.readAsString();
    await testFile.delete();

    _log.fine('Directory access test passed: $_syncDirectoryPath');
    return true;
  }

  /// Enable local directory sync.
  Future<void> enable() async {
    _log.info('Enabling local directory sync');
    _isAuthenticatedNotifier.value = true;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_getKEnabledKey(_id), true);
  }

  /// Disable local directory sync.
  Future<void> disable() async {
    _log.info('Disabling local directory sync');
    _isAuthenticatedNotifier.value = false;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_getKEnabledKey(_id), false);
  }

  @override
  Future<bool> isAuthenticated() async => _isAuthenticatedNotifier.value;

  @override
  AuthValueListenable get isAuthenticatedNotifier => _authListenable;

  @override
  String? get userDisplayName =>
      _isAuthenticatedNotifier.value ? 'Local Directory' : null;

  @override
  Future<void> logout() => disable();
}
