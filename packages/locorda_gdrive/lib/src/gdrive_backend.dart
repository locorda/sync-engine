import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;
import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;
import 'package:rxdart/rxdart.dart';

import 'auth/gdrive_auth_provider.dart';
import 'gdrive_type_index_manager.dart';
import 'shared/gdrive_config.dart';

final _log = Logger('GDriveBackend');
final _clientLog = Logger('GDriveClient');
final _mirrorLog = Logger('GDriveLocalMirror');

/// In-memory mapping from Drive IDs to human-readable paths.
///
/// Used to improve performance logs by showing paths instead of opaque IDs.
class GDrivePathIndex {
  final Map<String, String> _fileIdToPath = {};
  final Map<String, String> _folderIdToPath = {};

  void registerEntry(GDriveListedEntry entry) {
    if (entry.fileId.isEmpty || entry.path.isEmpty) return;
    if (entry.isFolder) {
      _folderIdToPath[entry.fileId] = entry.path;
    } else {
      _fileIdToPath[entry.fileId] = entry.path;
    }
  }

  void registerEntries(Iterable<GDriveListedEntry> entries) {
    for (final entry in entries) {
      registerEntry(entry);
    }
  }

  void registerFolderId(String folderId, String pathValue) {
    if (folderId.isEmpty || pathValue.isEmpty) return;
    _folderIdToPath[folderId] = pathValue;
  }

  void registerFileId(String fileId, String pathValue) {
    if (fileId.isEmpty || pathValue.isEmpty) return;
    _fileIdToPath[fileId] = pathValue;
  }

  String? pathForFileId(String fileId) => _fileIdToPath[fileId];

  String? pathForFolderId(String folderId) => _folderIdToPath[folderId];

  String describeFileId(String fileId) => _fileIdToPath[fileId] ?? fileId;

  String buildChildPath({required String? parentId, required String name}) {
    if (parentId == null || parentId.isEmpty) return name;
    if (parentId == 'root' || parentId == 'appDataFolder') return name;
    final parentPath = _folderIdToPath[parentId];
    if (parentPath == null || parentPath.isEmpty) return name;
    return path.join(parentPath, name);
  }
}

/// Minimal client abstraction to enable testable and swappable GDrive backends.
abstract interface class GDriveApiClient {
  Future<String> getOrCreateFolder({
    required String folderName,
    String? parentId,
    String spaces = 'drive',
  });

  Future<({String fileId, String etag})> createFile<T>(
    String filename,
    T graph, {
    required String folderId,
    bool fileNameMayBeRelativePath = false,
    String spaces = 'drive',
    required String contentType,
    required String Function(T) convert,
  });

  Future<({String fileId, String md5Checksum})> createFileRaw(
    String filename,
    List<int> bytes, {
    required String folderId,
    bool fileNameMayBeRelativePath = false,
    String spaces = 'drive',
    required String contentType,
  });

  Future<String?> findFile({
    required String fileName,
    required String parentId,
    bool fileNameMayBeRelativePath = false,
    String spaces = 'drive',
  });

  Future<({T? graph, String? etag, bool notModified})> download<T>(
    String fileId, {
    String? ifNoneMatch,
    required T Function(String) convert,
  });

  Future<List<int>> downloadRawBytes(String fileId);

  Future<RemoteUploadResult> upload<T>(
    String fileId,
    T updatedGraph, {
    required String ifMatch,
    required String Function(T) convert,
  });

  Future<RemoteUploadResult> uploadRaw(
    String fileId,
    List<int> bytes, {
    required String ifMatch,
  });

  Future<List<GDriveListedEntry>> listFilesRecursively({
    required String rootFolderId,
    required String spaces,
    required int maxConcurrentRequests,
  });

  Future<void> dispose();
}

/// Flattened representation of a remote Drive file for local mirroring.
final class GDriveListedEntry {
  final String fileId;
  final String path;
  final String? md5Checksum;
  final String? headRevisionId;
  final String? version;
  final bool isFolder;

  const GDriveListedEntry({
    required this.fileId,
    required this.path,
    required this.isFolder,
    this.md5Checksum,
    this.headRevisionId,
    this.version,
  });
}

class DriveApiImpl implements DriveApi {
  final drive.DriveApi _driveApi;
  DriveApiImpl(this._driveApi);

  Future<drive.FileList> list({
    required String q,
    required String spaces,
    required String $fields,
    int? pageSize,
    String? pageToken,
  }) =>
      _driveApi.files.list(
        q: q,
        spaces: spaces,
        $fields: $fields,
        pageSize: pageSize,
        pageToken: pageToken,
      );

  Future<drive.File> create(drive.File folderMetadata,
          {drive.Media? uploadMedia, required String $fields}) =>
      _driveApi.files
          .create(folderMetadata, uploadMedia: uploadMedia, $fields: $fields);

  Future<Object> get(String fileId,
          {String? $fields,
          drive.DownloadOptions downloadOptions =
              drive.DownloadOptions.metadata}) =>
      _driveApi.files
          .get(fileId, $fields: $fields, downloadOptions: downloadOptions);

  Future<drive.File> update(drive.File file, String fileId,
          {required drive.Media uploadMedia, required String $fields}) =>
      _driveApi.files
          .update(file, fileId, uploadMedia: uploadMedia, $fields: $fields);
}

abstract interface class DriveApi {
  Future<drive.FileList> list({
    required String q,
    required String spaces,
    required String $fields,
    int? pageSize,
    String? pageToken,
  });

  Future<drive.File> create(drive.File folderMetadata,
      {drive.Media? uploadMedia, required String $fields});

  Future<Object> get(String fileId,
      {String? $fields,
      drive.DownloadOptions downloadOptions = drive.DownloadOptions.metadata});

  Future<drive.File> update(drive.File file, String fileId,
      {required drive.Media uploadMedia, required String $fields});
}

class PerflogDriveApi implements DriveApi {
  final Perflog _perflog;
  final DriveApi _inner;
  final GDrivePathIndex? _pathIndex;
  PerflogDriveApi(this._inner,
      {required Perflog perflog,
      String name = 'raw_gdrive',
      bool? includeArgs,
      GDrivePathIndex? pathIndex})
      : _perflog = perflog.create(name, _inner, includeArgs: includeArgs),
        _pathIndex = pathIndex;

