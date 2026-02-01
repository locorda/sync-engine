import 'package:locorda_rdf_core/core.dart';

/// Google Drive folder storage mode.
enum GDriveFolderMode {
  /// Private app-specific folder (invisible to user in Drive UI).
  /// Better performance due to smaller search space.
  /// Requires 'drive.appdata' OAuth scope.
  appDataFolder,

  /// Visible folder in user's My Drive.
  /// User can see and manage files directly.
  /// Requires 'drive.file' or 'drive' OAuth scope.
  visibleFolder,
}

/// Configuration for the local mirror cache used by the GDrive backend.
///
/// This cache is an experimental performance optimization that mirrors the
/// remote Drive folder into a local sandboxed directory to minimize round-trips
/// during sync.
class GDriveLocalMirrorConfig {
  /// Enable the local mirror cache.
  final bool enabled;

  /// Root path for the cache directory.
  ///
  /// When null, a sandboxed directory under the system temp folder is used.
  final String? cacheRootPath;

  /// Maximum parallel folder listing requests.
  final int maxConcurrentListings;

  /// Maximum parallel file downloads for mirror initialization.
  final int maxConcurrentDownloads;

  /// Maximum parallel uploads during finalizeSync.
  final int maxConcurrentUploads;

  const GDriveLocalMirrorConfig({
    this.enabled = false,
    this.cacheRootPath,
    this.maxConcurrentListings = 4,
    this.maxConcurrentDownloads = 12,
    this.maxConcurrentUploads = 12,
  });

  GDriveLocalMirrorConfig copyWith({
    bool? enabled,
    String? cacheRootPath,
    int? maxConcurrentListings,
    int? maxConcurrentDownloads,
    int? maxConcurrentUploads,
  }) {
    return GDriveLocalMirrorConfig(
      enabled: enabled ?? this.enabled,
      cacheRootPath: cacheRootPath ?? this.cacheRootPath,
      maxConcurrentListings:
          maxConcurrentListings ?? this.maxConcurrentListings,
      maxConcurrentDownloads:
          maxConcurrentDownloads ?? this.maxConcurrentDownloads,
      maxConcurrentUploads: maxConcurrentUploads ?? this.maxConcurrentUploads,
    );
  }
}

/// Configuration for Google Drive folder mappings.
///
/// Allows explicit control over which folder names are used for specific
/// resource types. Configured mappings take precedence over auto-generated names.
class GDriveConfig {
  /// Explicit mapping: resource type IRI → folder name
  final Map<IriTerm, String> typeFolderNames;

  /// App folder name (only used when folderMode == visibleFolder)
  final String? appFolderName;

  /// Storage mode: appDataFolder (private, default) or visibleFolder
  final GDriveFolderMode folderMode;

  /// Additional OAuth scopes beyond the default drive scope.
  /// Use this to request access to other Google APIs (e.g., Calendar, Contacts).
  final List<String> extraScopes;

  /// Local mirror configuration for experimental high-throughput sync.
  final GDriveLocalMirrorConfig localMirrorConfig;

  /// Default constructor: uses appDataFolder mode (private, no visible folder name needed)
  const GDriveConfig({
    this.typeFolderNames = const {},
    this.extraScopes = const [],
    this.localMirrorConfig = const GDriveLocalMirrorConfig(),
  })  : appFolderName = null,
        folderMode = GDriveFolderMode.appDataFolder;

  /// Named constructor: uses visibleFolder mode with required folder name
  const GDriveConfig.visibleFolder({
    this.typeFolderNames = const {},
    this.extraScopes = const [],
    this.localMirrorConfig = const GDriveLocalMirrorConfig(),
    required this.appFolderName,
  }) : folderMode = GDriveFolderMode.visibleFolder;

  /// Returns the OAuth scopes required for this configuration.
  ///
  /// Automatically determines the correct Google Drive scope based on [folderMode]:
  /// - `appDataFolder`: Requires `drive.appdata` (private app storage)
  /// - `visibleFolder`: Requires `drive.file` (user-visible files)
  ///
  /// Always includes `openid` for stable user identification via Google's subject identifier.
  /// Appends any [extraScopes] specified by the application.
  List<String> get requiredScopes => [
        folderMode == GDriveFolderMode.appDataFolder
            ? 'https://www.googleapis.com/auth/drive.appdata'
            : 'https://www.googleapis.com/auth/drive.file',
        'openid',
        ...extraScopes,
      ];

  GDriveConfig copyWith({
    Map<IriTerm, String>? typeFolderNames,
    String? appFolderName,
    GDriveFolderMode? folderMode,
    List<String>? extraScopes,
    GDriveLocalMirrorConfig? localMirrorConfig,
  }) {
    // Validate: appFolderName must be set for visibleFolder mode
    final newMode = folderMode ?? this.folderMode;
    final newName = appFolderName ?? this.appFolderName;

    if (newMode == GDriveFolderMode.visibleFolder && newName == null) {
      throw ArgumentError(
        'appFolderName is required when folderMode is visibleFolder',
      );
    }

    return newMode == GDriveFolderMode.appDataFolder
        ? GDriveConfig(
            typeFolderNames: typeFolderNames ?? this.typeFolderNames,
            extraScopes: extraScopes ?? this.extraScopes,
            localMirrorConfig: localMirrorConfig ?? this.localMirrorConfig,
          )
        : GDriveConfig.visibleFolder(
            typeFolderNames: typeFolderNames ?? this.typeFolderNames,
            extraScopes: extraScopes ?? this.extraScopes,
            localMirrorConfig: localMirrorConfig ?? this.localMirrorConfig,
            appFolderName: newName!,
          );
  }
}
