/// Mock Locorda implementation for testing.
library;

import 'package:locorda/locorda.dart';

class MockSyncManager extends StandardSyncManager {
  MockSyncManager()
      : super(
          syncFunction: (syncTime) async {},
          configService: SimpleConfigService(SyncEngineConfig(resources: [])),
          physicalTimestampFactory: () => DateTime.now(),
        );
}
