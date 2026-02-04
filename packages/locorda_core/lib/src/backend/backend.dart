import 'package:locorda_core/src/storage/remote_storage.dart';

/// Backend interface for remote synchronization.
///
/// Provides access to remote storage operations and change notifications.
abstract interface class Backend {
  String get name;

  /// Remote storage operations (GET/PUT/DELETE)
  List<RemoteStorage> get remotes;

  /// Stream that emits when remote list changes.
  ///
  /// Fires when:
  /// - A remote is added/removed from the list (e.g., user logs in/out)
  /// - Backend configuration changes affecting remotes
  ///
  /// Note that it does not fire when remote's availability status changes.
  ///
  /// Consumers (e.g., StandardSyncEngine) listen to this to dynamically
  /// adjust ItemFetchPolicy when useShardDatasets remotes become available.
  ///
  /// Uses BehaviorSubject to provide current state on subscription and
  /// enable synchronous access to last emitted value.
  Stream<List<RemoteStorage>> get remotesChanged;

  Future<void> dispose();
}
