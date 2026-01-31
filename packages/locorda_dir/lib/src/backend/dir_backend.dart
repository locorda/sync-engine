/// File-based backend for local directory storage.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;
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

  DirBackend({
    required DirAuthProvider auth,
  }) : _auth = auth {
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
        )
      ];
    } else {
      _log.info('Sync disabled: clearing local directory remote storage');
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

/// Remote storage implementation using local directory for file operations.
class DirRemoteStorage implements RemoteStorage {
  final String _directoryPath;
  final RemoteId _remoteId;

  DirRemoteStorage({
    required String directoryPath,
  })  : _directoryPath = directoryPath,
        _remoteId = RemoteId('local-dir', directoryPath);

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

    return DirSyncStorage(directoryPath: _directoryPath);
  }
}

/// Per-sync-session storage for directory backend.
class DirSyncStorage extends RemoteSyncStorage {
  final String _directoryPath;
  final RdfGraphCodec _codec;
  final ResourceLocator _resourceLocator;

  DirSyncStorage({
    required String directoryPath,
  })  : _directoryPath = directoryPath,
        _codec = TurtleCodec(),
        _resourceLocator =
            LocalResourceLocator(iriTermFactory: IriTerm.validated);

  /// Convert internal document IRI to file path.
  ///
  /// Example: tag:locorda.org,2025:l:Note:abc123 → Note/abc123.ttl
  String _iriToFilePath(IriTerm documentIri) {
    // Use ResourceLocator to properly extract type and ID
    final identifier = _resourceLocator.fromIri(documentIri);

    // Use simple type name (last segment of type IRI) for folder
    final typeLocalName = identifier.typeIri.localName;

    // Create subdirectory per type
    final relativePath = path.join(typeLocalName, '${identifier.id}.ttl');
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
  Future<RemoteDownloadResult> download(
    IriTerm documentIri, {
    String? ifNoneMatch,
  }) async {
    final filePath = _iriToFilePath(documentIri);
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
      final graph = _codec.decode(content);

      _log.fine('Downloaded: $filePath, etag: $currentETag');
      return RemoteDownloadResult(
        graph: graph,
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
  }) async {
    final filePath = _iriToFilePath(documentIri);
    final file = File(filePath);

    _log.fine('Uploading: $filePath, ifMatch: $ifMatch');

    // Ensure parent directory exists
    await file.parent.create(recursive: true);

    // Check for create-only semantics (ifMatch: null)
    if (ifMatch == null) {
      if (await file.exists()) {
        _log.fine('File already exists, cannot create: $filePath');
        return RemoteUploadResult.conflict();
      }
    } else {
      // Check for update semantics with ETag validation
      if (!await file.exists()) {
        _log.fine('File does not exist, cannot update: $filePath');
        return RemoteUploadResult.conflict();
      }

      final currentETag = _generateETag(file);
      if (currentETag != ifMatch) {
        _log.fine(
            'ETag mismatch: $filePath (current: $currentETag, expected: $ifMatch)');
        return RemoteUploadResult.conflict();
      }
    }

    // Write file
    try {
      final content = _codec.encode(graph);
      await file.writeAsString(content);

      // Generate new ETag
      final newETag = _generateETag(file);

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
