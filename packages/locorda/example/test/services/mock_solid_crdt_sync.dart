/// Mock Locorda implementation for testing.
library;

import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_core/src/sync/standard_sync_manager.dart';

class MockSyncManager extends StandardSyncManager {
  MockSyncManager()
      : super(
          syncFunction: (syncTime) async {},
          autoSyncConfig: const AutoSyncConfig.disabled(),
          physicalTimestampFactory: () => DateTime.now(),
        );
}