  @override
  Future<drive.File> create(drive.File folderMetadata,
          {drive.Media? uploadMedia, required String $fields}) =>
      _perflog.measure(
          'create',
          args: [folderMetadata.name ?? ''],
          () => _inner.create(folderMetadata,
              uploadMedia: uploadMedia, $fields: $fields));

  @override
  Future<Object> get(String fileId,
          {String? $fields,
          drive.DownloadOptions downloadOptions =
              drive.DownloadOptions.metadata}) =>
      _perflog.measure(
          'get',
          args: [_pathIndex?.describeFileId(fileId) ?? fileId],
          () => _inner.get(fileId,
              $fields: $fields, downloadOptions: downloadOptions));

  @override
  Future<drive.FileList> list(
          {required String q,
          required String spaces,
          required String $fields,
          int? pageSize,
          String? pageToken}) =>
      _perflog.measure(
          'list',
          args: [q],
          () => _inner.list(
              q: q,
              spaces: spaces,
              $fields: $fields,
              pageSize: pageSize,
              pageToken: pageToken));

  @override
  Future<drive.File> update(drive.File file, String fileId,
          {required drive.Media uploadMedia, required String $fields}) =>
      _perflog.measure(
          'update',
          args: [_pathIndex?.describeFileId(fileId) ?? fileId],
          () => _inner.update(file, fileId,
              uploadMedia: uploadMedia, $fields: $fields));
}

/// Google Drive API client for RDF document storage.
///
/// Provides low-level Google Drive operations with OAuth2 authentication,
/// ETag-based concurrency control, and automatic token refresh on 401 errors.
class GDriveClient implements GDriveApiClient {
  final DriveApi _driveApi;
  final GDrivePathIndex _pathIndex;

  GDriveClient._({
    required DriveApi driveApi,
    required GDrivePathIndex pathIndex,
  })  : _driveApi = driveApi,
        _pathIndex = pathIndex;

