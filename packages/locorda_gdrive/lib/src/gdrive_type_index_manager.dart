import 'dart:convert';
import 'dart:nativewrappers/_internal/vm/lib/ffi_allocation_patch.dart';

import 'package:crypto/crypto.dart';
import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_gdrive/src/gdrive_api.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:logging/logging.dart';

import 'rdf/rdf_extensions.dart';
import 'shared/gdrive_config.dart';

final _log = Logger('GDriveTypeIndexManager');

abstract class TypeIndexManagerBackend {
  Future<({String fileId, String etag})> createFile<T>(String s, T emptyGraph,
      {required String folderId,
      required String spaces,
      required String contentType,
      required String Function(T) convert});

  Future<({T? graph, String? etag, bool notModified})> download<T>(fileId,
      {required T Function(String) convert});

  Future<String?> findFile(
      {required String fileName,
      required String parentId,
      required String spaces});

  Future<RemoteUploadResult> upload<T>(fileId, T updatedGraph,
      {required String ifMatch, required String Function(T) convert});

  Future<String> getOrCreateFolder(
      {required String folderName,
      required String parentId,
      required String spaces});
}

class GDriveTypeIndexManagerBackend extends TypeIndexManagerBackend {
  final GDriveApiClient _client;

  GDriveTypeIndexManagerBackend({required GDriveApiClient client})
      : _client = client;

  Future<({String fileId, String etag})> createFile<T>(String s, T emptyGraph,
          {required String folderId,
          required String spaces,
          required String contentType,
          required String Function(T) convert}) =>
      _client.createFile<T>(
        s,
        emptyGraph,
        folderId: folderId,
        spaces: spaces,
        contentType: contentType,
        convert: convert,
      );

  Future<({T? graph, String? etag, bool notModified})> download<T>(fileId,
          {required T Function(String) convert}) =>
      _client.download(fileId, convert: convert);

  Future<String?> findFile(
          {required String fileName,
          required String parentId,
          required String spaces}) =>
      _client.findFile(
        fileName: fileName,
        parentId: parentId,
        spaces: spaces,
      );

  Future<RemoteUploadResult> upload<T>(fileId, T updatedGraph,
          {required String ifMatch, required String Function(T) convert}) =>
      _client.upload(
        fileId,
        updatedGraph,
        ifMatch: ifMatch,
        documentIri: IriTerm.validated('internal:gdrive:$fileId'),
        convert: convert,
      );

  Future<String> getOrCreateFolder(
          {required String folderName,
          required String parentId,
          required String spaces}) =>
      _client.getOrCreateFolder(
        folderName: folderName,
        parentId: parentId,
        spaces: spaces,
      );
}

/// Manages the Type Index file for Google Drive backend.
///
/// The Type Index is a special RDF file (`gdrive-index.ttl`) that maps
/// Locorda resource types to Google Drive folders. It uses the vocabulary
/// defined in `spec/vocabularies/gdrive.ttl`.
///
/// **Concurrency Control:**
/// Uses ETag-based optimistic locking to prevent duplicate TypeMapping entries
/// when multiple installations write concurrently.
///
/// **Protocol (for adding new type):**
/// 1. Read gdrive-index.ttl with ETag
/// 2. Check if TypeMapping for type exists
/// 3. If missing: Add blank node with type mapping
/// 4. Write with If-Match: ETag
/// 5. If conflict (412): Re-read and verify type was added
class GDriveTypeIndexManager {
  final TypeIndexManagerBackend _backend;
  final ResourceLocator _localResourceLocator;
  final GDriveConfig _config;
  final String _contentType = turtle.primaryMimeType;
  final RdfCore _rdfCore;
  final AppFolderProvider _appFolderProvider;

  late final String _spaces =
      _config.folderMode == GDriveFolderMode.appDataFolder
          ? 'appDataFolder'
          : 'drive';

  static final _indexTypes = {
    IdxFullIndex.classIri,
    IdxGroupIndex.classIri,
    IdxGroupIndexTemplate.classIri,
    IdxShard.classIri
  };

  GDriveTypeIndexManager({
    required TypeIndexManagerBackend backend,
    required IriTermFactory iriTermFactory,
    required GDriveConfig config,
    required RdfCore rdfCore,
    required AppFolderProvider appFolderProvider,
  })  : _backend = backend,
        _rdfCore = rdfCore,
        _appFolderProvider = appFolderProvider,
        _config = _fillInDefaults(config),
        _localResourceLocator =
            LocalResourceLocator(iriTermFactory: iriTermFactory);

