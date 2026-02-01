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

import 'auth/gdrive_auth_provider.dart';
import 'gdrive_type_index_manager.dart';
import 'shared/gdrive_config.dart';

final _log = Logger('GDriveBackend');
final _clientLog = Logger('GDriveClient');
final _mirrorLog = Logger('GDriveLocalMirror');

/// Minimal client abstraction to enable testable and swappable GDrive backends.
abstract interface class GDriveApiClient {
  RdfCore get rdfCore;

  Future<String> getOrCreateFolder({
    required String folderName,
    String? parentId,
    String spaces = 'drive',
  });

  Future<({String fileId, String etag})> createFile(
    String filename,
    RdfGraph graph, {
    required String folderId,
    bool fileNameMayBeRelativePath = false,
    String spaces = 'drive',
  });

  Future<({String fileId, String md5Checksum})> createFileRaw(
    String filename,
    List<int> bytes, {
    required String folderId,
    bool fileNameMayBeRelativePath = false,
    String spaces = 'drive',
  });

  Future<String?> findFile({
    required String fileName,
    required String parentId,
    bool fileNameMayBeRelativePath = false,
    String spaces = 'drive',
  });

  Future<({RdfGraph? graph, String? etag, bool notModified})> download(
    String fileId, {
    String? ifNoneMatch,
  });

  Future<List<int>> downloadRawBytes(String fileId);

