import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_gdrive/src/gdrive_backend.dart';
import 'package:locorda_gdrive/src/gdrive_type_index_manager.dart';
import 'package:locorda_gdrive/src/shared/gdrive_config.dart';
import 'package:locorda_rdf_core/core.dart';

class _FakeRemoteFile {
  _FakeRemoteFile({
    required this.fileId,
    required this.bytes,
    required this.path,
  }) : md5Checksum = md5.convert(bytes).toString();

  final String fileId;
  final String path;
  List<int> bytes;
  String md5Checksum;
}

class FakeGDriveClient implements GDriveApiClient {
  FakeGDriveClient(this.rdfCore);

  @override
  final RdfCore rdfCore;

  final Map<String, _FakeRemoteFile> filesById = {};
  final List<GDriveListedEntry> listedEntries = [];
  int _nextId = 0;

  @override
  Future<List<GDriveListedEntry>> listFilesRecursively({
    required String rootFolderId,
    required String spaces,
    required int maxConcurrentRequests,
  }) async {
    return listedEntries;
  }

  @override
  Future<List<int>> downloadRawBytes(String fileId) async {
    final file = filesById[fileId];
    if (file == null) throw StateError('Missing file: $fileId');
    return file.bytes;
  }

  @override
  Future<({String fileId, String md5Checksum})> createFileRaw(
    String filename,
    List<int> bytes, {
    required String folderId,
    bool fileNameMayBeRelativePath = false,
    String spaces = 'drive',
  }) async {
    final id = 'new-${_nextId++}';
    final path = filename;
    final file = _FakeRemoteFile(fileId: id, bytes: bytes, path: path);
    filesById[id] = file;
    listedEntries.add(GDriveListedEntry(
      fileId: id,
      path: path,
      isFolder: false,
      md5Checksum: file.md5Checksum,
      headRevisionId: 'rev-$id',
      version: '1',
    ));
    return (fileId: id, md5Checksum: file.md5Checksum);
  }

  @override
  Future<RemoteUploadResult> uploadRaw(
    String fileId,
    List<int> bytes, {
    required String ifMatch,
  }) async {
    final file = filesById[fileId];
    if (file == null) throw StateError('Missing file: $fileId');
    if (file.md5Checksum != ifMatch) {
      return RemoteUploadResult.conflict();
    }
    file.bytes = bytes;
    file.md5Checksum = md5.convert(bytes).toString();
    return RemoteUploadResult.success(file.md5Checksum);
  }