  /// Load or create the Type Index and ensure all resource types are mapped.
  ///
  /// Returns a map of resource type IRI → folder ID for efficient lookups
  /// during sync operations.
  ///
  /// **Steps:**
  /// 1. Get/create app root folder
  /// 2. Load gdrive-index.ttl (create if missing)
  /// 3. Parse TypeMappings
  /// 4. For each missing type: Add with optimistic locking
  /// 5. Return folder ID mappings
  Future<TypeIndexMappings> loadOrCreateTypeIndex(
    SyncEngineConfig engineConfig,
  ) async {
    _log.info(
        'Loading Type Index for ${engineConfig.resources.length} resource types');

    // Step 1: Get or create app root folder
    final appFolderId = await _appFolderProvider.appFolderId;
    _log.fine('App folder ID: $appFolderId');

    // Step 2: Load or create gdrive-index.ttl
    final typeIndexResult = await _loadOrCreateTypeIndexFile(appFolderId);
    final graph = typeIndexResult.graph;
    _log.fine('Type Index loaded, ETag: ${typeIndexResult.etag}');

    // Step 3: Parse existing TypeMappings
    final typeIndexIri = graph.getIdentifier(GdriveTypeIndex.classIri);
    final existingMappings = _parseTypeMappings(typeIndexIri, graph);
    _log.fine('Found ${existingMappings.length} existing type mappings');

    // Step 4: Add missing types with optimistic locking
    final allTypes = _collectAllTypes(engineConfig);
    final missingTypes = allTypes.where(
      (type) => !existingMappings.containsKey(type),
    );

    if (missingTypes.isNotEmpty) {
      _log.info('Adding ${missingTypes.length} missing type mappings');
      await _addMissingTypes(
        typeIndexIri: typeIndexIri,
        appFolderId: appFolderId,
        existingGraph: typeIndexResult.graph,
        existingETag: typeIndexResult.etag,
        missingTypes: missingTypes,
      );

      // Re-read to get final state with folder IDs
      final updatedResult = await _loadTypeIndexFile(appFolderId);
      if (updatedResult == null) {
        throw StateError('Type Index disappeared after update');
      }
      final updatedMappings =
          _parseTypeMappings(typeIndexIri, updatedResult.graph);
      return TypeIndexMappings(
        appFolderId: appFolderId,
        typeMappings: updatedMappings,
      );
    }

    // Step 5: Return mappings
    return TypeIndexMappings(
      appFolderId: appFolderId,
      typeMappings: existingMappings,
    );
  }

  /// Load or create the gdrive-index.ttl file.
  Future<_TypeIndexFile> _loadOrCreateTypeIndexFile(String appFolderId) async {
    // Try to load existing file
    final existingFile = await _loadTypeIndexFile(appFolderId);
    if (existingFile != null) {
      return existingFile;
    }

    // Create new empty Type Index
    _log.info('Creating new Type Index file');
    final emptyGraph = _createEmptyTypeIndex();

    // Upload to Drive (returns fileId and etag directly)
    final result = await _backend.createFile(
      'gdrive-index.ttl',
      emptyGraph,
      folderId: appFolderId,
      spaces: _spaces,
      contentType: turtle.primaryMimeType,
      convert: (c) => _rdfCore.encode(c, contentType: _contentType),
    );

    _log.info(
        'Created Type Index file: ${result.fileId} with ETag: ${result.etag}');

    return _TypeIndexFile(
      graph: emptyGraph,
      etag: result.etag,
    );
  }

  /// Load existing gdrive-index.ttl file.
  Future<_TypeIndexFile?> _loadTypeIndexFile(String appFolderId) async {
    // Search for gdrive-index.ttl in app folder
    final fileId = await _backend.findFile(
      fileName: 'gdrive-index.ttl',
      parentId: appFolderId,
      spaces: _spaces,
    );

    if (fileId == null) {
      _log.fine('Type Index file not found');
      return null;
    }

    // Download with ETag
    _log.fine('Downloading Type Index file: $fileId');
    final result = await _backend.download(fileId,
        convert: (c) => _rdfCore.decode(
              c,
              contentType: _contentType,
            ));

    if (result.graph == null) {
      throw StateError('Type Index file is empty: $fileId');
    }

    return _TypeIndexFile(
      graph: result.graph!,
      etag: result.etag ?? '',
    );
  }

