import 'package:locorda_rdf_core/core.dart';

import 'gdrive_type_index_manager.dart';

/// Abstracts where on Google Drive each document type is stored.
///
/// The strategy determines folder IDs and names per resource type, enabling
/// layout-specific backends to be ignorant of whether a type index exists.
abstract interface class GDriveFolderStrategy {
  String get appFolderId;

  /// Returns the Drive folder ID for uploading/downloading [typeIri] documents.
  String folderIdFor(IriTerm typeIri);

  /// Returns the relative folder name used for local mirror paths.
  ///
  /// An empty string means documents reside directly in the app root.
  String folderNameFor(IriTerm typeIri);

  /// Reverse lookup: folder name → resource type IRI.
  ///
  /// Returns null for strategies without per-type folder organization
  /// (e.g. [AppRootFolderStrategy]).
  IriTerm? typeForFolderName(String folderName);
}

/// All documents stored directly in the app root folder — no subfolders.
///
/// Used for [SingleFile] and [ShardDataset] layouts where type-based folder
/// organization adds no value.
class AppRootFolderStrategy implements GDriveFolderStrategy {
  @override
  final String appFolderId;

  const AppRootFolderStrategy({required this.appFolderId});

  @override
  String folderIdFor(IriTerm typeIri) => appFolderId;

  @override
  String folderNameFor(IriTerm typeIri) => '';

  @override
  IriTerm? typeForFolderName(String folderName) => null;
}

/// Type-based folder organization via the GDrive type index file.
///
/// Used for [FilePerResource] layout where each resource type has its own
/// Drive subfolder, mapped via the `gdrive-index.ttl` type index.
class TypeIndexFolderStrategy implements GDriveFolderStrategy {
  final TypeIndexMappings _mappings;
  late final Map<String, IriTerm> _folderNameToType;

  TypeIndexFolderStrategy(TypeIndexMappings mappings) : _mappings = mappings {
    _folderNameToType = {
      for (final entry in mappings.typeMappings.entries)
        entry.value.folderName: entry.key,
    };
  }

  @override
  String get appFolderId => _mappings.appFolderId;

  @override
  String folderIdFor(IriTerm typeIri) => _mappings.getFolderId(typeIri);

  @override
  String folderNameFor(IriTerm typeIri) => _mappings.getFolderName(typeIri);

  @override
  IriTerm? typeForFolderName(String folderName) =>
      _folderNameToType[folderName];
}
