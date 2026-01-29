@TestOn('vm') // Only run on native platforms
import 'dart:async';

import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_worker/worker.dart';
import 'package:locorda_worker/src/main/native_worker_handle.dart';
import 'package:test/test.dart';

Future<WorkerParams> _setupWorker() async {
  return WorkerParams(
    remotes: [],
    storage: InMemoryStorageWorkerHandler(),
  );
}

SyncEngineConfig _createTestConfig() {
  return SyncEngineConfig(resources: []);
}

void main() {
  group('NativeWorkerHandle', () {
    test('creates worker successfully', () async {
      final worker = await NativeWorkerHandle.create(
        _setupWorker,
        _createTestConfig().toJson(),
        'test-worker',
        (_) async {}, // No plugins
      );

      expect(worker, isA<NativeWorkerHandle>());

      await worker.dispose();
    });

    test('exposes messages stream', () async {
      final worker = await NativeWorkerHandle.create(
        _setupWorker,
        _createTestConfig().toJson(),
        'test-worker',
        (_) async {}, // No plugins
      );

      // Verify stream is available (don't listen yet - isolate already does)
      expect(worker.messages, isA<Stream<Object?>>());

      await worker.dispose();
    });

    test('can send messages', () async {
      final worker = await NativeWorkerHandle.create(
        _setupWorker,
        _createTestConfig().toJson(),
        'test-worker',
        (_) async {}, // No plugins
      );
      final pluginHandle =
          worker.mainHandlerContext.createChannel('test-channel');
      // Send test channel messages (won't be deserialized by framework)
      // Using __channel marker so worker treats them as app-specific messages
      pluginHandle.send('test-message-1');
      pluginHandle.send('test-message-2');
      pluginHandle.send('test-message-3');

      // Give isolate time to process
      await Future.delayed(const Duration(milliseconds: 50));

      await worker.dispose();
    });

    test('disposes cleanly', () async {
      final worker = await NativeWorkerHandle.create(
        _setupWorker,
        _createTestConfig().toJson(),
        'test-worker',
        (_) async {}, // No plugins
      );

      // Should not throw
      await worker.dispose();
    });

    test('can create multiple workers', () async {
      final worker1 = await NativeWorkerHandle.create(
        _setupWorker,
        _createTestConfig().toJson(),
        'worker-1',
        (_) async {}, // No plugins
      );
      final worker2 = await NativeWorkerHandle.create(
        _setupWorker,
        _createTestConfig().toJson(),
        'worker-2',
        (_) async {}, // No plugins
      );

      expect(worker1, isA<NativeWorkerHandle>());
      expect(worker2, isA<NativeWorkerHandle>());
      expect(worker1, isNot(same(worker2)));

      await worker1.dispose();
      await worker2.dispose();
    });
  });
}