  /// Create an empty Type Index graph.
  RdfGraph _createEmptyTypeIndex() {
    final typeIndexIri = _localResourceLocator.toIri(
      ResourceIdentifier.document(
        GdriveTypeIndex.rdfType,
        'gdrive-index',
      ),
    );

    return RdfGraph.fromTriples({
      Triple(
        typeIndexIri,
        GdriveTypeIndex.rdfType,
        GdriveTypeIndex.classIri,
      ),
    });
  }

  /// Parse TypeMappings from Type Index graph.
  ///
  /// Returns map: type IRI → TypeMapping with folder ID and name.
  Map<IriTerm, TypeMapping> _parseTypeMappings(
      IriTerm typeIndexIri, RdfGraph graph) {
    final result = <IriTerm, TypeMapping>{};
    final typeMappingSubjects = graph.getMultiValueObjects<RdfSubject>(
        typeIndexIri, GdriveTypeIndex.hasTypeMapping);

    // Find all TypeMapping blank nodes
    for (final typeMappingSubject in typeMappingSubjects) {
      // Get forType
      final typeIri = graph.expectSingleObject<IriTerm>(
        typeMappingSubject,
        GdriveTypeMapping.forType,
      );
      final folderId = graph
          .expectSingleObject<LiteralTerm>(
              typeMappingSubject, GdriveTypeMapping.driveFolderId)
          ?.value;
      final folderName = graph
          .expectSingleObject<LiteralTerm>(
              typeMappingSubject, GdriveTypeMapping.driveFolder)
          ?.value;

      if (typeIri != null && folderId != null && folderName != null) {
        result[typeIri] = TypeMapping(
          folderId: folderId,
          folderName: folderName,
        );
      }
    }

    return result;
  }

  /// Collect all resource types that need mappings.
  ///
  /// Includes:
  /// - All configured resource types from SyncEngineConfig - this includes framework types like installation and index types
  Set<IriTerm> _collectAllTypes(SyncEngineConfig engineConfig) =>
      {...engineConfig.resources.map((r) => r.typeIri), Sync.SyncFile};

  /// Add missing type mappings with optimistic locking.
  ///
  /// Creates folders for all missing types, then adds TypeMappings to the
  /// Type Index with complete folder information (ID and name).
  ///
  /// Retries up to [maxRetries] times on conflict (default: 5).
  /// Throws [StateError] if types cannot be added after all retries.
  Future<void> _addMissingTypes({
    required IriTerm typeIndexIri,
    required String appFolderId,
    required RdfGraph existingGraph,
    required String existingETag,
    required Iterable<IriTerm> missingTypes,
    int retryCount = 0,
    int maxRetries = 5,
  }) async {
    if (retryCount >= maxRetries) {
      throw StateError(
        'Failed to add type mappings after $maxRetries retries. '
        'Still missing: ${missingTypes.map((t) => t.value).join(", ")}',
      );
    }

    _log.fine(
        'Adding ${missingTypes.length} missing types with optimistic locking '
        '(attempt ${retryCount + 1}/$maxRetries)');

    // Step 1: Extract already used folder names from existing graph
    final existingMappings = _parseTypeMappings(typeIndexIri, existingGraph);
    final alreadyUsedNames =
        existingMappings.values.map((mapping) => mapping.folderName).toSet();

    // Step 2: Create folders for all missing types (sequentially)
    final typeFolderMappings = await _createFoldersForTypes(
      appFolderId,
      missingTypes,
      alreadyUsedNames: alreadyUsedNames,
    );

    // Step 3: Create updated graph with complete TypeMappings (including folder IDs)
    final updatedGraph = _addTypeMappingsToDataset(
      typeIndexIri,
      existingGraph,
      typeFolderMappings,
    );

    // Step 4: Find Type Index file ID
    final fileId = await _backend.findFile(
      fileName: 'gdrive-index.ttl',
      parentId: appFolderId,
      spaces: _spaces,
    );

    if (fileId == null) {
      throw StateError('Type Index file disappeared during update');
    }

    // Step 5: Upload with If-Match: existingETag (optimistic locking)
    try {
      final uploadResult = await _backend.upload(
        fileId,
        updatedGraph,
        ifMatch: existingETag,
        convert: (content) =>
            _rdfCore.encode(content, contentType: _contentType),
      );

      switch (uploadResult) {
        case SuccessUploadResult():
          _log.info('Successfully added ${missingTypes.length} type mappings');
          return;
        case ConflictUploadResult():
          _log.warning('412 Conflict - Type Index was modified concurrently');
        // Fall through to conflict handling
        case ErrorUploadResult(:final error, :final stackTrace):
          Error.throwWithStackTrace(error, stackTrace);
      }
    } catch (e) {
      if (e is GDriveClientException && e.message.contains('412')) {
        _log.warning('412 Conflict - Type Index was modified concurrently');
        // Fall through to conflict handling
      } else {
        rethrow;
      }
    }

    // Handle 412 Conflict: Re-read and verify
    _log.fine('Re-reading Type Index after conflict');
    final updatedFile = await _loadTypeIndexFile(appFolderId);
    if (updatedFile == null) {
      throw StateError('Type Index disappeared after conflict');
    }

    final currentMappings = _parseTypeMappings(typeIndexIri, updatedFile.graph);
    final stillMissing = missingTypes.where(
      (type) => !currentMappings.containsKey(type),
    );

    if (stillMissing.isEmpty) {
      _log.info('All types were added by concurrent write - no retry needed');
      return;
    }

    // Some types still missing - retry with new ETag
    _log.info('Retrying add for ${stillMissing.length} still-missing types');
    await _addMissingTypes(
      typeIndexIri: typeIndexIri,
      appFolderId: appFolderId,
      existingGraph: updatedFile.graph,
      existingETag: updatedFile.etag,
      missingTypes: stillMissing,
      retryCount: retryCount + 1,
      maxRetries: maxRetries,
    );
  }

