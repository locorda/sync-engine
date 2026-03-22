/// File-based backend for local directory storage.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;
import 'package:rxdart/rxdart.dart';

import '../auth/dir_auth_provider.dart';
import '../rdf/rdf_extensions.dart';

final _log = Logger('DirBackend');

/// File-based backend that stores RDF graphs as Turtle files in a local directory.
///
/// This backend:
/// - Creates/reads files in a local directory
/// - Uses file modification times for ETag generation
/// - Provides offline-first storage with local file access
/// - Primarily for desktop platforms (macOS, Windows, Linux)
class DirBackend implements Backend {
  @override
  String get name => 'local-dir';

  final DirAuthProvider _auth;
  List<RemoteStorage> _remotes = [];
  final RdfCore _rdfCore;
  final String _contentType;
  final String _datasetContentType;
  final bool _useShardDatasets;
  late final BehaviorSubject<List<RemoteStorage>> _remotesChangedSubject;
  final IriTranslator? _iriTranslator;
  final Perflog _perflog;

  DirBackend({
    required DirAuthProvider auth,
    required RdfCore rdfCore,
    required String contentType,
    required String datasetContentType,
    required bool useShardDatasets,
    IriTranslator? iriTranslator,
    required Perflog perflog,
  })  : _auth = auth,
        _rdfCore = rdfCore,
        _contentType = contentType,
        _datasetContentType = datasetContentType,
        _useShardDatasets = useShardDatasets,
        _perflog = perflog,
        _iriTranslator = iriTranslator {
    _remotesChangedSubject = BehaviorSubject<List<RemoteStorage>>();
    _auth.isAuthenticatedNotifier.addListener(_authStateChanged);
    _authStateChanged();
  }

