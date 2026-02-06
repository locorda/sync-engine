import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;
import 'package:locorda_core/locorda_core.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;

import 'auth/gdrive_auth_provider.dart';

final _clientLog = Logger('GDriveClient');

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
