/// Registry for managing remote backend UI adapters.
library;

import 'remote_ui_adapter.dart';

/// Central registry for remote backend UI adapters.
///
/// Manages a collection of [RemoteUiAdapter] instances and provides:
/// - Single source of truth for configured remote backends
/// - Query methods for active/authenticated remotes
/// - UI integration point for multi-backend status widgets
///
/// ## Usage Pattern
///
/// The registry is **created automatically** by [Locorda.create] when
/// you provide remote integrations:
///
/// ```dart
/// // 1. Initialize auth for remote backends
/// final solidAuth = SolidAuth(...);
/// await solidAuth.init();
/// final gdriveAuth = await GDriveAuth.create();
///
/// // 2. Create Locorda with remote handlers
/// final locorda = await Locorda.create(
///   remotes: [
///     SolidMainIntegration(solidAuth: solidAuth),
///     GDriveMainIntegration(gdriveAuth: gdriveAuth),
///   ],
///   storage: DriftMainHandler(),
///   config: locordaConfig,
///   mapperInitializer: myMapperInitializer,
///   workerSetup: setupWorkerEngine,
/// );
///
/// // 3. Access registry via Locorda instance
/// final registry = locorda.uiAdapterRegistry;
///
/// // 4. Use in UI for multi-backend auth status
/// AppBar(
///   actions: [
///     // Build custom UI using registry.remoteAdapters
///     for (final adapter in registry.remoteAdapters)
///       // ... auth button for adapter ...
///   ],
/// )
/// ```
///
/// ## Manual Creation
///
/// You can also create a registry manually for testing or advanced use cases:
///
/// ```dart
/// final registry = UiAdapterRegistry.withRemotes([
///   SolidMainIntegration(solidAuth: solidAuth),
///   GDriveMainIntegration(gdriveAuth: gdriveAuth),
/// ]);
/// ```
class UiAdapterRegistry {
  final List<RemoteUiAdapter> _remoteAdapters;

  /// Creates a registry with the given remote UI adapters.
  ///
  /// Adapters are ordered by priority - the first authenticated adapter
  /// becomes the [activeRemote].
  UiAdapterRegistry.withRemotes(List<RemoteUiAdapter> remoteAdapters)
      : _remoteAdapters = List.unmodifiable(remoteAdapters);

  /// All registered remote UI adapters (immutable view).
  List<RemoteUiAdapter> get remoteAdapters => _remoteAdapters;

  /// The currently active (authenticated) remote adapter.
  ///
  /// Returns the first adapter where [Auth.isAuthenticatedNotifier.isAuthenticated]
  /// is `true`, or `null` if none are authenticated.
  ///
  /// Priority determined by adapter order in constructor.
  RemoteUiAdapter? get activeRemote {
    for (final remoteAdapter in _remoteAdapters) {
      if (remoteAdapter.auth.isAuthenticatedNotifier.isAuthenticated) {
        return remoteAdapter;
      }
    }
    return null;
  }

  /// All remote adapters that are currently authenticated.
  ///
  /// Note: UI should ensure only one is active, but backend supports multiple.
  List<RemoteUiAdapter> get authenticatedRemotes {
    return _remoteAdapters
        .where((p) => p.auth.isAuthenticatedNotifier.isAuthenticated)
        .toList();
  }

  /// Finds remote adapter by unique identifier.
  ///
  /// Returns `null` if no adapter with [id] is registered.
  RemoteUiAdapter? findByRemoteId(String id) {
    for (final remoteAdapter in _remoteAdapters) {
      if (remoteAdapter.id == id) {
        return remoteAdapter;
      }
    }
    return null;
  }
}
