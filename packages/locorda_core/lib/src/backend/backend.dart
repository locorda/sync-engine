import 'package:locorda_core/src/storage/remote_storage.dart';

/// Backend interface for remote synchronization.
///
/// Provides access to remote storage operations.
abstract interface class Backend {
  String get name;

  /// Remote storage operations (GET/PUT/DELETE)
  List<RemoteStorage> get remotes;

  Future<void> dispose();
}
