/// Shared message types for GDriveConfig synchronization.
library;

import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_rdf_core/core.dart';

import 'gdrive_config.dart';

/// Message to send GDriveConfig from main thread to worker.
class GDriveConfigMessage {
  final GDriveConfig config;

  GDriveConfigMessage({required this.config});

  Map<String, dynamic> toJson() => {
        'type': 'GDriveConfigMessage',
        'folderMode': config.folderMode.name,
        'appFolderName': config.appFolderName,
        'typeFolderNames': config.typeFolderNames
            .map((key, value) => MapEntry(key.value, value)),
        'extraScopes': config.extraScopes,
        'localMirrorConfig': {
          'enabled': config.localMirrorConfig.enabled,
          'cacheRootPath': config.localMirrorConfig.cacheRootPath,
          'maxConcurrentListings':
              config.localMirrorConfig.maxConcurrentListings,
          'maxConcurrentDownloads':
              config.localMirrorConfig.maxConcurrentDownloads,
          'maxConcurrentUploads': config.localMirrorConfig.maxConcurrentUploads,
        },
        'layout': config.layout.toJson(),
      };

  static GDriveConfigMessage fromJson(Map<String, dynamic> json) {
    final folderModeName = json['folderMode'] as String;
    final folderMode = GDriveFolderMode.values.firstWhere(
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

    final mirrorConfigRaw = json['localMirrorConfig'] as Map<String, dynamic>?;
    final mirrorConfig = mirrorConfigRaw == null
        ? const GDriveLocalMirrorConfig()
        : GDriveLocalMirrorConfig(
            enabled: mirrorConfigRaw['enabled'] as bool? ?? false,
            cacheRootPath: mirrorConfigRaw['cacheRootPath'] as String?,
            maxConcurrentListings:
                mirrorConfigRaw['maxConcurrentListings'] as int? ?? 16,
            maxConcurrentDownloads:
                mirrorConfigRaw['maxConcurrentDownloads'] as int? ?? 40,
            maxConcurrentUploads:
                mirrorConfigRaw['maxConcurrentUploads'] as int? ?? 30,
          );

    final layoutRaw = json['layout'] as Map<String, dynamic>?;
    final layout = layoutRaw == null
        ? const ShardDataset()
        : RemoteStorageLayout.fromJson(layoutRaw);

    return GDriveConfigMessage(
      config: folderMode == GDriveFolderMode.appDataFolder
          ? GDriveConfig(
              typeFolderNames: typeFolderNames,
              extraScopes: extraScopes,
              localMirrorConfig: mirrorConfig,
              layout: layout,
            )
          : GDriveConfig.visibleFolder(
              appFolderName: appFolderName!,
              typeFolderNames: typeFolderNames,
              extraScopes: extraScopes,
              localMirrorConfig: mirrorConfig,
              layout: layout,
            ),
    );
  }
}
