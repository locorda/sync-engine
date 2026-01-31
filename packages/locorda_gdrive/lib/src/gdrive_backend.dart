import 'dart:convert';

import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;
import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:logging/logging.dart';

import 'auth/gdrive_auth_provider.dart';
import 'gdrive_type_index_manager.dart';

final _log = Logger('GDriveBackend');
final _clientLog = Logger('GDriveClient');

/// Google Drive API client for RDF document storage.
///
/// Provides low-level Google Drive operations with OAuth2 authentication,
/// ETag-based concurrency control, and automatic token refresh on 401 errors.
class GDriveClient {
  final RdfCore _rdfCore;
  final drive.DriveApi _driveApi;

  GDriveClient._({
    required RdfCore rdfCore,
    required drive.DriveApi driveApi,
  })  : _rdfCore = rdfCore,
        _driveApi = driveApi;

  factory GDriveClient(
      {required GDriveAuthProvider authProvider, RdfCore? rdfCore}) {
    final client = _GoogleAuthClient(authProvider);
    final driveApi = drive.DriveApi(client);
    return GDriveClient._(
      rdfCore: rdfCore ??
          RdfCore.withStandardCodecs(iriTermFactory: IriTerm.validated),
      driveApi: driveApi,
    );
  }

  /// Get or create a folder in Google Drive.
  ///
  /// Searches for existing folder by name in parent (or root), creates if not found.
  /// Returns the folder ID (suitable for use as parentId in other operations).
  ///
  /// Parameters:
  /// - [folderName]: Name of folder to find or create
  /// - [parentId]: Parent folder ID, or null for root ('root' is Drive's root folder ID)
  /// - [spaces]: Search space ('drive' for My Drive, 'appDataFolder' for app-specific folder)
  ///
  /// Throws [GDriveClientException] if user not authenticated or API error occurs.
  Future<String> getOrCreateFolder({
    required String folderName,
    String? parentId,
    String spaces = 'drive',
  }) async {
    final parent = parentId ?? 'root';

    try {
      _clientLog.fine(
          'Searching for folder "$folderName" in parent=$parent (spaces=$spaces)');

      // Search for existing folder
      // Query: name matches AND mimeType is folder AND parent is specified
      final escapedName = GDriveClient._escapeQueryValue(folderName);
      final query =
          "name='$escapedName' and mimeType='application/vnd.google-apps.folder' and '$parent' in parents and trashed=false";

      final fileList = await _driveApi.files.list(
        q: query,
        spaces: spaces,
        $fields: 'files(id, name)',
      );

      if (fileList.files != null && fileList.files!.isNotEmpty) {
        final folderId = fileList.files!.first.id!;
        _clientLog.fine('Found existing folder: $folderId');
        return folderId;
      }

      _clientLog.fine('Folder not found, creating new folder');

      // Create new folder
      final folderMetadata = drive.File()
        ..name = folderName
        ..mimeType = 'application/vnd.google-apps.folder';

      // Only set parents if not root (omitting parents creates in root)
      if (parentId != null) {
        folderMetadata.parents = [parent];
      }

      final createdFolder = await _driveApi.files.create(
        folderMetadata,
        $fields: 'id',
      );

      final folderId = createdFolder.id!;
      _clientLog.info('Created folder "$folderName" with ID: $folderId');
      return folderId;
    } catch (e, stackTrace) {
      handleGDriveAuthError(e);
      _clientLog.severe(
          'Failed to get or create folder "$folderName"', e, stackTrace);
      throw GDriveClientException(
          'Failed to get or create folder "$folderName": $e');
    }
  }

  void handleGDriveAuthError(Object e) {
    if (e is drive.DetailedApiRequestError && e.status == 401) {
      _clientLog.warning(
          'Authentication failed (401) - OAuth authorization may have been revoked');
      throw AuthException(
        'Google Drive authentication failed. Please sign in again.',
        cause: e,
      );
    }
  }

