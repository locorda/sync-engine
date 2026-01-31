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

/**
 * Wrapper around Google Drive Files API so we can extend it with etag handling.
 */
class FilesApi {
  final http.Client _client;
  final drive.DriveApi _driveApi;

  FilesApi(this._client) : _driveApi = drive.DriveApi(_client);

  // Ensure etag is always included in fields, to make it more likely
  // to be computed and returned as http header too.
  String? _fixFields(String? fields) {
    return '*';
    if (fields == null) return 'etag';
    // Vermeiden Sie Teil-Matches (z.B. "metadatag" würde etag enthalten)
    final regExp = RegExp(r'\betag\b');
    if (regExp.hasMatch(fields)) return fields;
    return 'etag,$fields';
  }

  /// Don't forget to check for not modified - will be trhown as DetailedApiRequestError with status 304
  Future<({T response, String? etag})> get<T>(
    String fileId, {
    String? ifNoneMatch,
    bool? acknowledgeAbuse,
    String? includeLabels,
    String? includePermissionsForView,
    bool? supportsAllDrives,
    bool? supportsTeamDrives,
    String? $fields,
    drive.DownloadOptions downloadOptions = drive.DownloadOptions.metadata,
  }) async {
    final ETagClient etagClient = ETagClient(_client, ifNoneMatch: ifNoneMatch);

    final res = await drive.DriveApi(etagClient).files.get(
          fileId,
          acknowledgeAbuse: acknowledgeAbuse,
          includeLabels: includeLabels,
          includePermissionsForView: includePermissionsForView,
          supportsAllDrives: supportsAllDrives,
          supportsTeamDrives: supportsTeamDrives,
          $fields: _fixFields($fields),
          downloadOptions: downloadOptions,
        );
    if (downloadOptions == drive.DownloadOptions.metadata &&
        etagClient.etag == null) {
      throw GDriveClientException(
          'ETag not found in response for file $fileId');
    }
    return (response: res as T, etag: etagClient.etag);
  }

  /// don't forget to check for conflicts when using ifMatch! - status code 412 (and to be sure maybe also 409)
  Future<({drive.File response, String? etag})> update(
    drive.File request,
    String fileId, {
    String? ifMatch,
    String? addParents,
    bool? enforceSingleParent,
    String? includeLabels,
    String? includePermissionsForView,
    bool? keepRevisionForever,
    String? ocrLanguage,
    String? removeParents,
    bool? supportsAllDrives,
    bool? supportsTeamDrives,
    bool? useContentAsIndexableText,
    String? $fields,
    drive.UploadOptions uploadOptions = drive.UploadOptions.defaultOptions,
    drive.Media? uploadMedia,
  }) async {
    final ETagClient etagClient = ETagClient(_client, ifMatch: ifMatch);
    final res = await drive.DriveApi(etagClient).files.update(
          request,
          fileId,
          addParents: addParents,
          enforceSingleParent: enforceSingleParent,
          includeLabels: includeLabels,
          includePermissionsForView: includePermissionsForView,
          keepRevisionForever: keepRevisionForever,
          ocrLanguage: ocrLanguage,
          removeParents: removeParents,
          supportsAllDrives: supportsAllDrives,
          supportsTeamDrives: supportsTeamDrives,
          useContentAsIndexableText: useContentAsIndexableText,
          $fields: _fixFields($fields),
          uploadOptions: uploadOptions,
          uploadMedia: uploadMedia,
        );
    if (etagClient.etag == null) {
      throw GDriveClientException(
          'ETag not found in response for updated file $fileId');
    }
    return (response: res, etag: etagClient.etag);
  }