  void _authStateChanged() {
    _log.info('Authentication state changed: '
        'isAuthenticated=${_auth.isAuthenticatedNotifier.isAuthenticated}');

    if (_auth.isAuthenticatedNotifier.isAuthenticated) {
      // Query path from auth provider (type-safe access)
      final syncDirectoryPath = _auth.syncDirectoryPath;

      if (_remotes.length == 1 &&
          _remotes.first is DirRemoteStorage &&
          (_remotes.first as DirRemoteStorage)._directoryPath ==
              syncDirectoryPath) {
        _log.fine('No change in directory remote storage');
        return;
      }

      _log.info('Sync enabled: initializing local directory remote storage');
      _remotes = [
        DirRemoteStorage(
          directoryPath: syncDirectoryPath,
          rdfCore: _rdfCore,
          contentType: _contentType,
          datasetContentType: _datasetContentType,
          useShardDatasets: _useShardDatasets,
          iriTranslator: _iriTranslator,
          perflog: _perflog,
        )
      ];

      // Emit remote change
      _remotesChangedSubject.add(_remotes);
    } else {
      _log.info('Sync disabled: clearing local directory remote storage');
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

/// Remote storage implementation using local directory for file operations.
class DirRemoteStorage implements RemoteStorage {
  final String _directoryPath;
  final RemoteId _remoteId;
  final String _contentType;
  final String _datasetContentType;
  final RdfCore _rdfCore;
  final bool _useShardDatasets;
  final IriTranslator? _iriTranslator;
  final Perflog _perflog;

  DirRemoteStorage({
    required String directoryPath,
    required String contentType,
    required String datasetContentType,
    required RdfCore rdfCore,
    required bool useShardDatasets,
    required IriTranslator? iriTranslator,
    required Perflog perflog,
  })  : _directoryPath = directoryPath,
        _contentType = contentType,
        _datasetContentType = datasetContentType,
        _rdfCore = rdfCore,
        _remoteId = RemoteId('local-dir', directoryPath),
        _useShardDatasets = useShardDatasets,
        _iriTranslator = iriTranslator,
        _perflog = perflog;

  @override
  bool get useShardDatasets => _useShardDatasets;

  @override
  RemoteId get remoteId => _remoteId;

  @override
  Future<bool> isAvailable() async {
    // Check if directory exists and is writable
    try {
      final dir = Directory(_directoryPath);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return true;
    } catch (e, stackTrace) {
      _log.severe('Directory not available: $_directoryPath', e, stackTrace);
      return false;
    }
  }

  @override
  Future<RemoteSyncStorage> createSyncStorage(SyncEngineConfig config) async {
    // Ensure directory exists
    final dir = Directory(_directoryPath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
      _log.info('Created sync directory: $_directoryPath');
    }

    final storage = DirSyncStorage(
      directoryPath: _directoryPath,
      rdfCore: _rdfCore,
      contentType: _contentType,
      datasetContentType: _datasetContentType,
      perflog: _perflog,
    );
    if (_iriTranslator != null) {
      return IriTranslatingRemoteSyncStorage(
          storage: storage, iriTranslator: _iriTranslator);
    }
    return storage;
  }

  @override
  Future<void> dispose() {
    // No resources to dispose for directory storage
    return Future.value();
  }
}

/// Per-sync-session storage for directory backend.
class DirSyncStorage extends RemoteSyncStorage {
  final String _directoryPath;
  final RdfCore _rdfCore;
  final String _contentType;
  final String _datasetContentType;
  final ResourceLocator _resourceLocator;
  final Perflog _perflog;

  /// Tracks parent directories already ensured to exist, avoiding redundant
  /// `Directory.create(recursive: true)` syscalls during bulk uploads.
  final _ensuredDirectories = <String>{};

  DirSyncStorage({
    required String directoryPath,
    required RdfCore rdfCore,
    required String contentType,
    required String datasetContentType,
    required Perflog perflog,
  })  : _directoryPath = directoryPath,
        _rdfCore = rdfCore,
        _contentType = contentType,
        _datasetContentType = datasetContentType,
        _perflog = perflog.create('Backend', 'DirSyncStorage'),
        _resourceLocator =
            LocalResourceLocator(iriTermFactory: IriTerm.validated);

  /// Convert internal document IRI to file path.
  ///
  /// Example: tag:locorda.org,2025:l:Note:abc123 → Note/abc123.ttl
  String _iriToFilePath(IriTerm documentIri, {required bool isDataset}) {
    // Use ResourceLocator to properly extract type and ID
    final identifier = _resourceLocator.fromIri(documentIri);

    // Use simple type name (last segment of type IRI) for folder
    final typeLocalName = identifier.typeIri.localName;

    // Create subdirectory per type
    final relativePath = path.join(
        typeLocalName, '${identifier.id}.${isDataset ? 'trig' : 'ttl'}');
    return path.join(_directoryPath, relativePath);
  }

  /// Generate ETag from file metadata.
  ///
  /// Uses file modification time and size to create a stable identifier.
  String _generateETag(File file) {
    final stat = file.statSync();
    final modified = stat.modified.millisecondsSinceEpoch;
    final size = stat.size;

    // Create hash of modification time and size
    final content = '$modified:$size';
    final hash = md5.convert(utf8.encode(content)).toString();

    return '"$hash"';
  }

  @override
  Future<RemoteDownloadResult<RdfGraph>> download(
    IriTerm documentIri, {
    String? ifNoneMatch,
  }) =>
      _download<RdfGraph>(
        documentIri,
        isDataset: false,
        ifNoneMatch: ifNoneMatch,
        convert: (content) =>
            _rdfCore.decode(content, contentType: _contentType),
      );

  Future<RemoteDownloadResult<RdfDataset>> downloadDataset(
    IriTerm documentIri, {
    String? ifNoneMatch,
  }) =>
      _download<RdfDataset>(
        documentIri,
        isDataset: true,
        ifNoneMatch: ifNoneMatch,
        convert: (content) => _rdfCore.decodeDataset(
          content,
          contentType: _datasetContentType,
        ),
      );

  Future<RemoteDownloadResult<T>> _download<T>(
    IriTerm documentIri, {
    String? ifNoneMatch,
    required T Function(String) convert,
    required bool isDataset,
  }) async {
    final filePath = _iriToFilePath(documentIri, isDataset: isDataset);
    final file = File(filePath);

    _log.fine('Downloading: $filePath, ifNoneMatch: $ifNoneMatch');

    // Check if file exists
    if (!await file.exists()) {
      _log.fine('File not found: $filePath');
      return RemoteDownloadResult(graph: null, etag: null);
    }

    // Generate current ETag
    final currentETag = _generateETag(file);

    // Check for 304 Not Modified
    if (ifNoneMatch != null && ifNoneMatch == currentETag) {
      _log.fine('File not modified: $filePath');
      return RemoteDownloadResult.notModified(etag: currentETag);
    }

    // Read and parse file
    try {
      final content = await file.readAsString();
      final dataset = convert(content);

      _log.fine('Downloaded: $filePath, etag: $currentETag');
      return RemoteDownloadResult(
        graph: dataset,
        etag: currentETag,
      );
    } catch (e, stackTrace) {
      _log.severe('Failed to read file: $filePath', e, stackTrace);
      rethrow;
    }
  }

  @override
  Future<RemoteUploadResult> upload(
    IriTerm documentIri,
    RdfGraph graph, {
    String? ifMatch,
  }) =>
      _upload<RdfGraph>(
        documentIri,
        graph,
        ifMatch: ifMatch,
        isDataset: false,
        convert: (content) =>
            _rdfCore.encode(content, contentType: _contentType),
      );

  @override
  Future<RemoteUploadResult> uploadDataset(
    IriTerm documentIri,
    RdfDataset dataset, {
    String? ifMatch,
  }) =>
      _upload<RdfDataset>(
        documentIri,
        dataset,
        ifMatch: ifMatch,
        isDataset: true,
        convert: (content) => _rdfCore.encodeDataset(
          content,
          contentType: _datasetContentType,
        ),
      );

  Future<RemoteUploadResult> _upload<T>(
    IriTerm documentIri,
    T graph, {
    String? ifMatch,
    required bool isDataset,
    required String Function(T) convert,
  }) async {
    final filePath = _iriToFilePath(documentIri, isDataset: isDataset);
    final file = File(filePath);
    final kind = isDataset ? 'dataset' : 'graph';

    _log.fine('Uploading: $filePath, ifMatch: $ifMatch');

    // Ensure parent directory exists (cached per session)
    final parentPath = file.parent.path;
    if (!_ensuredDirectories.contains(parentPath)) {
      await _perflog.measure(
        '_upload.ensureParentDir',
        () => file.parent.create(recursive: true),
        args: [
          'kind=$kind',
          'type=${_resourceLocator.fromIri(documentIri).typeIri.localName}'
        ],
        minDurationMs: 2,
      );
      _ensuredDirectories.add(parentPath);
    }

    // Check for create-only semantics (ifMatch: null)
    if (ifMatch == null) {
      final exists = await _perflog.measure(
        '_upload.existsCheck',
        () => file.exists(),
        args: ['kind=$kind', 'mode=create'],
        minDurationMs: 2,
      );
      if (exists) {
        _log.fine('File already exists, cannot create: $filePath');
        return RemoteUploadResult.conflict();
      }
    } else {
      // Check for update semantics with ETag validation
      final exists = await _perflog.measure(
        '_upload.existsCheck',
        () => file.exists(),
        args: ['kind=$kind', 'mode=update'],
        minDurationMs: 2,
      );
      if (!exists) {
        _log.fine('File does not exist, cannot update: $filePath');
        return RemoteUploadResult.conflict();
      }

      final currentETag = await _perflog.measure(
        '_upload.computeCurrentEtag',
        () async => _generateETag(file),
        args: ['kind=$kind'],
        minDurationMs: 2,
      );
      if (currentETag != ifMatch) {
        _log.fine(
            'ETag mismatch: $filePath (current: $currentETag, expected: $ifMatch)');
        return RemoteUploadResult.conflict();
      }
    }

    // Write file
    try {
      final content = await _perflog.measure(
        '_upload.convert',
        () async => convert(graph),
        args: [
          'kind=$kind',
          'type=${_resourceLocator.fromIri(documentIri).typeIri.localName}'
        ],
        minDurationMs: 2,
      );

      await _perflog.measure(
        '_upload.writeAsString',
        () => file.writeAsString(content),
        args: ['kind=$kind', 'bytes=${utf8.encode(content).length}'],
        minDurationMs: 2,
      );

      // Generate new ETag
      final newETag = await _perflog.measure(
        '_upload.computeNewEtag',
        () async => _generateETag(file),
        args: ['kind=$kind'],
        minDurationMs: 2,
      );

      _log.fine('Uploaded: $filePath, new etag: $newETag');
      return RemoteUploadResult.success(newETag);
    } catch (e, stackTrace) {
      _log.severe('Failed to write file: $filePath', e, stackTrace);
      rethrow;
    }
  }

  @override
  Future<void> finalizeSync() async {
    // No cleanup needed for file-based storage
  }
}