  Future<({String fileId, String etag})> createFile(
      String filename, RdfGraph graph,
      {required String folderId,
      bool fileNameMayBeRelativePath = false,
      String spaces = 'drive'}) async {
    try {
      // 1. Handle relative paths (create folder hierarchy if needed)
      String parentId = folderId;
      String actualFileName = filename;
      if (fileNameMayBeRelativePath && filename.contains('/')) {
        final parts = filename.split('/');
        actualFileName = parts.last;
        // Navigate/create folder hierarchy
        for (final folderName in parts.sublist(0, parts.length - 1)) {
          parentId = await getOrCreateFolder(
              folderName: folderName, parentId: parentId, spaces: spaces);
        }
      }

      _clientLog.fine('Creating file "$actualFileName" in folder=$parentId');

      // 2. Serialize RDF graph to Turtle format
      final content = _rdfCore.encode(graph);
      final bytes = utf8.encode(content);

      // 3. Create file metadata
      final fileMetadata = drive.File()
        ..name = actualFileName
        ..parents = [parentId]
        ..mimeType = 'text/turtle';

      // 4. Upload with media
      final media = drive.Media(Stream.value(bytes), bytes.length);

      final createdFile = await _driveApi.files.create(
        fileMetadata,
        uploadMedia: media,
        $fields: 'id, md5Checksum',
      );

      final fileId = createdFile.id!;
      final etag = createdFile.md5Checksum!;
      _clientLog.info('Created file: $fileId with ETag: $etag');

      return (fileId: fileId, etag: etag);
    } catch (e, stackTrace) {
      handleGDriveAuthError(e);
      _clientLog.severe('Failed to create file "$filename"', e, stackTrace);
      throw GDriveClientException('Failed to create file "$filename": $e');
    }
  }

  /// Find a file in Google Drive by name and parent folder.
  ///
  /// Returns the file ID if found, null otherwise.
  ///
  /// **Path Handling:**
  /// - If [fileNameMayBeRelativePath] is false: Searches for exact filename in [parentId]
  ///   - `fileName = "data.ttl"` → searches in parentId
  ///   - `fileName = "my/file.ttl"` → searches for file literally named "my/file.ttl"
  ///
  /// - If [fileNameMayBeRelativePath] is true: Interprets slashes as folder hierarchy
  ///   - `fileName = "data.ttl"` → searches in parentId
  ///   - `fileName = "subfolder/data.ttl"` → searches in parentId/subfolder/
  ///   - Creates missing folders automatically
  ///
  /// Parameters:
  /// - [fileName]: File name (with optional path if [fileNameMayBeRelativePath] is true)
  /// - [parentId]: Parent folder ID to search in
  /// - [fileNameMayBeRelativePath]: Whether to interpret slashes as folder separators
  /// - [spaces]: Search space ('drive' for My Drive, 'appDataFolder' for app-specific folder)
  ///
  /// Returns file ID if found, null if not found.
  Future<String?> findFile({
    required String fileName,
    required String parentId,
    bool fileNameMayBeRelativePath = false,
    String spaces = 'drive',
  }) async {
    try {
      // Handle relative paths by traversing folder hierarchy
      if (fileNameMayBeRelativePath && fileName.contains('/')) {
        final parts = fileName.split('/');
        final folderPath = parts.sublist(0, parts.length - 1);
        final actualFileName = parts.last;

        // Navigate/create folder hierarchy
        String currentParentId = parentId;
        for (final folderName in folderPath) {
          currentParentId = await getOrCreateFolder(
              folderName: folderName,
              parentId: currentParentId,
              spaces: spaces);
        }

        // Search for file in final folder
        return await _findFileInFolder(
            fileName: actualFileName,
            parentId: currentParentId,
            spaces: spaces);
      }

      // Direct search in parent folder
      return await _findFileInFolder(
          fileName: fileName, parentId: parentId, spaces: spaces);
    } catch (e, stackTrace) {
      _clientLog.severe('Failed to find file "$fileName"', e, stackTrace);
      throw GDriveClientException('Failed to find file "$fileName": $e');
    }
  }

  /// Internal helper: Search for file by exact name in specific folder.
  Future<String?> _findFileInFolder({
    required String fileName,
    required String parentId,
    String spaces = 'drive',
  }) async {
    _clientLog.fine(
        'Searching for file "$fileName" in folder=$parentId (spaces=$spaces)');

    try {
      final escapedName = _escapeQueryValue(fileName);
      final query =
          "name='$escapedName' and '$parentId' in parents and trashed=false";

      final fileList = await _driveApi.files.list(
        q: query,
        spaces: spaces,
        $fields: 'files(id, name)',
      );

      if (fileList.files != null && fileList.files!.isNotEmpty) {
        final fileId = fileList.files!.first.id!;
        _clientLog.fine('Found file: $fileId');
        return fileId;
      }

      _clientLog.fine('File not found');
      return null;
    } on drive.DetailedApiRequestError catch (e) {
      handleGDriveAuthError(e);
      rethrow;
    }
  }

