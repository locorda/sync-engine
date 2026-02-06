import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;

import 'gdrive_api.dart';
import 'gdrive_type_index_manager.dart';
import 'shared/gdrive_config.dart';

final _mirrorLog = Logger('GDriveLocalMirror');

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

  final Directory _filesDir;
  final File _indexFile;
  _GDriveMirrorIndex _index;
  final _GDriveMirrorStore _store;
  late final Map<String, IriTerm> _folderNameToType;

  GDriveLocalMirror._({
    required GDriveApiClient client,
    required TypeIndexMappings typeIndexMappings,
    required ResourceLocator resourceLocator,
    required GDriveLocalMirrorConfig config,
    required String spaces,
    required Directory filesDir,
    required File indexFile,
    required _GDriveMirrorIndex index,
    required _GDriveMirrorStore store,
  })  : _client = client,
        _typeIndexMappings = typeIndexMappings,
        _resourceLocator = resourceLocator,
        _config = config,
        _spaces = spaces,
        _filesDir = filesDir,
        _indexFile = indexFile,
        _index = index,
        _store = store {
    _folderNameToType = {
      for (final entry in _typeIndexMappings.typeMappings.entries)
        entry.value.folderName: entry.key,
    };
  }

  static Future<GDriveLocalMirror> initialize({
    required GDriveLocalMirrorConfig config,
    required String userId,
    required String spaces,
    required GDriveApiClient client,
    required Future<TypeIndexMappings> Function(TypeIndexManagerBackend)
        typeIndexMappingsProvider,
    required ResourceLocator resourceLocator,
    required Future<String> Function() appFolderProvider,
  }) async {
    final _rootDir =
        await _resolveRootDir(config: config, userId: userId, spaces: spaces);
    final filesDir = Directory(path.join(_rootDir.path, 'files'));
    final indexFile = File(path.join(_rootDir.path, 'index.json'));

    await filesDir.create(recursive: true);

    final existingIndex = await _loadIndex(indexFile);

    // Streaming pipeline: start downloads while listing is still in progress
    final updatedIndex = existingIndex.copy();
    await _streamingListAndDownload(
      updatedIndex,
      filesDir: filesDir,
      config: config,
      client: client,
      appFolderId: await appFolderProvider(),
      spaces: spaces,
    );

    final index = updatedIndex;
    await _saveIndex(indexFile, index);
    final store = _GDriveMirrorStore(filesDir: filesDir, index: index);
    final TypeIndexManagerBackend backend = GDriveMirrorTypeIndexBackend(
      store: store,
      getOrCreateFolder: ({
        required String folderName,
        required String parentId,
        required String spaces,
      }) =>
          client.getOrCreateFolder(
        folderName: folderName,
        parentId: parentId,
        spaces: spaces,
      ),
      onIndexChanged: () => _saveIndex(indexFile, index),
    );
    final typeIndexMappings = await typeIndexMappingsProvider(backend);
    await _saveIndex(indexFile, index);

    return GDriveLocalMirror._(
      client: client,
      typeIndexMappings: typeIndexMappings,
      resourceLocator: resourceLocator,
      config: config,
      spaces: spaces,
      filesDir: filesDir,
      indexFile: indexFile,
      index: index,
      store: store,
    );
  }

  Future<RemoteDownloadResult<T>> download<T>(
    IriTerm documentIri, {
    String? ifNoneMatch,
    required T Function(String) convert,
  }) async {
    final relativePath = _relativePathForDocument(documentIri);
    final result =
        await _store.download(relativePath, ifNoneMatch: ifNoneMatch);
    if (result.notModified) {
      return RemoteDownloadResult<T>.notModified(etag: result.etag ?? '');
    }
    if (result.graph == null) {
      return RemoteDownloadResult<T>(
          graph: null, etag: null, notModified: false);
    }
    final graph = convert(result.graph!);
    return RemoteDownloadResult<T>(graph: graph, etag: result.etag);
  }

  Future<RemoteUploadResult> upload<T>(IriTerm documentIri, T updatedGraph,
      {String? ifMatch,
      required String Function(T) convert,
      required String contentType}) async {
    final relativePath = _relativePathForDocument(documentIri);
    final content = convert(updatedGraph);
    final bytes = utf8.encode(content);
    return _store.upload(
      relativePath,
      bytes,
      ifMatch: ifMatch,
      contentType: contentType,
    );
  }

  Future<void> finalize() async {
    final dirtyEntries = _index.entries.values.where((e) => e.dirty).toList();
    if (dirtyEntries.isEmpty) return;

    await _runConcurrent(
      dirtyEntries,
      _config.maxConcurrentUploads,
      (entry) async {
        final filePath = _localFilePath(_filesDir, entry.path);
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

    await _saveIndex(_indexFile, _index);
  }

  static Future<Directory> _resolveRootDir(
      {required GDriveLocalMirrorConfig config,
      required String userId,
      required String spaces}) async {
    final rootPath = config.cacheRootPath ?? Directory.systemTemp.path;
    final userSegment = base64Url.encode(utf8.encode(userId));
    final dir = Directory(
        path.join(rootPath, 'locorda_gdrive_cache', userSegment, spaces));
    await dir.create(recursive: true);
    return dir;
  }

  String _relativePathForDocument(IriTerm documentIri) {
    final doc = _resourceLocator.fromIri(documentIri);
    final folderName = _typeIndexMappings.getFolderName(doc.typeIri);
    return path.normalize(path.join(folderName, doc.id));
  }

  static String _localFilePath(Directory filesDir, String relativePath) {
    return path.join(filesDir.path, relativePath);
  }

  static Future<_GDriveMirrorIndex> _loadIndex(File indexFile) async {
    if (!await indexFile.exists()) {
      return _GDriveMirrorIndex.empty();
    }

    try {
      final content = await indexFile.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      return _GDriveMirrorIndex.fromJson(json);
    } catch (e, stackTrace) {
      _mirrorLog.warning(
          'Failed to read mirror index, rebuilding', e, stackTrace);
      return _GDriveMirrorIndex.empty();
    }
  }

  static Future<void> _saveIndex(
      File indexFile, _GDriveMirrorIndex index) async {
    final json = jsonEncode(index.toJson());
    await indexFile.writeAsString(json, flush: true);
  }

  /// Streaming pipeline: list files and download them concurrently as they're discovered.
  ///
  /// This replaces the two-phase approach (list all, then download all) with a
  /// single-pass pipeline that starts downloads immediately when files are found.
  static Future<void> _streamingListAndDownload(
    _GDriveMirrorIndex index, {
    required Directory filesDir,
    required GDriveLocalMirrorConfig config,
    required GDriveApiClient client,
    //_typeIndexMappings.appFolderId
    required String appFolderId,
    required String spaces,
  }) async {
    final downloadQueue = Queue<_GDriveMirrorIndexEntry>();
    final downloadCompleter = Completer<void>();
    final listCompleter = Completer<void>();
    final seenPaths = <String>{};

    var activeDownloads = 0;
    var listingComplete = false;

    // Download worker pool
    Future<void> scheduleDownloads() async {
      while (activeDownloads < config.maxConcurrentDownloads &&
          downloadQueue.isNotEmpty) {
        final entry = downloadQueue.removeFirst();
        activeDownloads++;

        _downloadFile(entry, index, filesDir: filesDir, client: client)
            .whenComplete(() {
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
    _streamListFiles(
        spaces: spaces,
        appFolderId: appFolderId,
        client: client,
        config: config, (remoteEntry) {
      if (remoteEntry.isFolder) return;
      seenPaths.add(remoteEntry.path);

      final existingEntry = index.entries[remoteEntry.path];
      final needsDownload =
          _shouldDownload(remoteEntry, existingEntry, filesDir: filesDir);

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

    _purgeMissingRemoteEntries(index, seenPaths, filesDir: filesDir);
  }

  static void _purgeMissingRemoteEntries(
    _GDriveMirrorIndex index,
    Set<String> seenPaths, {
    required Directory filesDir,
  }) {
    final missingPaths =
        index.entries.keys.where((path) => !seenPaths.contains(path)).toList();
    if (missingPaths.isEmpty) return;

    for (final pathEntry in missingPaths) {
      index.entries.remove(pathEntry);
      final file = File(_localFilePath(filesDir, pathEntry));
      if (file.existsSync()) {
        file.deleteSync();
      }
    }

    _mirrorLog.warning(
      'Removed ${missingPaths.length} local mirror entries missing on remote',
    );
  }

  /// Stream files from Drive API, calling callback for each entry.
  static Future<void> _streamListFiles(void Function(GDriveListedEntry) onEntry,
      {required String spaces,
      required String appFolderId,
      required GDriveApiClient client,
      required GDriveLocalMirrorConfig config}) async {
    final entries = await client.listFilesRecursively(
      rootFolderId: appFolderId,
      spaces: spaces,
      maxConcurrentRequests: config.maxConcurrentListings,
    );
    for (final entry in entries) {
      onEntry(entry);
    }
  }

  static bool _shouldDownload(
    GDriveListedEntry remote,
    _GDriveMirrorIndexEntry? existing, {
    required Directory filesDir,
  }) {
    if (remote.fileId.isEmpty) return false;

    final localFile = File(_localFilePath(filesDir, remote.path));
    if (!localFile.existsSync()) return true;

    if (existing == null) return true;

    final remoteMd5 = remote.md5Checksum;
    if (remoteMd5 != null && remoteMd5 != existing.localMd5) {
      return true;
    }

    return false;
  }

  static Future<void> _downloadFile(
      _GDriveMirrorIndexEntry entry, _GDriveMirrorIndex index,
      {required GDriveApiClient client, required Directory filesDir}) async {
    try {
      final bytes = await client.downloadRawBytes(entry.fileId!);
      final file = File(_localFilePath(filesDir, entry.path));
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

  static String _computeMd5(List<int> bytes) {
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

class GDriveMirrorTypeIndexBackend extends TypeIndexManagerBackend {
  final _GDriveMirrorStore _store;
  final Future<String> Function({
    required String folderName,
    required String parentId,
    required String spaces,
  }) _getOrCreateFolder;
  final Future<void> Function()? _onIndexChanged;

  GDriveMirrorTypeIndexBackend({
    required _GDriveMirrorStore store,
    required Future<String> Function({
      required String folderName,
      required String parentId,
      required String spaces,
    }) getOrCreateFolder,
    Future<void> Function()? onIndexChanged,
  })  : _store = store,
        _getOrCreateFolder = getOrCreateFolder,
        _onIndexChanged = onIndexChanged;

  @override
  Future<({String fileId, String etag})> createFile<T>(
    String fileName,
    T data, {
    required String folderId,
    required String spaces,
    required String contentType,
    required String Function(T) convert,
  }) async {
    final bytes = utf8.encode(convert(data));
    final result = await _store.upload(
      fileName,
      bytes,
      ifMatch: null,
      contentType: contentType,
    );

    if (result is SuccessUploadResult) {
      await _onIndexChanged?.call();
      return (fileId: fileName, etag: result.etag);
    }

    final existing = await _store.download(fileName);
    if (existing.graph == null) {
      throw StateError('Failed to create or read file: $fileName');
    }
    await _onIndexChanged?.call();
    return (fileId: fileName, etag: existing.etag ?? '');
  }

  @override
  Future<({T? graph, String? etag, bool notModified})> download<T>(
    fileId, {
    required T Function(String) convert,
  }) async {
    final result = await _store.download(fileId as String);
    return (
      graph: result.graph == null ? null : convert(result.graph!),
      etag: result.etag,
      notModified: result.notModified,
    );
  }

  @override
  Future<String?> findFile({
    required String fileName,
    required String parentId,
    required String spaces,
  }) async {
    final exists = await _store.exists(fileName);
    return exists ? fileName : null;
  }

  @override
  Future<RemoteUploadResult> upload<T>(
    fileId,
    T updatedGraph, {
    required String ifMatch,
    required String Function(T) convert,
  }) async {
    final bytes = utf8.encode(convert(updatedGraph));
    final result = await _store.upload(
      fileId as String,
      bytes,
      ifMatch: ifMatch,
    );
    await _onIndexChanged?.call();
    return result;
  }

  @override
  Future<String> getOrCreateFolder({
    required String folderName,
    required String parentId,
    required String spaces,
  }) {
    return _getOrCreateFolder(
      folderName: folderName,
      parentId: parentId,
      spaces: spaces,
    );
  }
}

class _GDriveMirrorStore {
  final Directory _filesDir;
  final _GDriveMirrorIndex _index;

  _GDriveMirrorStore({
    required Directory filesDir,
    required _GDriveMirrorIndex index,
  })  : _filesDir = filesDir,
        _index = index;

  Future<RemoteDownloadResult<String>> download(
    String relativePath, {
    String? ifNoneMatch,
  }) async {
    final entry = _index.entries[relativePath];
    final file =
        File(GDriveLocalMirror._localFilePath(_filesDir, relativePath));
    if (!await file.exists()) {
      return RemoteDownloadResult<String>(
        graph: null,
        etag: null,
        notModified: false,
      );
    }

    final currentEtag = entry?.localMd5 ?? await _computeFileMd5(file);
    if (ifNoneMatch != null && ifNoneMatch == currentEtag) {
      return RemoteDownloadResult<String>.notModified(etag: currentEtag);
    }

    final content = await file.readAsString();
    return RemoteDownloadResult<String>(graph: content, etag: currentEtag);
  }

  Future<RemoteUploadResult> upload(
    String relativePath,
    List<int> bytes, {
    String? ifMatch,
    String? contentType,
  }) async {
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

    final newMd5 = GDriveLocalMirror._computeMd5(bytes);
    final file =
        File(GDriveLocalMirror._localFilePath(_filesDir, relativePath));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);

    final updatedEntry =
        (entry ?? _GDriveMirrorIndexEntry.newLocal(relativePath)).copyWith(
      localMd5: newMd5,
      dirty: true,
      contentType: contentType ?? entry?.contentType,
    );

    _index.entries[relativePath] = updatedEntry;
    return RemoteUploadResult.success(newMd5);
  }

  Future<bool> exists(String relativePath) async {
    final file =
        File(GDriveLocalMirror._localFilePath(_filesDir, relativePath));
    return file.exists();
  }

  Future<String> _computeFileMd5(File file) async {
    final bytes = await file.readAsBytes();
    return GDriveLocalMirror._computeMd5(bytes);
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
