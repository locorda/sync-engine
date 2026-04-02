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
class DirBackend implements PipelineBackend {
  @override
  String get name => 'local-dir';

  final DirAuthProvider _auth;
  List<PipelineRemoteStorage> _remotes = [];
  final RdfCore _rdfCore;
  final String _contentType;
  final String _datasetContentType;
  final bool _useShardDatasets;
  late final BehaviorSubject<List<PipelineRemoteStorage>>
      _remotesChangedSubject;
  final IriTranslator? _iriTranslator;
  final Perflog _perflog;
  final ResourceGraphLoader _resourceGraphLoader;

  DirBackend({
    required DirAuthProvider auth,
    required RdfCore rdfCore,
    required String contentType,
    required String datasetContentType,
    required bool useShardDatasets,
    IriTranslator? iriTranslator,
    required Perflog perflog,
    required ResourceGraphLoader resourceGraphLoader,
  })  : _auth = auth,
        _rdfCore = rdfCore,
        _contentType = contentType,
        _datasetContentType = datasetContentType,
        _useShardDatasets = useShardDatasets,
        _perflog = perflog,
        _resourceGraphLoader = resourceGraphLoader,
        _iriTranslator = iriTranslator {
    _remotesChangedSubject = BehaviorSubject<List<PipelineRemoteStorage>>();
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
          resourceGraphLoader: _resourceGraphLoader,
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
  List<PipelineRemoteStorage> get pipelineRemotes => _remotes;

  @override
  Stream<List<PipelineRemoteStorage>> get pipelineRemotesChanged =>
      _remotesChangedSubject.stream;

  @override
  Future<void> dispose() async {
    _auth.isAuthenticatedNotifier.removeListener(_authStateChanged);
    await _remotesChangedSubject.close();
  }
}

/// Remote storage implementation using local directory for file operations.
class DirRemoteStorage implements PipelineRemoteStorage {
  final String _directoryPath;
  final RemoteId _remoteId;
  final String _contentType;
  final String _datasetContentType;
  final RdfCore _rdfCore;
  final bool _useShardDatasets;
  final IriTranslator? _iriTranslator;
  final Perflog _perflog;
  final ResourceGraphLoader _resourceGraphLoader;

  DirRemoteStorage({
    required String directoryPath,
    required String contentType,
    required String datasetContentType,
    required RdfCore rdfCore,
    required bool useShardDatasets,
    required IriTranslator? iriTranslator,
    required Perflog perflog,
    required ResourceGraphLoader resourceGraphLoader,
  })  : _directoryPath = directoryPath,
        _contentType = contentType,
        _datasetContentType = datasetContentType,
        _rdfCore = rdfCore,
        _remoteId = RemoteId('local-dir', directoryPath),
        _useShardDatasets = useShardDatasets,
        _iriTranslator = iriTranslator,
        _perflog = perflog,
        _resourceGraphLoader = resourceGraphLoader;

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
  Future<PipelineRemoteSyncStorage> createPipelineSyncStorage(
      SyncEngineConfig config) async {
    // Ensure directory exists
    final dir = Directory(_directoryPath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
      _log.info('Created sync directory: $_directoryPath');
    }

    final mode =
        RemoteStorageMode.fromFlags(useShardDatasets: useShardDatasets);
    final effectiveContentType =
        useShardDatasets ? _datasetContentType : _contentType;
    final isBinary = isBinaryContentType(effectiveContentType);

    final storage = DirSyncStorage(
      directoryPath: _directoryPath,
      contentType: effectiveContentType,
      perflog: _perflog,
      isBinary: isBinary,
      isDataset: useShardDatasets,
    );

    if (_iriTranslator != null) {
      return RemoteSyncStorages.createIriTranslated(
        backend: storage,
        mode: mode,
        rdfCore: _rdfCore,
        resourceGraphLoader: _resourceGraphLoader,
        contentType: effectiveContentType,
        isBinary: isBinary,
        translator: _iriTranslator,
      );
    }
    return RemoteSyncStorages.create(
        mode: mode,
        backend: storage,
        rdfCore: _rdfCore,
        contentType: effectiveContentType,
        isBinary: isBinary,
        resourceGraphLoader: _resourceGraphLoader);
  }

  @override
  Future<void> dispose() {
    // No resources to dispose for directory storage
    return Future.value();
  }
}

/// Per-sync-session storage for directory backend.
///
/// Implements [RemoteSyncBackend] using raw file I/O. RDF encoding/decoding
/// is handled upstream by the pipeline adapter (FPR or SDS) — this class
/// only reads/writes bytes or text and computes ETags from file metadata.
class DirSyncStorage implements RemoteSyncBackend {
  final String _directoryPath;
  final String _contentType;
  final bool _isBinary;
  final bool _isDataset;
  final ResourceLocator _resourceLocator;
  final Perflog _perflog;

  /// Tracks parent directories already ensured to exist, avoiding redundant
  /// `Directory.create(recursive: true)` syscalls during bulk uploads.
  final _ensuredDirectories = <String>{};

  DirSyncStorage({
    required String directoryPath,
    required String contentType,
    required Perflog perflog,
    required bool isBinary,
    required bool isDataset,
  })  : _directoryPath = directoryPath,
        _contentType = contentType,
        _isBinary = isBinary,
        _isDataset = isDataset,
        _perflog = perflog.create('Backend', 'DirSyncStorage'),
        _resourceLocator =
            LocalResourceLocator(iriTermFactory: IriTerm.validated);