  Future<({RdfGraph? graph, String? etag, bool notModified})> download(
      String fileId,
      {String? ifNoneMatch}) async {
    _clientLog.fine('Downloading file $fileId');

    try {
      // 1. Get file metadata (for ETag check)
      final metadata = await _driveApi.files.get(
        fileId,
        $fields: 'md5Checksum',
      ) as drive.File;

      final currentEtag = metadata.md5Checksum;

      // 2. Check if modified (ETag comparison)
      if (ifNoneMatch != null && currentEtag == ifNoneMatch) {
        _clientLog.fine('File not modified (ETag match): $fileId');
        return (graph: null, etag: ifNoneMatch, notModified: true);
      }

      // 3. Download file content
      final media = await _driveApi.files.get(
        fileId,
        downloadOptions: drive.DownloadOptions.fullMedia,
      ) as drive.Media;

      // 4. Read stream and decode RDF
      final completer = <int>[];
      await for (final chunk in media.stream) {
        completer.addAll(chunk);
      }
      final content = utf8.decode(completer);
      final graph = _rdfCore.decode(content, contentType: 'text/turtle');

      _clientLog.fine('Downloaded file: $fileId (ETag: $currentEtag)');
      return (graph: graph, etag: currentEtag, notModified: false);
    } on drive.DetailedApiRequestError catch (e, stackTrace) {
      // Handle API-specific errors
      handleGDriveAuthError(e);

      if (e.status == 404) {
        // File not found - return null (same as Solid backend)
        _clientLog.fine('File not found: $fileId');
        return (graph: null, etag: null, notModified: false);
      }

      _clientLog.severe('API error downloading file $fileId', e, stackTrace);
      throw GDriveClientException(
          'Failed to download file $fileId: ${e.status} ${e.message}');
    } catch (e, stackTrace) {
      _clientLog.severe('Failed to download file $fileId', e, stackTrace);
      throw GDriveClientException('Failed to download file $fileId: $e');
    }
  }

  Future<RemoteUploadResult> upload(String fileId, RdfGraph updatedGraph,
      {required String ifMatch}) async {
    _clientLog.fine('Uploading file $fileId');

    try {
      // 1. Fetch current ETag for conflict detection
      final metadata = await _driveApi.files.get(
        fileId,
        $fields: 'md5Checksum',
      ) as drive.File;

      final currentEtag = metadata.md5Checksum;

      // 2. Check for conflict
      if (currentEtag != ifMatch) {
        _clientLog.warning(
            'ETag mismatch for file $fileId: expected=$ifMatch, actual=$currentEtag');
        return RemoteUploadResult.conflict();
      }

      // 3. Serialize RDF graph to Turtle format
      final content = _rdfCore.encode(updatedGraph);
      final bytes = utf8.encode(content);

      // 4. Upload updated content
      final media = drive.Media(Stream.value(bytes), bytes.length);
      final updated = await _driveApi.files.update(
        drive.File(), // Empty metadata (no property changes)
        fileId,
        uploadMedia: media,
        $fields: 'md5Checksum',
      );

      final newEtag = updated.md5Checksum!;
      _clientLog.info('Updated file: $fileId (new ETag: $newEtag)');
      return RemoteUploadResult.success(newEtag);
    } on drive.DetailedApiRequestError catch (e, stackTrace) {
      // Handle API-specific errors
      handleGDriveAuthError(e);

      if (e.status == 404) {
        // File not found - throw exception (same as Solid backend)
        _clientLog.warning('File not found during upload: $fileId');
        throw GDriveClientException('File not found: $fileId');
      }

      _clientLog.severe('API error uploading file $fileId', e, stackTrace);
      throw GDriveClientException(
          'Failed to upload file $fileId: ${e.status} ${e.message}');
    } catch (e, stackTrace) {
      _clientLog.severe('Failed to upload file $fileId', e, stackTrace);
      throw GDriveClientException('Failed to upload file $fileId: $e');
    }
  }