  @override
  Future<RemoteUploadResult> upload(
    String fileId,
    RdfGraph updatedGraph, {
    required String ifMatch,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<({RdfGraph? graph, String? etag, bool notModified})> download(
    String fileId, {
    String? ifNoneMatch,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<String?> findFile({
    required String fileName,
    required String parentId,
    bool fileNameMayBeRelativePath = false,
    String spaces = 'drive',
  }) {
    throw UnimplementedError();
  }

  @override
  Future<String> getOrCreateFolder({
    required String folderName,
    String? parentId,
    String spaces = 'drive',
  }) {
    throw UnimplementedError();
  }

  @override
  Future<({String fileId, String etag})> createFile(
    String filename,
    RdfGraph graph, {
    required String folderId,
    bool fileNameMayBeRelativePath = false,
    String spaces = 'drive',
  }) {
    throw UnimplementedError();
  }
}

void main() {
  test('GDriveLocalMirror initializes cache and serves local downloads',
      () async {
    final rdfCore =
        RdfCore.withStandardCodecs(iriTermFactory: IriTerm.validated);
    final client = FakeGDriveClient(rdfCore);

    final typeIri = IriTerm.validated('https://example.com/Note');
    final locator = LocalResourceLocator(iriTermFactory: IriTerm.validated);
    final docIri =
        locator.toIri(ResourceIdentifier.document(typeIri, 'note-1'));

    final graph = RdfGraph(triples: {
      Triple(
        docIri,
        IriTerm.validated('https://example.com/predicate'),
        LiteralTerm.string('value'),
      ),
    });
    final bytes = utf8.encode(rdfCore.encode(graph));
    final md5Checksum = md5.convert(bytes).toString();

    final fileId = 'file-1';
    client.filesById[fileId] =
        _FakeRemoteFile(fileId: fileId, bytes: bytes, path: 'Note/note-1');
    client.listedEntries.add(GDriveListedEntry(
      fileId: fileId,
      path: 'Note/note-1',
      isFolder: false,
      md5Checksum: md5Checksum,
      headRevisionId: 'rev-1',
      version: '1',
    ));

    final tempDir = await Directory.systemTemp.createTemp('gdrive-mirror-test');
    final mirrorConfig = GDriveLocalMirrorConfig(
      cacheRootPath: tempDir.path,
      maxConcurrentDownloads: 4,
      maxConcurrentListings: 2,
      maxConcurrentUploads: 2,
    );

    final mirror = GDriveLocalMirror(
      client: client,
      typeIndexMappings: TypeIndexMappings(
        appFolderId: 'root',
        typeMappings: {
          typeIri: const TypeMapping(folderId: 'folder-1', folderName: 'Note'),
        },
      ),
      resourceLocator: locator,
      config: mirrorConfig,
      spaces: 'drive',
      userId: 'user-1',
    );

    await mirror.initialize();

    final download = await mirror.download(docIri);
    expect(download.graph, isNotNull);
    expect(download.etag, md5Checksum);

    final mirrorIndex = File(
      '${tempDir.path}/locorda_gdrive_cache/${base64Url.encode(utf8.encode('user-1'))}/drive/index.json',
    );
    expect(await mirrorIndex.exists(), isTrue);
  });

  test('GDriveLocalMirror uploads locally and finalizes remote updates',
      () async {
    final rdfCore =
        RdfCore.withStandardCodecs(iriTermFactory: IriTerm.validated);
    final client = FakeGDriveClient(rdfCore);

    final typeIri = IriTerm.validated('https://example.com/Note');
    final locator = LocalResourceLocator(iriTermFactory: IriTerm.validated);
    final docIri =
        locator.toIri(ResourceIdentifier.document(typeIri, 'note-2'));

    final graph = RdfGraph(triples: {
      Triple(
        docIri,
        IriTerm.validated('https://example.com/predicate'),
        LiteralTerm.string('value'),
      ),
    });
    final bytes = utf8.encode(rdfCore.encode(graph));
    final md5Checksum = md5.convert(bytes).toString();

    final fileId = 'file-2';
    client.filesById[fileId] =
        _FakeRemoteFile(fileId: fileId, bytes: bytes, path: 'Note/note-2');
    client.listedEntries.add(GDriveListedEntry(
      fileId: fileId,
      path: 'Note/note-2',
      isFolder: false,
      md5Checksum: md5Checksum,
      headRevisionId: 'rev-2',
      version: '1',
    ));

    final tempDir = await Directory.systemTemp.createTemp('gdrive-mirror-test');
    final mirrorConfig = GDriveLocalMirrorConfig(
      cacheRootPath: tempDir.path,
    );

    final mirror = GDriveLocalMirror(
      client: client,
      typeIndexMappings: TypeIndexMappings(
        appFolderId: 'root',
        typeMappings: {
          typeIri: const TypeMapping(folderId: 'folder-1', folderName: 'Note'),
        },
      ),
      resourceLocator: locator,
      config: mirrorConfig,
      spaces: 'drive',
      userId: 'user-2',
    );

    await mirror.initialize();

    final updatedGraph = RdfGraph(triples: {
      Triple(
        docIri,
        IriTerm.validated('https://example.com/predicate'),
        LiteralTerm.string('updated'),
      ),
    });

    final uploadResult =
        await mirror.upload(docIri, updatedGraph, ifMatch: md5Checksum);
    expect(uploadResult, isA<SuccessUploadResult>());

    await mirror.finalize();

    final remoteFile = client.filesById[fileId]!;
    final updatedMd5 = md5.convert(remoteFile.bytes).toString();
    expect(updatedMd5, isNot(md5Checksum));
  });
}