  /// Create folders for types, handling name collisions.
  ///
  /// Returns a map of type IRI → (folderId, folderName).
  /// Processes configured types first, then unconfigured types alphabetically.
  ///
  /// [alreadyUsedNames] contains folder names already in use from existing
  /// TypeMappings to prevent collisions during retry scenarios.
  Future<Map<IriTerm, ({String folderId, String folderName})>>
      _createFoldersForTypes(
    String appFolderId,
    Iterable<IriTerm> types, {
    Set<String> alreadyUsedNames = const {},
  }) async {
    final result = <IriTerm, ({String folderId, String folderName})>{};
    final usedFolderNames = <String>{...alreadyUsedNames};

    // Sort: configured types first, then alphabetically by IRI value
    final sortedTypes = _sortTypesForProcessing(types);

    for (final type in sortedTypes) {
      final folderName = _determineFolderName(type, usedFolderNames);
      usedFolderNames.add(folderName);

      final folderId = await _backend.getOrCreateFolder(
        folderName: folderName,
        parentId: appFolderId,
        spaces: _spaces,
      );

      result[type] = (folderId: folderId, folderName: folderName);
      _log.fine(
          'Created/found folder "$folderName" (id: $folderId) for type: ${type.value}');
    }

    return result;
  }

  /// Sort types for processing: configured first, then alphabetically.
  List<IriTerm> _sortTypesForProcessing(Iterable<IriTerm> types) {
    final configured = <IriTerm>[];
    final unconfigured = <IriTerm>[];

    for (final type in types) {
      if (_config.typeFolderNames.containsKey(type)) {
        configured.add(type);
      } else {
        unconfigured.add(type);
      }
    }

    // Sort unconfigured alphabetically by IRI value
    unconfigured.sort((a, b) => a.value.compareTo(b.value));
    configured.sort((a, b) => a.value.compareTo(b.value));

    return [...configured, ...unconfigured];
  }

  /// Determine folder name for a type, resolving collisions.
  ///
  /// - Configured names are used as-is (no collision check)
  /// - Index types share "indices" folder
  /// - Auto-generated names get suffix if collision detected
  String _determineFolderName(IriTerm type, Set<String> usedNames) {
    // 1. Check explicit configuration first
    final configured = _config.typeFolderNames[type];
    if (configured != null) {
      return configured; // No collision check for configured names
    }

    // 3. Generate from IRI
    final baseName = _extractFolderNameFromIri(type);

    // 4. Check for collision
    if (!usedNames.contains(baseName)) {
      return baseName;
    }

    // 5. Resolve collision with suffix
    int suffix = 2;
    while (usedNames.contains('$baseName-$suffix')) {
      suffix++;
    }

    final resolvedName = '$baseName-$suffix';
    _log.warning(
        'Folder name collision for ${type.value}: using "$resolvedName" instead of "$baseName"');
    return resolvedName;
  }

  /// Extract folder name from IRI (fragment or local name).
  String _extractFolderNameFromIri(IriTerm type) {
    final fragment = type.fragment;
    if (fragment.isNotEmpty) return fragment;

    final localName = type.localName;
    if (localName.isNotEmpty) return localName;

    // Fallback: use md5 hash of IRI
    return 'type-${md5.convert(utf8.encode(type.value)).toString()}';
  }