  /// Escape special characters in Drive API query values.
  ///
  /// Google Drive API requires escaping:
  /// - Single quote (') → \'
  /// - Backslash (\) → \\
  ///
  /// See: https://developers.google.com/drive/api/guides/search-files
  static String _escapeQueryValue(String value) {
    return value
        .replaceAll('\\', '\\\\') // Backslash must be escaped first!
        .replaceAll("'", "\\'"); // Then escape single quotes
  }
}

/// HTTP client for googleapis library that adds Bearer token authentication.
///
/// The googleapis package requires an authenticated http.Client.
/// This implementation adds the OAuth2 access token to all requests.
/// Token refresh logic is handled at the method level (download/upload).
class _GoogleAuthClient extends http.BaseClient {
  final GDriveAuthProvider _authProvider;
  final http.Client _inner = http.Client();

  _GoogleAuthClient(this._authProvider);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final accessToken = await _authProvider.getAccessToken();
    request.headers['Authorization'] = 'Bearer $accessToken';
    return _inner.send(request);
  }

  @override
  void close() {
    _inner.close();
  }
}

class GDriveClientException implements Exception {
  final String message;
  GDriveClientException(this.message);

  @override
  String toString() => 'GDriveClientException: $message';
}

class GDriveSyncStorage extends RemoteSyncStorage {
  final GDriveClient _client;

  final TypeIndexMappings _typeIndexMappings;
  final ResourceLocator _resourceLocator;
  final String _spaces;

  GDriveSyncStorage({
    required GDriveClient client,
    required TypeIndexMappings typeIndexMappings,
    required ResourceLocator resourceLocator,
    required String spaces,
  })  : _client = client,
        _typeIndexMappings = typeIndexMappings,
        _resourceLocator = resourceLocator,
        _spaces = spaces;

  @override
  Future<RemoteDownloadResult> download(IriTerm documentIri,
      {String? ifNoneMatch}) async {
    final docIri = _resourceLocator.fromIri(documentIri);
    final folderId = _typeIndexMappings.getFolderId(docIri.typeIri);
    final filePath = docIri.id;
    final fileId = await _client.findFile(
        parentId: folderId,
        fileName: filePath,
        fileNameMayBeRelativePath: true,
        spaces: _spaces);
    if (fileId == null) {
      return RemoteDownloadResult(
        graph: null,
        etag: null,
        notModified: false,
      );
    }
    final result = await _client.download(fileId, ifNoneMatch: ifNoneMatch);
    if (result.notModified) {
      return RemoteDownloadResult.notModified(etag: result.etag);
    }
    if (result.graph == null) {
      return RemoteDownloadResult(
        graph: null,
        etag: result.etag,
        notModified: false,
      );
    }
    return RemoteDownloadResult(
      graph: result.graph!,
      etag: result.etag,
      notModified: false,
    );
  }

  @override
  Future<RemoteUploadResult> upload(IriTerm documentIri, RdfGraph graph,
      {String? ifMatch}) async {
    final docIri = _resourceLocator.fromIri(documentIri);
    final folderId = _typeIndexMappings.getFolderId(docIri.typeIri);
    final filePath = docIri.id;
    final fileId = await _client.findFile(
        parentId: folderId,
        fileName: filePath,
        fileNameMayBeRelativePath: true,
        spaces: _spaces);

    if (fileId == null) {
      // Create new file
      final created = await _client.createFile(filePath, graph,
          folderId: folderId, fileNameMayBeRelativePath: true, spaces: _spaces);
      return SuccessUploadResult(created.etag);
    } else {
      // Update existing file
      return await _client.upload(fileId, graph, ifMatch: ifMatch!);
    }
  }

  @override
  Future<void> finalizeSync() async {
    // No-op for GDrive sync storage
  }
}

class GDriveRemoteStorage implements RemoteStorage {
  final RemoteId _remoteId;
  final String _userId;
  final GDriveClient _client;
  final GDriveTypeIndexManager _typeIndexManager;
  final ResourceLocator _resourceLocator;
  final String _spaces;