  /// Converts an internal document IRI to a file path.
  ///
  /// Example: tag:locorda.org,2025:l:Note:abc123 → Note/abc123.ttl
  String _iriToFilePath(IriTerm documentIri) {
    final identifier = _resourceLocator.fromIri(documentIri);
    final typeLocalName = identifier.typeIri.localName;
    final ext = _isDataset ? 'trig' : 'ttl';
    return path.join(_directoryPath, typeLocalName, '${identifier.id}.$ext');
  }

  /// Generates an ETag from file modification time and size.
  String _generateETag(File file) {
    final stat = file.statSync();
    final hash = md5
        .convert(
            utf8.encode('${stat.modified.millisecondsSinceEpoch}:${stat.size}'))
        .toString();
    return '"$hash"';
  }

  @override
  Stream<RemoteDownloadResult<RawContent>> download(
      Stream<RemoteDownloadRequest> requests) async* {
    await for (final request in requests) {
      yield await _downloadOne(request);
    }
  }

  Future<RemoteDownloadResult<RawContent>> _downloadOne(
      RemoteDownloadRequest request) async {
    final filePath = _iriToFilePath(request.documentIri);
    final file = File(filePath);

    _log.fine('Downloading: $filePath, ifNoneMatch: ${request.ifNoneMatch}');

    if (!await file.exists()) {
      _log.fine('File not found: $filePath');
      return RemoteDownloadResult(graph: null, etag: null);
    }

    final currentETag = _generateETag(file);

    if (request.ifNoneMatch != null && request.ifNoneMatch == currentETag) {
      _log.fine('File not modified: $filePath');
      return RemoteDownloadResult.notModified(etag: currentETag);
    }

    try {
      final RawContent content;
      if (_isBinary) {
        final bytes = await file.readAsBytes();
        content = BinaryContent(bytes, contentType: _contentType);
      } else {
        final text = await file.readAsString();
        content = TextContent(text, contentType: _contentType);
      }
      _log.fine('Downloaded: $filePath, etag: $currentETag');
      return RemoteDownloadResult(graph: content, etag: currentETag);
    } catch (e, stackTrace) {
      _log.severe('Failed to read file: $filePath', e, stackTrace);
      rethrow;
    }
  }

  @override
  Stream<RemoteUploadResult> upload(
      Stream<RemoteUploadRequest<RawContent>> requests) async* {
    await for (final request in requests) {
      yield await _uploadOne(request);
    }
  }

  Future<RemoteUploadResult> _uploadOne(
      RemoteUploadRequest<RawContent> request) async {
    final filePath = _iriToFilePath(request.documentIri);
    final file = File(filePath);

    _log.fine('Uploading: $filePath, ifMatch: ${request.ifMatch}');

    // Ensure parent directory exists (cached per session)
    final parentPath = file.parent.path;
    if (!_ensuredDirectories.contains(parentPath)) {
      await _perflog.measure(
        '_upload.ensureParentDir',
        () => file.parent.create(recursive: true),
        args: [
          'type=${_resourceLocator.fromIri(request.documentIri).typeIri.localName}'
        ],
        minDurationMs: 2,
      );
      _ensuredDirectories.add(parentPath);
    }

    if (request.ifMatch == null) {
      final exists = await _perflog.measure(
        '_upload.existsCheck',
        () => file.exists(),
        args: ['mode=create'],
        minDurationMs: 2,
      );
      if (exists) {
        _log.fine('File already exists, cannot create: $filePath');
        return RemoteUploadResult.conflict();
      }
    } else {
      final exists = await _perflog.measure(
        '_upload.existsCheck',
        () => file.exists(),
        args: ['mode=update'],
        minDurationMs: 2,
      );
      if (!exists) {
        _log.fine('File does not exist, cannot update: $filePath');
        return RemoteUploadResult.conflict();
      }
      final currentETag = await _perflog.measure(
        '_upload.computeCurrentEtag',
        () async => _generateETag(file),
        minDurationMs: 2,
      );
      if (currentETag != request.ifMatch) {
        _log.fine(
            'ETag mismatch: $filePath (current: $currentETag, expected: ${request.ifMatch})');
        return RemoteUploadResult.conflict();
      }
    }

    try {
      final raw = request.document;
      final bytesCount = raw is BinaryContent
          ? raw.bytes.length
          : utf8.encode((raw as TextContent).text).length;
      await _perflog.measure(
        '_upload.writeFile',
        () async {
          if (raw is BinaryContent) {
            await file.writeAsBytes(raw.bytes);
          } else {
            await file.writeAsString((raw as TextContent).text);
          }
        },
        args: [
          'type=${_resourceLocator.fromIri(request.documentIri).typeIri.localName}',
          'bytes=$bytesCount',
        ],
        minDurationMs: 2,
      );
      final newETag = await _perflog.measure(
        '_upload.computeNewEtag',
        () async => _generateETag(file),
        minDurationMs: 2,
      );
      _log.fine('Uploaded: $filePath, new etag: $newETag');
      return RemoteUploadResult.success(newETag);
    } catch (e, stackTrace) {
      _log.severe('Failed to write file: $filePath', e, stackTrace);
      rethrow;
    }
  }
}
