import 'package:flutter_test/flutter_test.dart';
import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_gdrive/src/shared/gdrive_config.dart';
import 'package:locorda_gdrive/src/shared/gdrive_config_messages.dart';

void main() {
  test('GDriveConfigMessage round-trips shard dataset layout', () {
    final message = GDriveConfigMessage(
      config: const GDriveConfig(
        layout: ShardDataset(contentType: 'application/trig'),
      ),
    );

    final decoded = GDriveConfigMessage.fromJson(message.toJson()).config;

    expect(decoded.layout, isA<ShardDataset>());
    expect(decoded.layout.contentType, 'application/trig');
  });

  test('GDriveConfigMessage round-trips visible single-file layout', () {
    final message = GDriveConfigMessage(
      config: const GDriveConfig.visibleFolder(
        appFolderName: 'Locorda',
        layout: SingleFile(contentType: 'application/x-jelly-rdf'),
      ),
    );

    final decoded = GDriveConfigMessage.fromJson(message.toJson()).config;

    expect(decoded.folderMode, GDriveFolderMode.visibleFolder);
    expect(decoded.appFolderName, 'Locorda');
    expect(decoded.layout, isA<SingleFile>());
    expect(decoded.layout.contentType, 'application/x-jelly-rdf');
  });
}