  GDriveRemoteStorage({
    required GDriveClient client,
    required String userId,
    required GDriveTypeIndexManager typeIndexManager,
    required ResourceLocator resourceLocator,
    required String spaces,
  })  : _client = client,
        _userId = userId,
        _typeIndexManager = typeIndexManager,
        _resourceLocator = resourceLocator,
        _spaces = spaces,
        _remoteId = RemoteId("google", userId);

  RemoteId get remoteId => _remoteId;

  @override
  Future<RemoteSyncStorage> createSyncStorage(
      SyncEngineConfig engineConfig) async {
    final typeIndexMappings =
        await _typeIndexManager.loadOrCreateTypeIndex(engineConfig);
    return GDriveSyncStorage(
      client: _client,
      resourceLocator: _resourceLocator,
      typeIndexMappings: typeIndexMappings,
      spaces: _spaces,
    );
  }

  @override
  Future<bool> isAvailable() {
    // TODO: implement availability check, maybe by using some API to
    // check for online/offline status or similar.
    return Future.value(true);
  }
}

class GDriveBackend implements Backend {
  @override
  String get name => 'gdrive';
  final GDriveAuthProvider _auth;
  final GDriveClient _client;
  final GDriveTypeIndexManager _typeIndexManager;
  final ResourceLocator _resourceLocator;
  final GDriveConfig _config;

  List<RemoteStorage> _remotes = [];

  factory GDriveBackend({
    required GDriveAuthProvider auth,
    required GDriveConfig config,
    IriTermFactory? iriTermFactory,
    RdfCore? rdfCore,
  }) {
    final client = GDriveClient(
      authProvider: auth,
      rdfCore: rdfCore ??
          RdfCore.withStandardCodecs(
              iriTermFactory: iriTermFactory ?? IriTerm.validated),
    );
    return GDriveBackend._(
        auth: auth,
        config: config,
        client: client,
        iriTermFactory: iriTermFactory);
  }

  GDriveBackend._({
    required GDriveAuthProvider auth,
    required GDriveClient client,
    required GDriveConfig config,
    IriTermFactory? iriTermFactory,
  })  : _auth = auth,
        _client = client,
        _config = config,
        _typeIndexManager = GDriveTypeIndexManager(
          client: client,
          iriTermFactory: iriTermFactory ?? IriTerm.validated,
          config: config,
        ),
        _resourceLocator = LocalResourceLocator(
          iriTermFactory: iriTermFactory ?? IriTerm.validated,
        ) {
    _auth.isAuthenticatedNotifier.addListener(_authStateChanged);
    _authStateChanged();
  }

  void _authStateChanged() {
    _log.info('Authentication state changed: '
        'isAuthenticated=${_auth.isAuthenticatedNotifier.isAuthenticated}, userId=${_auth.userId}');
    if (_auth.isAuthenticatedNotifier.isAuthenticated) {
      final userId = _auth.userId;
      if (userId == null) {
        throw StateError(
            'User is authenticated but userId is null in GDriveBackend');
      }
      if (_remotes.length == 1 &&
          _remotes.first is GDriveRemoteStorage &&
          (_remotes.first as GDriveRemoteStorage)._userId == userId) {
        // No change in authentication state
        _log.fine('No change in GDrive remote storage for userId=$userId');
        return;
      }
      _log.info(
          'User logged in: initializing GDrive remote storage for userId=$userId');
      // User logged in: initialize remote storage
      final spaces = _config.folderMode == GDriveFolderMode.appDataFolder
          ? 'appDataFolder'
          : 'drive';

      final baseRemote = GDriveRemoteStorage(
        userId: userId,
        client: _client,
        typeIndexManager: _typeIndexManager,
        resourceLocator: _resourceLocator,
        spaces: spaces,
      );

      // Wrap with auth-aware retry logic
      _remotes = [
        AuthAwareRemoteStorage(
          inner: baseRemote,
          onAuthFailure: () async {
            _log.info('Auth failure detected, requesting token refresh');
            await _auth.refreshToken(
                reason: 'Authentication failed during sync operation');
          },
          config: const AuthRetryConfig.retryOnce(),
        )
      ];
    } else {
      _log.info('User logged out: clearing GDrive remote storage');
      // User logged out: clear remote storage
      _remotes = [];
    }
  }

  @override
  List<RemoteStorage> get remotes => _remotes;

  @override
  Future<void> dispose() async {
    _auth.isAuthenticatedNotifier.removeListener(_authStateChanged);
  }
}
