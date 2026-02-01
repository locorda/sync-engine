/// Shared message types for GDriveConfig synchronization.
library;

import 'package:locorda_rdf_core/core.dart';

import '../gdrive_type_index_manager.dart';

/// Message to send GDriveConfig from main thread to worker.
class GDriveConfigMessage {
  final GDriveSlowConfig config;

  GDriveConfigMessage({required this.config});

  Map<String, dynamic> toJson() => {
        'type': 'GDriveConfigMessage',
        'folderMode': config.folderMode.name,
        'appFolderName': config.appFolderName,
        'typeFolderNames': config.typeFolderNames
            .map((key, value) => MapEntry(key.value, value)),
        'extraScopes': config.extraScopes,
      };

  static GDriveConfigMessage fromJson(Map<String, dynamic> json) {
    final folderModeName = json['folderMode'] as String;
    final folderMode = GDriveSlowFolderMode.values.firstWhere(
      (e) => e.name == folderModeName,
    );

    final appFolderName = json['appFolderName'] as String?;
    final typeFolderNamesRaw = json['typeFolderNames'] as Map<String, dynamic>?;
    final typeFolderNames = typeFolderNamesRaw?.map(
          (key, value) => MapEntry(IriTerm(key), value as String),
        ) ??
        <IriTerm, String>{};
    final extraScopesRaw = json['extraScopes'] as List<dynamic>?;
    final extraScopes = extraScopesRaw?.cast<String>() ?? <String>[];

    return GDriveConfigMessage(
      config: folderMode == GDriveSlowFolderMode.appDataFolder
          ? GDriveSlowConfig(
              typeFolderNames: typeFolderNames,
              extraScopes: extraScopes,
            )
          : GDriveSlowConfig.visibleFolder(
              appFolderName: appFolderName!,
              typeFolderNames: typeFolderNames,
              extraScopes: extraScopes,
            ),
    );
  }
}
