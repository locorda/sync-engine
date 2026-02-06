import 'package:flutter_test/flutter_test.dart';
import 'package:locorda_solid/locorda_solid.dart';
import 'package:locorda_solid/src/solid/shared/solid_config_messages.dart';

void main() {
  test('SolidConfig JSON roundtrip', () {
    const config = SolidConfig(
      maxConcurrentDocumentSyncs: 3,
      maxConcurrentShardSyncs: 2,
      maxConcurrentIndexSyncs: 4,
      useShardDatasets: false,
    );

    final json = config.toJson();
    final decoded = SolidConfig.fromJson(json);

    expect(decoded.maxConcurrentDocumentSyncs, 3);
    expect(decoded.maxConcurrentShardSyncs, 2);
    expect(decoded.maxConcurrentIndexSyncs, 4);
    expect(decoded.useShardDatasets, isFalse);
  });

  test('SolidConfigMessage JSON roundtrip', () {
    const config = SolidConfig(
      maxConcurrentDocumentSyncs: 5,
      maxConcurrentShardSyncs: 6,
      maxConcurrentIndexSyncs: 7,
      useShardDatasets: true,
    );

    final message = SolidConfigMessage(config: config);
    final json = message.toJson();
    final decoded = SolidConfigMessage.fromJson(json).config;

    expect(decoded.maxConcurrentDocumentSyncs, 5);
    expect(decoded.maxConcurrentShardSyncs, 6);
    expect(decoded.maxConcurrentIndexSyncs, 7);
    expect(decoded.useShardDatasets, isTrue);
  });
}
