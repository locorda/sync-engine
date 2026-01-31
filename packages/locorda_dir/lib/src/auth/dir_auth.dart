/// Simple authentication for local directory backend.
library;

import 'package:flutter/foundation.dart';
import 'package:locorda_core/locorda_core.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  DirAuth._({
    required bool initiallyEnabled,
    required String syncDirectoryPath,
  })  : _isAuthenticatedNotifier = ValueNotifier(initiallyEnabled),
        _syncDirectoryPath = syncDirectoryPath {
    _authListenable = _AuthValueListenableImpl(_isAuthenticatedNotifier);
    _log.info(
        'DirAuth initialized: enabled=$initiallyEnabled, path=$syncDirectoryPath');
  }

  /// Creates DirAuth with initial state.
  ///
  /// [syncDirectoryPath] is the directory where sync files will be stored.
  /// [initiallyEnabled] determines if sync is enabled on startup (default: false).
  ///
  /// State is persisted to SharedPreferences and restored on subsequent launches.
  static Future<DirAuth> create({
    required String syncDirectoryPath,
    bool initiallyEnabled = false,
  }) async {
    final prefs = await SharedPreferences.getInstance();

    // Load persisted state, fallback to constructor params
    final savedPath = prefs.getString(_kPathKey) ?? syncDirectoryPath;
    final savedEnabled = prefs.getBool(_kEnabledKey) ?? initiallyEnabled;

    return DirAuth._(
      initiallyEnabled: savedEnabled,
      syncDirectoryPath: savedPath,
    );
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
    await prefs.setString(_kPathKey, newPath);
  }

  /// Enable local directory sync.
  Future<void> enable() async {
    _log.info('Enabling local directory sync');
    _isAuthenticatedNotifier.value = true;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabledKey, true);
  }

  /// Disable local directory sync.
  Future<void> disable() async {
    _log.info('Disabling local directory sync');
    _isAuthenticatedNotifier.value = false;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabledKey, false);
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