  Future<RemoteUploadResult> upload(
    String fileId,
    RdfGraph updatedGraph, {
    required String ifMatch,
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

/// Google Drive API client for RDF document storage.
///
/// Provides low-level Google Drive operations with OAuth2 authentication,
/// ETag-based concurrency control, and automatic token refresh on 401 errors.
class GDriveClient implements GDriveApiClient {
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

  @override
  RdfCore get rdfCore => _rdfCore;

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

  @override
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

  @override
  Future<({String fileId, String md5Checksum})> createFileRaw(
      String filename, List<int> bytes,
      {required String folderId,
      bool fileNameMayBeRelativePath = false,
      String spaces = 'drive'}) async {
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
        ..mimeType = 'text/turtle';

      final media = drive.Media(Stream.value(bytes), bytes.length);
      final createdFile = await _driveApi.files.create(
        fileMetadata,
        uploadMedia: media,
        $fields: 'id, md5Checksum',
      );

      final fileId = createdFile.id!;
      final md5Checksum = createdFile.md5Checksum ?? '';
      _clientLog.info('Created raw file: $fileId with md5: $md5Checksum');

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

  @override
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

  @override
  Future<List<int>> downloadRawBytes(String fileId) async {
    _clientLog.fine('Downloading raw bytes for file $fileId');
    try {
      final media = await _driveApi.files.get(
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

  @override
  Future<RemoteUploadResult> uploadRaw(String fileId, List<int> bytes,
      {required String ifMatch}) async {
    _clientLog.fine('Uploading raw file $fileId');

    try {
      final metadata = await _driveApi.files.get(
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
      final updated = await _driveApi.files.update(
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
      return _listAppDataFolder(spaces);
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
              queue.add(_DriveFolderTask(
                folderId: child.fileId,
                prefix: child.path,
              ));
            } else {
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
      final fileList = await _driveApi.files.list(
        spaces: spaces,
        q: 'trashed=false',
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
      final fileList = await _driveApi.files.list(
        q: query,
        spaces: spaces,
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
    final remoteEntries = await _client.listFilesRecursively(
      rootFolderId: _typeIndexMappings.appFolderId,
      spaces: _spaces,
      maxConcurrentRequests: _config.maxConcurrentListings,
    );

    final updatedIndex = _reconcileIndex(existingIndex, remoteEntries);
    await _downloadMissingOrChanged(updatedIndex, remoteEntries);
    _index = updatedIndex;

    await _saveIndex(_index);
  }

  Future<RemoteDownloadResult> download(IriTerm documentIri,
      {String? ifNoneMatch}) async {
    final relativePath = _relativePathForDocument(documentIri);
    final entry = _index.entries[relativePath];
    if (entry == null) {
      return RemoteDownloadResult(graph: null, etag: null, notModified: false);
    }

    final file = File(_localFilePath(relativePath));
    if (!await file.exists()) {
      return RemoteDownloadResult(graph: null, etag: null, notModified: false);
    }

    final currentEtag = entry.localMd5 ?? await _computeFileMd5(file);
    if (ifNoneMatch != null && ifNoneMatch == currentEtag) {
      return RemoteDownloadResult.notModified(etag: currentEtag);
    }

    final content = await file.readAsString();
    final graph = _client.rdfCore.decode(content, contentType: 'text/turtle');
    return RemoteDownloadResult(graph: graph, etag: currentEtag);
  }

  Future<RemoteUploadResult> upload(IriTerm documentIri, RdfGraph graph,
      {String? ifMatch}) async {
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

    final content = _client.rdfCore.encode(graph);
    final bytes = utf8.encode(content);
    final newMd5 = _computeMd5(bytes);

    final file = File(_localFilePath(relativePath));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);

    final updatedEntry =
        (entry ?? _GDriveMirrorIndexEntry.newLocal(relativePath)).copyWith(
      localMd5: newMd5,
      dirty: true,
    );

    _index.entries[relativePath] = updatedEntry;
    await _saveIndex(_index);
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
          final created = await _createRemoteFile(entry.path, bytes);
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
        final result =
            await _client.uploadRaw(entry.fileId!, bytes, ifMatch: ifMatch);
        if (result is SuccessUploadResult) {
          _index.entries[entry.path] = entry.copyWith(
            remoteMd5: result.etag,
            localMd5: result.etag,
            dirty: false,
          );
        } else {
          _mirrorLog.warning('Conflict while finalizing upload: ${entry.path}');
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

  _GDriveMirrorIndex _reconcileIndex(
    _GDriveMirrorIndex existing,
    List<GDriveListedEntry> remoteEntries,
  ) {
    final remotePaths = remoteEntries.map((e) => e.path).toSet();
    final updated = existing.copy();

    for (final entry in remoteEntries.where((e) => !e.isFolder)) {
      final existingEntry = updated.entries[entry.path];
      updated.entries[entry.path] = (existingEntry ??
              _GDriveMirrorIndexEntry.remote(entry.path, entry.fileId))
          .copyWith(
        fileId: entry.fileId,
        remoteMd5: entry.md5Checksum ?? existingEntry?.remoteMd5,
        headRevisionId: entry.headRevisionId,
        version: entry.version,
        localOnly: false,
      );
    }

    final removedPaths = existing.entries.keys
        .where((path) => !remotePaths.contains(path))
        .toList();

    for (final pathToRemove in removedPaths) {
      final entry = updated.entries[pathToRemove];
      if (entry == null) continue;
      if (entry.localOnly || entry.dirty) continue;

      updated.entries.remove(pathToRemove);
      final file = File(_localFilePath(pathToRemove));
      if (file.existsSync()) {
        file.deleteSync();
      }
    }

    return updated;
  }

  Future<void> _downloadMissingOrChanged(
    _GDriveMirrorIndex index,
    List<GDriveListedEntry> remoteEntries,
  ) async {
    final remoteByPath = {
      for (final entry in remoteEntries.where((e) => !e.isFolder))
        entry.path: entry,
    };

    final toDownload = <_GDriveMirrorIndexEntry>[];
    for (final entry in index.entries.values) {
      final remote = remoteByPath[entry.path];
      if (remote == null || remote.fileId.isEmpty) continue;

      final file = File(_localFilePath(entry.path));
      final fileExists = await file.exists();
      final remoteMd5 = remote.md5Checksum;
      if (!fileExists || (remoteMd5 != null && remoteMd5 != entry.localMd5)) {
        toDownload.add(entry.copyWith(fileId: remote.fileId));
      }
    }

    await _runConcurrent(
      toDownload,
      _config.maxConcurrentDownloads,
      (entry) async {
        final remote = remoteByPath[entry.path];
        if (remote == null) return;

        final bytes = await _client.downloadRawBytes(remote.fileId);
        final file = File(_localFilePath(entry.path));
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes, flush: true);

        final localMd5 = _computeMd5(bytes);
        final updatedEntry = entry.copyWith(
          localMd5: localMd5,
          remoteMd5: remote.md5Checksum ?? localMd5,
          dirty: false,
        );
        index.entries[entry.path] = updatedEntry;
      },
    );
  }

  Future<({String fileId, String md5Checksum})?> _createRemoteFile(
      String relativePath, List<int> bytes) async {
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
  final bool dirty;
  final bool localOnly;

  const _GDriveMirrorIndexEntry({
    required this.path,
    required this.fileId,
    required this.remoteMd5,
    required this.localMd5,
    required this.headRevisionId,
    required this.version,
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

  GDriveSyncStorage({
    required GDriveApiClient client,
    required TypeIndexMappings typeIndexMappings,
    required ResourceLocator resourceLocator,
    required String spaces,
    GDriveLocalMirror? localMirror,
  })  : _client = client,
        _typeIndexMappings = typeIndexMappings,
        _resourceLocator = resourceLocator,
        _spaces = spaces,
        _localMirror = localMirror;

  @override
  Future<RemoteDownloadResult> download(IriTerm documentIri,
      {String? ifNoneMatch}) async {
    if (_localMirror != null) {
      return _localMirror.download(documentIri, ifNoneMatch: ifNoneMatch);
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
    if (_localMirror != null) {
      return _localMirror.upload(documentIri, graph, ifMatch: ifMatch);
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

  GDriveRemoteStorage({
    required GDriveApiClient client,
    required String userId,
    required GDriveTypeIndexManager typeIndexManager,
    required ResourceLocator resourceLocator,
    required String spaces,
    required GDriveLocalMirrorConfig mirrorConfig,
  })  : _client = client,
        _userId = userId,
        _typeIndexManager = typeIndexManager,
        _resourceLocator = resourceLocator,
        _spaces = spaces,
        _mirrorConfig = mirrorConfig,
        _remoteId = RemoteId("google", userId);

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
        mirrorConfig: _config.localMirrorConfig,
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