  /// Add TypeMapping blank nodes with complete folder information.
  RdfGraph _addTypeMappingsToDataset(
    IriTerm typeIndexIri,
    RdfGraph existingGraph,
    Map<IriTerm, ({String folderId, String folderName})> typeFolderMappings,
  ) {
    final newTriples = <Triple>{...existingGraph.triples};

    // Add TypeMapping for each type with complete folder info
    for (final entry in typeFolderMappings.entries) {
      final type = entry.key;
      final mapping = entry.value;
      final mappingNode = BlankNodeTerm(); // Generate unique blank node

      // TypeIndex hasTypeMapping _:mapping
      newTriples.add(Triple(
        typeIndexIri,
        GdriveTypeIndex.hasTypeMapping,
        mappingNode,
      ));

      // _:mapping rdf:type gdrive:TypeMapping
      newTriples.add(Triple(
        mappingNode,
        GdriveTypeMapping.rdfType,
        GdriveTypeMapping.classIri,
      ));

      // _:mapping gdrive:forType <type>
      newTriples.add(Triple(
        mappingNode,
        GdriveTypeMapping.forType,
        type,
      ));

      // _:mapping gdrive:driveFolder "folder-name"
      newTriples.add(Triple(
        mappingNode,
        GdriveTypeMapping.driveFolder,
        LiteralTerm(mapping.folderName),
      ));

      // _:mapping gdrive:driveFolderId "folder-id"
      newTriples.add(Triple(
        mappingNode,
        GdriveTypeMapping.driveFolderId,
        LiteralTerm(mapping.folderId),
      ));
    }

    return RdfGraph.fromTriples(newTriples);
  }

  static GDriveConfig _fillInDefaults(GDriveConfig config) {
    if (_indexTypes.every((it) => config.typeFolderNames.containsKey(it))) {
      return config;
    }
    return config.copyWith(
      typeFolderNames: {
        ...config.typeFolderNames,
        for (final it in _indexTypes)
          if (!config.typeFolderNames.containsKey(it)) it: 'indices',
      },
    );
  }
}

class AppFolderProvider {
  final GDriveApiClient _client;
  final GDriveConfig _config;

  late final Future<String> appFolderId = _getOrCreateAppFolder();

  AppFolderProvider({
    required GDriveApiClient client,
    required GDriveConfig config,
  })  : _client = client,
        _config = config;

  /// Get or create the app root folder in Google Drive.
  ///
  /// Returns:
  /// - 'appDataFolder' (reserved alias) for appDataFolder mode
  /// - Actual folder ID for visibleFolder mode
  Future<String> _getOrCreateAppFolder() async {
    switch (_config.folderMode) {
      case GDriveFolderMode.appDataFolder:
        _log.fine('Using appDataFolder (private app-specific space)');
        return 'appDataFolder'; // Reserved Google Drive alias

      case GDriveFolderMode.visibleFolder:
        _log.fine(
            'Getting or creating visible folder: ${_config.appFolderName}');
        return await _client.getOrCreateFolder(
          folderName: _config.appFolderName!,
          spaces: 'drive',
        );
    }
  }
}

/// Result of loading the Type Index file.
class _TypeIndexFile {
  final RdfGraph graph;
  final String etag;

  _TypeIndexFile({
    required this.graph,
    required this.etag,
  });
}

/// Mapping of a resource type to its Google Drive folder.
class TypeMapping {
  /// Google Drive folder ID
  final String folderId;

  /// Folder name (for logging/debugging)
  final String folderName;

  const TypeMapping({
    required this.folderId,
    required this.folderName,
  });
}

/// Type Index mappings for efficient lookup during sync.
class TypeIndexMappings {
  /// App root folder ID in Google Drive
  final String appFolderId;

  /// Map of resource type IRI → TypeMapping
  final Map<IriTerm, TypeMapping> typeMappings;

  TypeIndexMappings({
    required this.appFolderId,
    required this.typeMappings,
  });

  /// Get folder ID for a resource type.
  ///
  /// Throws [StateError] if type is not mapped.
  String getFolderId(IriTerm type) {
    final mapping = typeMappings[type];
    if (mapping == null) {
      throw StateError('No folder mapping for type: ${type.value}');
    }
    return mapping.folderId;
  }

  /// Get folder name for a resource type.
  ///
  /// Throws [StateError] if type is not mapped.
  String getFolderName(IriTerm type) {
    final mapping = typeMappings[type];
    if (mapping == null) {
      throw StateError('No folder mapping for type: ${type.value}');
    }
    return mapping.folderName;
  }
}
