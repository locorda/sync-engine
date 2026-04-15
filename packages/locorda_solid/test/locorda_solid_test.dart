import 'package:flutter_test/flutter_test.dart';
import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_solid/locorda_solid.dart';
import 'package:locorda_solid/src/solid/shared/solid_config_messages.dart';

void main() {
  test('SolidConfig JSON roundtrip with FilePerResource layout', () {
    const config = SolidConfig(layout: FilePerResource());

    final json = config.toJson();
    final decoded = SolidConfig.fromJson(json);

    expect(decoded.layout, isA<FilePerResource>());
  });

  test('SolidConfig JSON roundtrip with ShardDataset layout', () {
    const config = SolidConfig(layout: ShardDataset());

    final json = config.toJson();
    final decoded = SolidConfig.fromJson(json);

    expect(decoded.layout, isA<ShardDataset>());
  });

  test('SolidConfig fromJson defaults to FilePerResource when layout missing',
      () {
    final decoded = SolidConfig.fromJson(const {});
    expect(decoded.layout, isA<FilePerResource>());
  });

  test('SolidConfigMessage JSON roundtrip', () {
    const config = SolidConfig(layout: ShardDataset());

    final message = SolidConfigMessage(config: config);
    final json = message.toJson();
    final decoded = SolidConfigMessage.fromJson(json).config;

    expect(decoded.layout, isA<ShardDataset>());
  });
}
