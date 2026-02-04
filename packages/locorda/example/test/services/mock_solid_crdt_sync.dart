/// Mock Locorda implementation for testing.
library;

import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_core/src/sync/standard_sync_manager.dart';
import 'package:locorda_core/src/standard_sync_engine.dart';

class MockSyncManager extends StandardSyncManager {
  MockSyncManager()
      : super(
          syncFunction: (syncTime) async {},
          configService: SimpleConfigService(SyncEngineConfig(resources: [])),
          physicalTimestampFactory: () => DateTime.now(),
        );
}