  Future<({drive.File response, String? etag})> create(
    drive.File request, {
    bool? enforceSingleParent,
    bool? ignoreDefaultVisibility,
    String? includeLabels,
    String? includePermissionsForView,
    bool? keepRevisionForever,
    String? ocrLanguage,
    bool? supportsAllDrives,
    bool? supportsTeamDrives,
    bool? useContentAsIndexableText,
    String? $fields,
    drive.UploadOptions uploadOptions = drive.UploadOptions.defaultOptions,
    drive.Media? uploadMedia,
  }) async {
    final ETagClient etagClient = ETagClient(_client);
    final res = await drive.DriveApi(etagClient).files.create(
          request,
          enforceSingleParent: enforceSingleParent,
          ignoreDefaultVisibility: ignoreDefaultVisibility,
          includeLabels: includeLabels,
          includePermissionsForView: includePermissionsForView,
          keepRevisionForever: keepRevisionForever,
          ocrLanguage: ocrLanguage,
          supportsAllDrives: supportsAllDrives,
          supportsTeamDrives: supportsTeamDrives,
          useContentAsIndexableText: useContentAsIndexableText,
          $fields: _fixFields($fields),
          uploadOptions: uploadOptions,
          uploadMedia: uploadMedia,
        );
    if (etagClient.etag == null) {
      throw GDriveClientException(
          'ETag not found in response for created file');
    }
    return (response: res, etag: etagClient.etag);
  }

  Future<drive.FileList> list({
    String? corpora,
    String? corpus,
    String? driveId,
    bool? includeItemsFromAllDrives,
    String? includeLabels,
    String? includePermissionsForView,
    bool? includeTeamDriveItems,
    String? orderBy,
    int? pageSize,
    String? pageToken,
    String? q,
    String? spaces,
    bool? supportsAllDrives,
    bool? supportsTeamDrives,
    String? teamDriveId,
    String? $fields,
  }) =>
      _driveApi.files.list(
        corpora: corpora,
        corpus: corpus,
        driveId: driveId,
        includeItemsFromAllDrives: includeItemsFromAllDrives,
        includeLabels: includeLabels,
        includePermissionsForView: includePermissionsForView,
        includeTeamDriveItems: includeTeamDriveItems,
        orderBy: orderBy,
        pageSize: pageSize,
        pageToken: pageToken,
        q: q,
        spaces: spaces,
        supportsAllDrives: supportsAllDrives,
        supportsTeamDrives: supportsTeamDrives,
        teamDriveId: teamDriveId,
        $fields: $fields,
      );
}

class ETagClient extends http.BaseClient {
  final http.Client _inner;
  final String? _ifMatch;
  final String? _ifNoneMatch;
  String? _etag;

  String? get etag => _etag;

  ETagClient(this._inner, {String? ifMatch, String? ifNoneMatch})
      : _ifMatch = ifMatch,
        _ifNoneMatch = ifNoneMatch;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final _extraHeaders = <String, String>{
      if (_ifMatch != null) 'If-Match': _ifMatch,
      if (_ifNoneMatch != null) 'If-None-Match': _ifNoneMatch,
    };
    if (_extraHeaders.isNotEmpty) {
      request.headers.addAll(_extraHeaders);
    }
    final response = await _inner.send(request);
    if (response.headers.containsKey('etag')) {
      _etag = response.headers['etag'];
    }
    if (_etag == null &&
        response.headers['content-type']?.contains('application/json') ==
            true) {
      // ACHTUNG: Das Buffern des Streams ist bei großen Downloads gefährlich.
      // Aber bei METADATEN (JSON) ist es völlig okay.
      final bytes = await response.stream.toBytes();
      final jsonMap = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      _etag = jsonMap['etag'] as String?;

      // Da wir den Stream konsumiert haben, müssen wir einen neuen für die Library bauen
      return http.StreamedResponse(
        Stream.value(bytes),
        response.statusCode,
        headers: response.headers,
        request: response.request,
        isRedirect: response.isRedirect,
        reasonPhrase: response.reasonPhrase,
      );
    }
    _log.fine('ETagClient: Received ETag: $_etag');
    _log.fine('Headers: ${response.headers}');
    return response;
  }
}