  factory GDriveClient({
    required GDriveAuthProvider authProvider,
    required http.Client httpClient,
    Perflog? perflog,
  }) {
    final client = _GoogleAuthClient(httpClient, authProvider);
    final driveApi = DriveApiImpl(drive.DriveApi(client));
    final pathIndex = GDrivePathIndex();

    return GDriveClient._(
      driveApi: perflog == null
          ? driveApi
          : PerflogDriveApi(driveApi, perflog: perflog, pathIndex: pathIndex),
      pathIndex: pathIndex,
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
  @override
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
        _pathIndex.registerFolderId(
          folderId,
          _pathIndex.buildChildPath(parentId: parentId, name: folderName),
        );
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

      final createdFolder = await _driveApi.create(
        folderMetadata,
        $fields: 'id',
      );

      final folderId = createdFolder.id!;
      _clientLog.info('Created folder "$folderName" with ID: $folderId');
      _pathIndex.registerFolderId(
        folderId,
        _pathIndex.buildChildPath(parentId: parentId, name: folderName),
      );
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

  @override
  Future<({String fileId, String etag})> createFile<T>(
    String filename,
    T graph, {
    required String folderId,
    bool fileNameMayBeRelativePath = false,
    String spaces = 'drive',
    required String contentType,
    required String Function(T) convert,
  }) async {
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
      final content = convert(graph);
      final bytes = utf8.encode(content);

      // 3. Create file metadata
      final fileMetadata = drive.File()
        ..name = actualFileName
        ..parents = [parentId]
        ..mimeType = contentType;

      // 4. Upload with media
      final media = drive.Media(Stream.value(bytes), bytes.length);

      final createdFile = await _driveApi.create(
        fileMetadata,
        uploadMedia: media,
        $fields: 'id, md5Checksum',
      );

      final fileId = createdFile.id!;
      final etag = createdFile.md5Checksum!;
      _clientLog.info('Created file: $fileId with ETag: $etag');

      _pathIndex.registerFileId(
        fileId,
        _pathIndex.buildChildPath(parentId: parentId, name: actualFileName),
      );

      return (fileId: fileId, etag: etag);
    } catch (e, stackTrace) {
      handleGDriveAuthError(e);
      _clientLog.severe('Failed to create file "$filename"', e, stackTrace);
      throw GDriveClientException('Failed to create file "$filename": $e');
    }
  }

  @override
  Future<({String fileId, String md5Checksum})> createFileRaw(
    String filename,
    List<int> bytes, {
    required String folderId,
    required String contentType,
    bool fileNameMayBeRelativePath = false,
    String spaces = 'drive',
  }) async {
    try {
      String parentId = folderId;
      String actualFileName = filename;
      if (fileNameMayBeRelativePath && filename.contains('/')) {
        final parts = filename.split('/');
        actualFileName = parts.last;
        for (final folderName in parts.sublist(0, parts.length - 1)) {
          parentId = await getOrCreateFolder(
              folderName: folderName, parentId: parentId, spaces: spaces);
        }
      }

      _clientLog
          .fine('Creating raw file "$actualFileName" in folder=$parentId');

      final fileMetadata = drive.File()
        ..name = actualFileName
        ..parents = [parentId]
        ..mimeType = contentType;

      final media = drive.Media(Stream.value(bytes), bytes.length);
      final createdFile = await _driveApi.create(
        fileMetadata,
        uploadMedia: media,
        $fields: 'id, md5Checksum',
      );

      final fileId = createdFile.id!;
      final md5Checksum = createdFile.md5Checksum ?? '';
      _clientLog.info('Created raw file: $fileId with md5: $md5Checksum');

      _pathIndex.registerFileId(
        fileId,
        _pathIndex.buildChildPath(parentId: parentId, name: actualFileName),
      );

      return (fileId: fileId, md5Checksum: md5Checksum);
    } catch (e, stackTrace) {
      handleGDriveAuthError(e);
      _clientLog.severe('Failed to create raw file "$filename"', e, stackTrace);
      throw GDriveClientException('Failed to create raw file "$filename": $e');
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
  @override
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
        final fileId = await _findFileInFolder(
            fileName: actualFileName,
            parentId: currentParentId,
            spaces: spaces);
        if (fileId != null) {
          _pathIndex.registerFileId(
            fileId,
            _pathIndex.buildChildPath(
                parentId: currentParentId, name: actualFileName),
          );
        }
        return fileId;
      }

      // Direct search in parent folder
      final fileId = await _findFileInFolder(
          fileName: fileName, parentId: parentId, spaces: spaces);
      if (fileId != null) {
        _pathIndex.registerFileId(
          fileId,
          _pathIndex.buildChildPath(parentId: parentId, name: fileName),
        );
      }
      return fileId;
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
        _pathIndex.registerFileId(
          fileId,
          _pathIndex.buildChildPath(parentId: parentId, name: fileName),
        );
        return fileId;
      }

      _clientLog.fine('File not found');
      return null;
    } on drive.DetailedApiRequestError catch (e) {
      handleGDriveAuthError(e);
      rethrow;
    }
  }

  @override
  Future<({T? graph, String? etag, bool notModified})> download<T>(
      String fileId,
      {String? ifNoneMatch,
      required T Function(String) convert}) async {
    _clientLog.fine('Downloading file $fileId');

    try {
      // 1. Get file metadata (for ETag check)
      final metadata = await _driveApi.get(
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
      final media = await _driveApi.get(
        fileId,
        downloadOptions: drive.DownloadOptions.fullMedia,
      ) as drive.Media;

      // 4. Read stream and decode RDF
      final completer = <int>[];
      await for (final chunk in media.stream) {
        completer.addAll(chunk);
      }
      final content = utf8.decode(completer);
      final graph = convert(content);

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

  @override
  Future<List<int>> downloadRawBytes(String fileId) async {
    _clientLog.fine('Downloading raw bytes for file $fileId');
    try {
      final media = await _driveApi.get(
        fileId,
        downloadOptions: drive.DownloadOptions.fullMedia,
      ) as drive.Media;

      final bytes = <int>[];
      await for (final chunk in media.stream) {
        bytes.addAll(chunk);
      }
      return bytes;
    } on drive.DetailedApiRequestError catch (e, stackTrace) {
      handleGDriveAuthError(e);
      _clientLog.severe(
          'API error downloading raw file $fileId', e, stackTrace);
      throw GDriveClientException(
          'Failed to download raw file $fileId: ${e.status} ${e.message}');
    } catch (e, stackTrace) {
      _clientLog.severe('Failed to download raw file $fileId', e, stackTrace);
      throw GDriveClientException('Failed to download raw file $fileId: $e');
    }
  }

  @override
  Future<RemoteUploadResult> upload<T>(
    String fileId,
    T updatedGraph, {
    required String ifMatch,
    required String Function(T) convert,
  }) async {
    _clientLog.fine('Uploading file $fileId');

    try {
      // 1. Fetch current ETag for conflict detection
      final metadata = await _driveApi.get(
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
      // FIXME: should we extract the original content type from the file metadata?
      // Or should we always use the client's default content type and set it in drive.File() metadata?
      final content = convert(updatedGraph);
      final bytes = utf8.encode(content);

      // 4. Upload updated content
      final media = drive.Media(Stream.value(bytes), bytes.length);
      final updated = await _driveApi.update(
        drive.File() // Empty metadata (no property changes)
        // ..mimeType = _contentType, // FIXME: make sure the mimeType is correct?
        ,
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

  @override
  Future<RemoteUploadResult> uploadRaw(String fileId, List<int> bytes,
      {required String ifMatch}) async {
    _clientLog.fine('Uploading raw file $fileId');

    try {
      final metadata = await _driveApi.get(
        fileId,
        $fields: 'md5Checksum',
      ) as drive.File;

      final currentEtag = metadata.md5Checksum;
      if (currentEtag != ifMatch) {
        _clientLog.warning(
            'ETag mismatch for raw file $fileId: expected=$ifMatch, actual=$currentEtag');
        return RemoteUploadResult.conflict();
      }

      final media = drive.Media(Stream.value(bytes), bytes.length);
      final updated = await _driveApi.update(
        drive.File(),
        fileId,
        uploadMedia: media,
        $fields: 'md5Checksum',
      );

      final newEtag = updated.md5Checksum ?? '';
      _clientLog.info('Updated raw file: $fileId (new ETag: $newEtag)');
      return RemoteUploadResult.success(newEtag);
    } on drive.DetailedApiRequestError catch (e, stackTrace) {
      handleGDriveAuthError(e);

      if (e.status == 404) {
        _clientLog.warning('File not found during raw upload: $fileId');
        throw GDriveClientException('File not found: $fileId');
      }

      _clientLog.severe('API error uploading raw file $fileId', e, stackTrace);
      throw GDriveClientException(
          'Failed to upload raw file $fileId: ${e.status} ${e.message}');
    } catch (e, stackTrace) {
      _clientLog.severe('Failed to upload raw file $fileId', e, stackTrace);
      throw GDriveClientException('Failed to upload raw file $fileId: $e');
    }
  }

  @override
  Future<List<GDriveListedEntry>> listFilesRecursively({
    required String rootFolderId,
    required String spaces,
    required int maxConcurrentRequests,
  }) async {
    if (rootFolderId == 'appDataFolder') {
      final entries = await _listAppDataFolder(spaces);
      _pathIndex.registerEntries(entries);
      return entries;
    }
    final results = <GDriveListedEntry>[];
    final queue = Queue<_DriveFolderTask>();
    queue.add(_DriveFolderTask(folderId: rootFolderId, prefix: ''));

    final concurrency = maxConcurrentRequests < 1 ? 1 : maxConcurrentRequests;

    final done = Completer<void>();
    var active = 0;

    Future<void> schedule() async {
      while (active < concurrency && queue.isNotEmpty) {
        final task = queue.removeFirst();
        active++;
        _listFolder(task, spaces).then((children) {
          for (final child in children) {
            if (child.isFolder) {
              _pathIndex.registerEntry(child);
              queue.add(_DriveFolderTask(
                folderId: child.fileId,
                prefix: child.path,
              ));
            } else {
              _pathIndex.registerEntry(child);
              results.add(child);
            }
          }
        }).whenComplete(() {
          active--;
          if (queue.isEmpty && active == 0 && !done.isCompleted) {
            done.complete();
          } else {
            schedule();
          }
        });
      }
    }

    await schedule();
    await done.future;
    return results;
  }

  Future<List<GDriveListedEntry>> _listAppDataFolder(String spaces) async {
    final entries = <GDriveListedEntry>[];
    final byId = <String, _DriveNode>{};

    String? pageToken;
    do {
      final fileList = await _driveApi.list(
        spaces: spaces,
        q: 'trashed=false',
        pageSize: 1000,
        pageToken: pageToken,
        $fields:
            'nextPageToken, files(id, name, mimeType, parents, md5Checksum, headRevisionId, version)',
      );

      for (final file in fileList.files ?? <drive.File>[]) {
        final id = file.id ?? '';
        final name = file.name ?? '';
        if (id.isEmpty || name.isEmpty) continue;
        byId[id] = _DriveNode(
          id: id,
          name: name,
          parents: file.parents ?? const [],
          isFolder: file.mimeType == 'application/vnd.google-apps.folder',
          md5Checksum: file.md5Checksum,
          headRevisionId: file.headRevisionId,
          version: file.version?.toString(),
        );
      }
      pageToken = fileList.nextPageToken;
    } while (pageToken != null && pageToken.isNotEmpty);

    String buildPath(_DriveNode node) {
      final segments = <String>[node.name];
      var current = node;
      while (current.parents.isNotEmpty) {
        final parentId = current.parents.first;
        final parent = byId[parentId];
        if (parent == null) break;
        segments.insert(0, parent.name);
        current = parent;
      }
      return segments.join('/');
    }

    for (final node in byId.values) {
      final filePath = buildPath(node);
      entries.add(GDriveListedEntry(
        fileId: node.id,
        path: filePath,
        isFolder: node.isFolder,
        md5Checksum: node.md5Checksum,
        headRevisionId: node.headRevisionId,
        version: node.version,
      ));
    }

    return entries;
  }

  Future<List<GDriveListedEntry>> _listFolder(
      _DriveFolderTask task, String spaces) async {
    final entries = <GDriveListedEntry>[];
    String? pageToken;
    final prefix = task.prefix;

    do {
      final query = "'${task.folderId}' in parents and trashed=false";
      final fileList = await _driveApi.list(
        q: query,
        spaces: spaces,
        pageSize: 1000,
        pageToken: pageToken,
        $fields:
            'nextPageToken, files(id, name, mimeType, md5Checksum, headRevisionId, version)',
      );

      for (final file in fileList.files ?? <drive.File>[]) {
        final name = file.name ?? '';
        if (name.isEmpty) continue;
        final filePath = prefix.isEmpty ? name : path.join(prefix, name);
        final isFolder = file.mimeType == 'application/vnd.google-apps.folder';
        entries.add(GDriveListedEntry(
          fileId: file.id ?? '',
          path: filePath,
          isFolder: isFolder,
          md5Checksum: file.md5Checksum,
          headRevisionId: file.headRevisionId,
          version: file.version?.toString(),
        ));
      }
      pageToken = fileList.nextPageToken;
    } while (pageToken != null && pageToken.isNotEmpty);

    return entries;
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

  @override
  Future<void> dispose() {
    // No resources to clean up in this implementation
    return Future.value();
  }
}

final class _DriveFolderTask {
  final String folderId;
  final String prefix;

  const _DriveFolderTask({
    required this.folderId,
    required this.prefix,
  });
}

final class _DriveNode {
  final String id;
  final String name;
  final List<String> parents;
  final bool isFolder;
  final String? md5Checksum;
  final String? headRevisionId;
  final String? version;

  const _DriveNode({
    required this.id,
    required this.name,
    required this.parents,
    required this.isFolder,
    this.md5Checksum,
    this.headRevisionId,
    this.version,
  });
}

/// HTTP client for googleapis library that adds Bearer token authentication.
///
/// The googleapis package requires an authenticated http.Client.
/// This implementation adds the OAuth2 access token to all requests.
/// Token refresh logic is handled at the method level (download/upload).
///
/// Enables gzip compression for all requests to reduce bandwidth usage.
/// The http package automatically decompresses gzip responses.
class _GoogleAuthClient extends http.BaseClient {
  final GDriveAuthProvider _authProvider;
  final http.Client _inner;

  _GoogleAuthClient(this._inner, this._authProvider);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final accessToken = await _authProvider.getAccessToken();
    request.headers['Authorization'] = 'Bearer $accessToken';
    request.headers['Accept-Encoding'] = 'gzip';
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

/// Local mirror cache for high-throughput GDrive sync.
///
/// Mirrors the remote Drive folder into a sandboxed local directory and
/// serves all sync downloads/uploads from that local copy.
class GDriveLocalMirror {
  final GDriveApiClient _client;
  final TypeIndexMappings _typeIndexMappings;
  final ResourceLocator _resourceLocator;
  final GDriveLocalMirrorConfig _config;
  final String _spaces;
  final String _userId;

  late final Directory _rootDir;
  late final Directory _filesDir;
  late final File _indexFile;
  late _GDriveMirrorIndex _index;
  late final Map<String, IriTerm> _folderNameToType;

  GDriveLocalMirror({
    required GDriveApiClient client,
    required TypeIndexMappings typeIndexMappings,
    required ResourceLocator resourceLocator,
    required GDriveLocalMirrorConfig config,
    required String spaces,
    required String userId,
  })  : _client = client,
        _typeIndexMappings = typeIndexMappings,
        _resourceLocator = resourceLocator,
        _config = config,
        _spaces = spaces,
        _userId = userId {
    _folderNameToType = {
      for (final entry in _typeIndexMappings.typeMappings.entries)
        entry.value.folderName: entry.key,
    };
  }

  Future<void> initialize() async {
    _rootDir = await _resolveRootDir();
    _filesDir = Directory(path.join(_rootDir.path, 'files'));
    _indexFile = File(path.join(_rootDir.path, 'index.json'));

    await _filesDir.create(recursive: true);

    final existingIndex = await _loadIndex();

    // Streaming pipeline: start downloads while listing is still in progress
    final updatedIndex = existingIndex.copy();
    await _streamingListAndDownload(updatedIndex);

    _index = updatedIndex;
    await _saveIndex(_index);
  }

  Future<RemoteDownloadResult<T>> download<T>(
    IriTerm documentIri, {
    String? ifNoneMatch,
    required T Function(String) convert,
  }) async {
    final relativePath = _relativePathForDocument(documentIri);
    final entry = _index.entries[relativePath];
    if (entry == null) {
      return RemoteDownloadResult<T>(
          graph: null, etag: null, notModified: false);
    }

    final file = File(_localFilePath(relativePath));
    if (!await file.exists()) {
      return RemoteDownloadResult<T>(
          graph: null, etag: null, notModified: false);
    }

    final currentEtag = entry.localMd5 ?? await _computeFileMd5(file);
    if (ifNoneMatch != null && ifNoneMatch == currentEtag) {
      return RemoteDownloadResult<T>.notModified(etag: currentEtag);
    }

    final content = await file.readAsString();
    final graph = convert(content);
    return RemoteDownloadResult<T>(graph: graph, etag: currentEtag);
  }

  Future<RemoteUploadResult> upload<T>(IriTerm documentIri, T updatedGraph,
      {String? ifMatch,
      required String Function(T) convert,
      required String contentType}) async {
    final relativePath = _relativePathForDocument(documentIri);
    final entry = _index.entries[relativePath];

    if (ifMatch == null) {
      if (entry != null) {
        return RemoteUploadResult.conflict();
      }
    } else {
      if (entry == null) {
        return RemoteUploadResult.conflict();
      }
      final currentEtag = entry.localMd5 ?? entry.remoteMd5;
      if (currentEtag != ifMatch) {
        return RemoteUploadResult.conflict();
      }
    }
    final content = convert(updatedGraph);
    final bytes = utf8.encode(content);
    final newMd5 = _computeMd5(bytes);

    final file = File(_localFilePath(relativePath));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);

    final updatedEntry =
        (entry ?? _GDriveMirrorIndexEntry.newLocal(relativePath)).copyWith(
      localMd5: newMd5,
      dirty: true,
      contentType: contentType,
    );

    _index.entries[relativePath] = updatedEntry;
    return RemoteUploadResult.success(newMd5);
  }

  Future<void> finalize() async {
    final dirtyEntries = _index.entries.values.where((e) => e.dirty).toList();
    if (dirtyEntries.isEmpty) return;

    await _runConcurrent(
      dirtyEntries,
      _config.maxConcurrentUploads,
      (entry) async {
        final filePath = _localFilePath(entry.path);
        final file = File(filePath);
        if (!await file.exists()) {
          _mirrorLog
              .warning('Local file missing during finalize: ${entry.path}');
          return;
        }

        final bytes = await file.readAsBytes();
        final localMd5 = _computeMd5(bytes);

        if (entry.fileId == null) {
          final contentType = entry.contentType ?? 'text/turtle';
          final created =
              await _createRemoteFile(entry.path, bytes, contentType);
          if (created == null) return;

          _index.entries[entry.path] = entry.copyWith(
            fileId: created.fileId,
            remoteMd5: created.md5Checksum,
            localMd5: created.md5Checksum,
            dirty: false,
            localOnly: false,
          );
          return;
        }

        final ifMatch = entry.remoteMd5 ?? localMd5;
        try {
          final result =
              await _client.uploadRaw(entry.fileId!, bytes, ifMatch: ifMatch);
          if (result is SuccessUploadResult) {
            _index.entries[entry.path] = entry.copyWith(
              remoteMd5: result.etag,
              localMd5: result.etag,
              dirty: false,
            );
          } else {
            _mirrorLog
                .warning('Conflict while finalizing upload: ${entry.path}');
          }
        } on GDriveClientException catch (e) {
          if (e.message.startsWith('File not found:')) {
            _mirrorLog.warning(
              'Remote file missing during finalize, recreating: ${entry.path}',
            );
            final contentType = entry.contentType ?? 'text/turtle';
            final created =
                await _createRemoteFile(entry.path, bytes, contentType);
            if (created == null) return;

            _index.entries[entry.path] = entry.copyWith(
              fileId: created.fileId,
              remoteMd5: created.md5Checksum,
              localMd5: created.md5Checksum,
              dirty: false,
              localOnly: false,
            );
          } else {
            rethrow;
          }
        }
      },
    );

    await _saveIndex(_index);
  }

  Future<Directory> _resolveRootDir() async {
    final rootPath = _config.cacheRootPath ?? Directory.systemTemp.path;
    final userSegment = base64Url.encode(utf8.encode(_userId));
    final dir = Directory(
        path.join(rootPath, 'locorda_gdrive_cache', userSegment, _spaces));
    await dir.create(recursive: true);
    return dir;
  }

  String _relativePathForDocument(IriTerm documentIri) {
    final doc = _resourceLocator.fromIri(documentIri);
    final folderName = _typeIndexMappings.getFolderName(doc.typeIri);
    return path.normalize(path.join(folderName, doc.id));
  }

  String _localFilePath(String relativePath) {
    return path.join(_filesDir.path, relativePath);
  }

  Future<_GDriveMirrorIndex> _loadIndex() async {
    if (!await _indexFile.exists()) {
      return _GDriveMirrorIndex.empty();
    }

    try {
      final content = await _indexFile.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      return _GDriveMirrorIndex.fromJson(json);
    } catch (e, stackTrace) {
      _mirrorLog.warning(
          'Failed to read mirror index, rebuilding', e, stackTrace);
      return _GDriveMirrorIndex.empty();
    }
  }

  Future<void> _saveIndex(_GDriveMirrorIndex index) async {
    final json = jsonEncode(index.toJson());
    await _indexFile.writeAsString(json, flush: true);
  }

  /// Streaming pipeline: list files and download them concurrently as they're discovered.
  ///
  /// This replaces the two-phase approach (list all, then download all) with a
  /// single-pass pipeline that starts downloads immediately when files are found.
  Future<void> _streamingListAndDownload(_GDriveMirrorIndex index) async {
    final downloadQueue = Queue<_GDriveMirrorIndexEntry>();
    final downloadCompleter = Completer<void>();
    final listCompleter = Completer<void>();
    final seenPaths = <String>{};

    var activeDownloads = 0;
    var listingComplete = false;

    // Download worker pool
    Future<void> scheduleDownloads() async {
      while (activeDownloads < _config.maxConcurrentDownloads &&
          downloadQueue.isNotEmpty) {
        final entry = downloadQueue.removeFirst();
        activeDownloads++;

        _downloadFile(entry, index).whenComplete(() {
          activeDownloads--;
          if (listingComplete &&
              downloadQueue.isEmpty &&
              activeDownloads == 0 &&
              !downloadCompleter.isCompleted) {
            downloadCompleter.complete();
          } else {
            scheduleDownloads();
          }
        });
      }
    }

    // Listing phase: stream entries and queue downloads
    _streamListFiles((remoteEntry) {
      if (remoteEntry.isFolder) return;
      seenPaths.add(remoteEntry.path);

      final existingEntry = index.entries[remoteEntry.path];
      final needsDownload = _shouldDownload(
        remoteEntry,
        existingEntry,
      );

      // Update index with remote metadata
      final updatedEntry = (existingEntry ??
              _GDriveMirrorIndexEntry.remote(
                  remoteEntry.path, remoteEntry.fileId))
          .copyWith(
        fileId: remoteEntry.fileId,
        remoteMd5: remoteEntry.md5Checksum ?? existingEntry?.remoteMd5,
        headRevisionId: remoteEntry.headRevisionId,
        version: remoteEntry.version,
        localOnly: false,
      );
      index.entries[remoteEntry.path] = updatedEntry;

      if (needsDownload) {
        downloadQueue.add(updatedEntry);
        scheduleDownloads();
      }
    }).then((_) {
      listingComplete = true;
      if (downloadQueue.isEmpty && activeDownloads == 0) {
        downloadCompleter.complete();
      }
      listCompleter.complete();
    });

    await listCompleter.future;
    await downloadCompleter.future;

    _purgeMissingRemoteEntries(index, seenPaths);
  }

  void _purgeMissingRemoteEntries(
    _GDriveMirrorIndex index,
    Set<String> seenPaths,
  ) {
    final missingPaths =
        index.entries.keys.where((path) => !seenPaths.contains(path)).toList();
    if (missingPaths.isEmpty) return;

    for (final pathEntry in missingPaths) {
      index.entries.remove(pathEntry);
      final file = File(_localFilePath(pathEntry));
      if (file.existsSync()) {
        file.deleteSync();
      }
    }

    _mirrorLog.warning(
      'Removed ${missingPaths.length} local mirror entries missing on remote',
    );
  }

  /// Stream files from Drive API, calling callback for each entry.
  Future<void> _streamListFiles(
    void Function(GDriveListedEntry) onEntry,
  ) async {
    final entries = await _client.listFilesRecursively(
      rootFolderId: _typeIndexMappings.appFolderId,
      spaces: _spaces,
      maxConcurrentRequests: _config.maxConcurrentListings,
    );
    for (final entry in entries) {
      onEntry(entry);
    }
  }

  bool _shouldDownload(
    GDriveListedEntry remote,
    _GDriveMirrorIndexEntry? existing,
  ) {
    if (remote.fileId.isEmpty) return false;

    final localFile = File(_localFilePath(remote.path));
    if (!localFile.existsSync()) return true;

    if (existing == null) return true;

    final remoteMd5 = remote.md5Checksum;
    if (remoteMd5 != null && remoteMd5 != existing.localMd5) {
      return true;
    }

    return false;
  }

  Future<void> _downloadFile(
    _GDriveMirrorIndexEntry entry,
    _GDriveMirrorIndex index,
  ) async {
    try {
      final bytes = await _client.downloadRawBytes(entry.fileId!);
      final file = File(_localFilePath(entry.path));
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes);

      final localMd5 = _computeMd5(bytes);
      final updatedEntry = entry.copyWith(
        localMd5: localMd5,
        remoteMd5: entry.remoteMd5 ?? localMd5,
        dirty: false,
      );
      index.entries[entry.path] = updatedEntry;
    } catch (e, stackTrace) {
      _mirrorLog.warning('Failed to download ${entry.path}', e, stackTrace);
    }
  }

  Future<({String fileId, String md5Checksum})?> _createRemoteFile(
      String relativePath, List<int> bytes, String contentType) async {
    final segments = path.split(relativePath);
    if (segments.isEmpty) return null;
    final folderName = segments.first;
    final typeIri = _folderNameToType[folderName];
    if (typeIri == null) {
      _mirrorLog.warning('Unknown type folder for path: $relativePath');
      return null;
    }

    final folderId = _typeIndexMappings.getFolderId(typeIri);
    final fileName = path.joinAll(segments.skip(1));
    if (fileName.isEmpty) {
      _mirrorLog
          .warning('Cannot create remote file with empty name: $relativePath');
      return null;
    }

    return _client.createFileRaw(
      fileName,
      bytes,
      folderId: folderId,
      fileNameMayBeRelativePath: true,
      spaces: _spaces,
      contentType: contentType,
    );
  }

  Future<String> _computeFileMd5(File file) async {
    final bytes = await file.readAsBytes();
    return _computeMd5(bytes);
  }

  String _computeMd5(List<int> bytes) {
    return md5.convert(bytes).toString();
  }

  Future<void> _runConcurrent<T>(
    List<T> items,
    int maxConcurrent,
    Future<void> Function(T) action,
  ) async {
    final queue = Queue<T>.from(items);
    final concurrency = maxConcurrent < 1 ? 1 : maxConcurrent;
    final done = Completer<void>();
    var active = 0;

    Future<void> schedule() async {
      while (active < concurrency && queue.isNotEmpty) {
        final item = queue.removeFirst();
        active++;
        action(item).whenComplete(() {
          active--;
          if (queue.isEmpty && active == 0 && !done.isCompleted) {
            done.complete();
          } else {
            schedule();
          }
        });
      }
    }

    if (items.isEmpty) return;
    await schedule();
    await done.future;
  }
}

final class _GDriveMirrorIndex {
  final Map<String, _GDriveMirrorIndexEntry> entries;

  _GDriveMirrorIndex({required this.entries});

  factory _GDriveMirrorIndex.empty() => _GDriveMirrorIndex(entries: {});

  factory _GDriveMirrorIndex.fromJson(Map<String, dynamic> json) {
    final entriesJson =
        (json['entries'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
    final entries = {
      for (final entryJson in entriesJson)
        entryJson['path'] as String:
            _GDriveMirrorIndexEntry.fromJson(entryJson),
    };
    return _GDriveMirrorIndex(entries: entries);
  }

  Map<String, dynamic> toJson() {
    return {
      'version': 1,
      'updatedAt': DateTime.now().toIso8601String(),
      'entries': entries.values.map((e) => e.toJson()).toList(),
    };
  }

  _GDriveMirrorIndex copy() {
    return _GDriveMirrorIndex(
      entries: {
        for (final entry in entries.entries) entry.key: entry.value.copyWith(),
      },
    );
  }
}

final class _GDriveMirrorIndexEntry {
  final String path;
  final String? fileId;
  final String? remoteMd5;
  final String? localMd5;
  final String? headRevisionId;
  final String? version;
  final String? contentType;
  final bool dirty;
  final bool localOnly;

  const _GDriveMirrorIndexEntry({
    required this.path,
    required this.fileId,
    required this.remoteMd5,
    required this.localMd5,
    required this.headRevisionId,
    required this.version,
    this.contentType,
    required this.dirty,
    required this.localOnly,
  });

  factory _GDriveMirrorIndexEntry.remote(String path, String fileId) {
    return _GDriveMirrorIndexEntry(
      path: path,
      fileId: fileId,
      remoteMd5: null,
      localMd5: null,
      headRevisionId: null,
      version: null,
      contentType: null,
      dirty: false,
      localOnly: false,
    );
  }

  factory _GDriveMirrorIndexEntry.newLocal(String path) {
    return _GDriveMirrorIndexEntry(
      path: path,
      fileId: null,
      remoteMd5: null,
      localMd5: null,
      headRevisionId: null,
      version: null,
      contentType: null,
      dirty: true,
      localOnly: true,
    );
  }

  factory _GDriveMirrorIndexEntry.fromJson(Map<String, dynamic> json) {
    return _GDriveMirrorIndexEntry(
      path: json['path'] as String,
      fileId: json['fileId'] as String?,
      remoteMd5: json['remoteMd5'] as String?,
      localMd5: json['localMd5'] as String?,
      headRevisionId: json['headRevisionId'] as String?,
      version: json['version'] as String?,
      contentType: json['contentType'] as String?,
      dirty: json['dirty'] as bool? ?? false,
      localOnly: json['localOnly'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'path': path,
      'fileId': fileId,
      'remoteMd5': remoteMd5,
      'localMd5': localMd5,
      'headRevisionId': headRevisionId,
      'version': version,
      'contentType': contentType,
      'dirty': dirty,
      'localOnly': localOnly,
    };
  }

  _GDriveMirrorIndexEntry copyWith({
    String? fileId,
    String? remoteMd5,
    String? localMd5,
    String? headRevisionId,
    String? version,
    String? contentType,
    bool? dirty,
    bool? localOnly,
  }) {
    return _GDriveMirrorIndexEntry(
      path: path,
      fileId: fileId ?? this.fileId,
      remoteMd5: remoteMd5 ?? this.remoteMd5,
      localMd5: localMd5 ?? this.localMd5,
      headRevisionId: headRevisionId ?? this.headRevisionId,
      version: version ?? this.version,
      contentType: contentType ?? this.contentType,
      dirty: dirty ?? this.dirty,
      localOnly: localOnly ?? this.localOnly,
    );
  }
}

class GDriveSyncStorage extends RemoteSyncStorage {
  final GDriveApiClient _client;

  final TypeIndexMappings _typeIndexMappings;
  final ResourceLocator _resourceLocator;
  final String _spaces;
  final GDriveLocalMirror? _localMirror;
  final RdfCore _rdfCore;
  final String _contentType;
  final String _datasetContentType;
  final GDriveConfig _config;
  GDriveSyncStorage({
    required GDriveApiClient client,
    required TypeIndexMappings typeIndexMappings,
    required ResourceLocator resourceLocator,
    required String spaces,
    required RdfCore rdfCore,
    required String contentType,
    required String datasetContentType,
    required GDriveConfig config,
    GDriveLocalMirror? localMirror,
  })  : _client = client,
        _typeIndexMappings = typeIndexMappings,
        _resourceLocator = resourceLocator,
        _spaces = spaces,
        _config = config,
        _localMirror = localMirror,
        _contentType = contentType,
        _datasetContentType = datasetContentType,
        _rdfCore = rdfCore;

  @override
  int get maxConcurrentDocumentSyncs => _config.maxConcurrentDocumentSyncs;
  @override
  int get maxConcurrentIndexSyncs => _config.maxConcurrentIndexSyncs;
  @override
  int get maxConcurrentShardSyncs => _config.maxConcurrentShardSyncs;

  @override
  Future<RemoteDownloadResult<RdfGraph>> download(IriTerm documentIri,
          {String? ifNoneMatch}) =>
      _download<RdfGraph>(
        documentIri,
        ifNoneMatch: ifNoneMatch,
        convert: (content) =>
            _rdfCore.decode(content, contentType: _contentType),
      );

  @override
  Future<RemoteDownloadResult<RdfDataset>> downloadDataset(IriTerm documentIri,
          {String? ifNoneMatch}) =>
      _download<RdfDataset>(
        documentIri,
        ifNoneMatch: ifNoneMatch,
        convert: (content) => _rdfCore.decodeDataset(
          content,
          contentType: _datasetContentType,
        ),
      );

  Future<RemoteDownloadResult<T>> _download<T>(IriTerm documentIri,
      {String? ifNoneMatch, required T Function(String) convert}) async {
    if (_localMirror != null) {
      return _localMirror.download(
        documentIri,
        ifNoneMatch: ifNoneMatch,
        convert: convert,
      );
    }
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
    final result = await _client.download(fileId,
        ifNoneMatch: ifNoneMatch, convert: convert);
    if (result.notModified) {
      return RemoteDownloadResult.notModified(etag: result.etag!);
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
          {String? ifMatch}) =>
      _upload<RdfGraph>(
        documentIri,
        graph,
        ifMatch: ifMatch,
        contentType: _contentType,
        convert: (content) =>
            _rdfCore.encode(content, contentType: _contentType),
      );

  @override
  Future<RemoteUploadResult> uploadDataset(
          IriTerm documentIri, RdfDataset dataset,
          {String? ifMatch}) =>
      _upload<RdfDataset>(
        documentIri,
        dataset,
        ifMatch: ifMatch,
        contentType: _datasetContentType,
        convert: (content) => _rdfCore.encodeDataset(
          content,
          contentType: _datasetContentType,
        ),
      );

  Future<RemoteUploadResult> _upload<T>(
    IriTerm documentIri,
    T graph, {
    String? ifMatch,
    required String contentType,
    required String Function(T) convert,
  }) async {
    if (_localMirror != null) {
      return _localMirror.upload(
        documentIri,
        graph,
        ifMatch: ifMatch,
        convert: convert,
        contentType: contentType,
      );
    }
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
      final created = await _client.createFile(
        filePath,
        graph,
        folderId: folderId,
        fileNameMayBeRelativePath: true,
        spaces: _spaces,
        contentType: contentType,
        convert: convert,
      );
      return SuccessUploadResult(created.etag);
    } else {
      // Update existing file
      return await _client.upload(
        fileId,
        graph,
        ifMatch: ifMatch!,
        convert: convert,
      );
    }
  }

  @override
  Future<void> finalizeSync() async {
    if (_localMirror != null) {
      await _localMirror.finalize();
    }
  }
}

class GDriveRemoteStorage implements RemoteStorage {
  final RemoteId _remoteId;
  final String _userId;
  final GDriveApiClient _client;
  final GDriveTypeIndexManager _typeIndexManager;
  final ResourceLocator _resourceLocator;
  final String _spaces;
  final GDriveLocalMirrorConfig _mirrorConfig;
  final RdfCore _rdfCore;
  final String _contentType;
  final String _datasetContentType;
  final GDriveConfig _config;

  // Severely reduces the number of files that have to be transferred between
  // the client and Google Drive, improving performance significantly.
  //
  // This means that all resources of a given shard are stored within
  // the shard file with the help of rdf datasets, instead of storing
  // a single file per rdf graph.
  @override
  bool get useShardDatasets => _config.useShardDatasets;

  GDriveRemoteStorage({
    required GDriveApiClient client,
    required String userId,
    required GDriveTypeIndexManager typeIndexManager,
    required ResourceLocator resourceLocator,
    required String spaces,
    required GDriveLocalMirrorConfig mirrorConfig,
    required RdfCore rdfCore,
    required String contentType,
    required String datasetContentType,
    required GDriveConfig config,
  })  : _client = client,
        _userId = userId,
        _config = config,
        _typeIndexManager = typeIndexManager,
        _resourceLocator = resourceLocator,
        _spaces = spaces,
        _mirrorConfig = mirrorConfig,
        _remoteId = RemoteId("google", userId),
        _rdfCore = rdfCore,
        _contentType = contentType,
        _datasetContentType = datasetContentType;

  RemoteId get remoteId => _remoteId;

  @override
  Future<RemoteSyncStorage> createSyncStorage(
      SyncEngineConfig engineConfig) async {
    final typeIndexMappings =
        await _typeIndexManager.loadOrCreateTypeIndex(engineConfig);
    GDriveLocalMirror? mirror;
    if (_mirrorConfig.enabled) {
      mirror = GDriveLocalMirror(
        client: _client,
        typeIndexMappings: typeIndexMappings,
        resourceLocator: _resourceLocator,
        config: _mirrorConfig,
        spaces: _spaces,
        userId: _userId,
      );
      await mirror.initialize();
    }
    return GDriveSyncStorage(
        client: _client,
        resourceLocator: _resourceLocator,
        typeIndexMappings: typeIndexMappings,
        spaces: _spaces,
        localMirror: mirror,
        rdfCore: _rdfCore,
        contentType: _contentType,
        datasetContentType: _datasetContentType,
        config: _config);
  }

  @override
  Future<bool> isAvailable() {
    // TODO: implement availability check, maybe by using some API to
    // check for online/offline status or similar.
    return Future.value(true);
  }

  @override
  Future<void> dispose() {
    return Future.value();
  }
}

class GDriveBackend implements Backend {
  @override
  String get name => 'gdrive';
  final GDriveAuthProvider _auth;
  final GDriveApiClient _client;
  final GDriveTypeIndexManager _typeIndexManager;
  final ResourceLocator _resourceLocator;
  final GDriveConfig _config;
  final RdfCore _rdfCore;
  final String _contentType;
  final String _datasetContentType;

  List<RemoteStorage> _remotes = [];
  late final BehaviorSubject<List<RemoteStorage>> _remotesChangedSubject;

  static Backend create({
    required GDriveAuthProvider auth,
    required GDriveConfig config,
    IriTermFactory? iriTermFactory,
    required RdfCore rdfCore,
    required http.Client httpClient,
    required String contentType,
    required String datasetContentType,
  }) {
    final perflog = Perflog.root();
    final client = GDriveClient(
      authProvider: auth,
      httpClient: httpClient,
      perflog: perflog,
    );

    final backend = GDriveBackend._(
      auth: auth,
      config: config,
      //  PerfLogGDriveApiClient(client, perflog: perflog)
      client: client,
      iriTermFactory: iriTermFactory,
      contentType: contentType,
      datasetContentType: datasetContentType,
      rdfCore: rdfCore,
    );
    return PerflogBackend(backend, perflog: perflog, name: 'gdrive');
  }

  GDriveBackend._({
    required GDriveAuthProvider auth,
    required GDriveApiClient client,
    required GDriveConfig config,
    required RdfCore rdfCore,
    required String contentType,
    required String datasetContentType,
    IriTermFactory? iriTermFactory,
  })  : _auth = auth,
        _client = client,
        _config = config,
        _typeIndexManager = GDriveTypeIndexManager(
          client: client,
          iriTermFactory: iriTermFactory ?? IriTerm.validated,
          config: config,
          rdfCore: rdfCore,
        ),
        _resourceLocator = LocalResourceLocator(
          iriTermFactory: iriTermFactory ?? IriTerm.validated,
        ),
        _rdfCore = rdfCore,
        _contentType = contentType,
        _datasetContentType = datasetContentType {
    _remotesChangedSubject = BehaviorSubject<List<RemoteStorage>>();
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
        mirrorConfig: _config.localMirrorConfig,
        contentType: _contentType,
        datasetContentType: _datasetContentType,
        rdfCore: _rdfCore,
        config: _config,
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

      // Emit remote change
      _remotesChangedSubject.add(_remotes);
    } else {
      _log.info('User logged out: clearing GDrive remote storage');
      // User logged out: clear remote storage
      _remotes = [];

      // Emit remote change
      _remotesChangedSubject.add(_remotes);
    }
  }

  @override
  List<RemoteStorage> get remotes => _remotes;

  @override
  Stream<List<RemoteStorage>> get remotesChanged =>
      _remotesChangedSubject.stream;

  @override
  Future<void> dispose() async {
    _auth.isAuthenticatedNotifier.removeListener(_authStateChanged);
    await _remotesChangedSubject.close();
  }
}
