import 'dart:async';

import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_gdrive/src/gdrive_backend.dart';

class PerfLogGDriveApiClient implements GDriveApiClient {
  final GDriveApiClient _inner;
  final Perflog _perflog;

  PerfLogGDriveApiClient(this._inner,
      {required Perflog perflog, String name = 'gdrive_api_client'})
      : _perflog = perflog.create(name, _inner);

  @override
  Future<String> getOrCreateFolder(
          {required String folderName,
          String? parentId,
          String spaces = 'drive'}) =>
      _perflog.measure(
          'getOrCreateFolder',
          args: [folderName],
          () => _inner.getOrCreateFolder(
              folderName: folderName, parentId: parentId, spaces: spaces));

  @override
  Future<({String etag, String fileId})> createFile<T>(String filename, T graph,
      {required String folderId,
      bool fileNameMayBeRelativePath = false,
      String spaces = 'drive',
      required String contentType,
      required String Function(T) convert}) {
    return _perflog.measure(
        'createFile',
        args: [filename],
        () => _inner.createFile(filename, graph,
            folderId: folderId,
            fileNameMayBeRelativePath: fileNameMayBeRelativePath,
            spaces: spaces,
            contentType: contentType,
            convert: convert));
  }

  @override
  Future<({String fileId, String md5Checksum})> createFileRaw(
      String filename, List<int> bytes,
      {required String folderId,
      bool fileNameMayBeRelativePath = false,
      String spaces = 'drive',
      required String contentType}) {
    return _perflog.measure(
        'createFileRaw',
        args: [filename],
        () => _inner.createFileRaw(filename, bytes,
            folderId: folderId,
            fileNameMayBeRelativePath: fileNameMayBeRelativePath,
            spaces: spaces,
            contentType: contentType));
  }

  @override
  Future<({String? etag, T? graph, bool notModified})> download<T>(
      String fileId,
      {String? ifNoneMatch,
      required T Function(String) convert}) {
    return _perflog.measure(
        'download',
        args: [fileId],
        () => _inner.download(fileId,
            ifNoneMatch: ifNoneMatch, convert: convert));
  }

  @override
  Future<List<int>> downloadRawBytes(String fileId) {
    return _perflog.measure(
        'downloadRawBytes',
        args: [fileId],
        () => _inner.downloadRawBytes(fileId));
  }

  @override
  Future<String?> findFile(
      {required String fileName,
      required String parentId,
      bool fileNameMayBeRelativePath = false,
      String spaces = 'drive'}) {
    return _perflog.measure(
        'findFile',
        args: [fileName],
        () => _inner.findFile(
            fileName: fileName,
            parentId: parentId,
            fileNameMayBeRelativePath: fileNameMayBeRelativePath,
            spaces: spaces));
  }

  @override
  Future<List<GDriveListedEntry>> listFilesRecursively(
      {required String rootFolderId,
      required String spaces,
      required int maxConcurrentRequests}) {
    return _perflog.measure(
        'listFilesRecursively',
        args: [rootFolderId],
        () => _inner.listFilesRecursively(
            rootFolderId: rootFolderId,
            spaces: spaces,
            maxConcurrentRequests: maxConcurrentRequests));
  }

  @override
  Future<RemoteUploadResult> upload<T>(String fileId, T updatedGraph,
      {required String ifMatch, required String Function(T) convert}) {
    return _perflog.measure(
        'upload',
        args: [fileId],
        () => _inner.upload(fileId, updatedGraph,
            ifMatch: ifMatch, convert: convert));
  }

  @override
  Future<RemoteUploadResult> uploadRaw(String fileId, List<int> bytes,
      {required String ifMatch}) {
    return _perflog.measure(
        'uploadRaw',
        args: [fileId],
        () => _inner.uploadRaw(fileId, bytes, ifMatch: ifMatch));
  }

  @override
  Future<void> dispose() async {
    await _perflog.dispose();
  }
}