/// Google Drive API client for RDF document storage.
///
/// Provides low-level Google Drive operations with OAuth2 authentication,
/// ETag-based concurrency control, and automatic token refresh on 401 errors.
class GDriveClient {
  final RdfCore _rdfCore;
  final FilesApi _driveApi;

  GDriveClient._({
    required RdfCore rdfCore,
    required FilesApi driveApi,
  })  : _rdfCore = rdfCore,
        _driveApi = driveApi;

  factory GDriveClient(
      {required GDriveAuthProvider authProvider, RdfCore? rdfCore}) {
    final client = _AutoRefreshingAuthClient(authProvider);
    final driveApi = FilesApi(client);
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

      final fileList = await _driveApi.list(
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

      final (response: createdFolder, etag: _) = await _driveApi.create(
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

      final (response: createdFile, etag: etag) = await _driveApi.create(
        fileMetadata,
        uploadMedia: media,
        $fields: 'id, etag',
      );

      final fileId = createdFile.id!;
      if (etag == null) {
        throw GDriveClientException(
            'Failed to retrieve ETag for created file "$filename"');
      }
      _clientLog.info('Created file: $fileId with ETag: $etag');

      return (fileId: fileId, etag: etag);
    } on GDriveClientException {
      rethrow;
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

      final fileList = await _driveApi.list(
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
      // 1. Do the etag check on metadata only - google will not return etag on full download
      final (response: _, etag: currentEtag) = await _driveApi.get<drive.Media>(
        fileId,
        ifNoneMatch: ifNoneMatch,
        downloadOptions: drive.DownloadOptions.metadata,
      );
      // 2. Download file content
      final (response: media, etag: _) = await _driveApi.get<drive.Media>(
        fileId,
        ifNoneMatch: ifNoneMatch,
        downloadOptions: drive.DownloadOptions.fullMedia,
      );

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
      if (e.status == 304) {
        // Not modified
        _clientLog.fine('File not modified: $fileId');
        return (graph: null, etag: ifNoneMatch, notModified: true);
      }
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
      // 3. Serialize RDF graph to Turtle format
      final content = _rdfCore.encode(updatedGraph);
      final bytes = utf8.encode(content);

      // 4. Upload updated content
      final media = drive.Media(Stream.value(bytes), bytes.length);
      final (response: updated, etag: etag) = await _driveApi.update(
        drive.File(), // Empty metadata (no property changes)
        ifMatch: ifMatch,
        fileId,
        uploadMedia: media,
        $fields: 'md5Checksum',
      );

      if (etag == null) {
        throw GDriveClientException(
            'Failed to retrieve ETag for updated file $fileId');
      }
      _clientLog.info('Updated file: $fileId (new ETag: $etag)');
      return RemoteUploadResult.success(etag);
    } on GDriveClientException {
      rethrow;
    } on drive.DetailedApiRequestError catch (e, stackTrace) {
      // Handle API-specific errors
      handleGDriveAuthError(e);
      if (e.status == 412 || e.status == 409) {
        // Conflict
        _clientLog.warning('Conflict detected when uploading file $fileId');
        return RemoteUploadResult.conflict();
      }
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
class _AutoRefreshingAuthClient extends http.BaseClient {
  final GDriveAuthProvider _authProvider;
  final http.Client _inner = http.Client();

  _AutoRefreshingAuthClient(this._authProvider);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final accessToken = await _authProvider.getAccessToken();
    request.headers['Authorization'] = 'Bearer $accessToken';
    final resp = await _inner.send(request);
    if (resp.statusCode == 401 || resp.statusCode == 403) {
      // Token may be expired or invalid - trigger refresh
      _log.warning(
          'Received ${resp.statusCode} Unauthorized - refreshing access token');
      await _authProvider.refreshToken(
          reason:
              'Received ${resp.statusCode} Unauthorized from Google Drive API');
    }
    return resp;
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
      _log.info('User logged out: clearing Solid remote storage');
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
