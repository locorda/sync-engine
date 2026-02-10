import 'dart:async';
import 'dart:isolate';

import '../shared/worker_params.dart';
// the native_worker_handle will spawn a native isolate and start the actual worker within,
// so we need to cross main/worker boundary here in order to kickstart the worker isolate.
import '../worker/worker_entry_point.dart' show startWorkerIsolate;
import 'locorda_worker.dart';

/// Message sent to isolate entry point with factory function.
class _IsolateStartMessage {
  final SendPort sendPort;
  final WorkerSetup workerSetup;
  final void Function()? onWorkerSpawn;

  _IsolateStartMessage(this.sendPort, this.workerSetup, {this.onWorkerSpawn});
}

/// Native platform implementation using Dart isolates.
class NativeWorkerHandle implements LocordaWorker {
  final SendPort _sendPort;
  final ReceivePort _receivePort;
  final Isolate _isolate;
  final StreamController<Object?> _controller;
  late MainHandlerContext mainHandlerContext = MainHandlerContextImpl(this);

  NativeWorkerHandle._internal(
    this._sendPort,
    this._receivePort,
    this._isolate,
    this._controller,
  );

  /// Creates worker by spawning isolate with plugin support.
  ///
  /// Execution order guarantees plugins are ready before worker starts:
  /// 1. Spawn worker isolate (creates communication channel)
  /// 2. Caller initializes plugins via callback (sets up listeners)
  /// 3. Send config to worker (triggers engine initialization)
  /// 4. Wait for 'ready' (worker has created SyncEngine)
  static Future<NativeWorkerHandle> create(
    WorkerSetup workerSetup,
    Map<String, dynamic> configJson,
    String? debugName,
    String activeStorageId,
    List<String> activeRemoteIds,
    Future<void> Function(NativeWorkerHandle handle) initializePlugins, {
    void onWorkerSpawn()?,
  }) async {
    // 1. Spawn isolate
    final receivePort = ReceivePort();
    final isolate = await Isolate.spawn(
      _isolateEntryPoint,
      _IsolateStartMessage(receivePort.sendPort, workerSetup,
          onWorkerSpawn: onWorkerSpawn),
      debugName: debugName,
    );

    final sendPortCompleter = Completer<SendPort>();
    final controller = StreamController<Object?>.broadcast();

    receivePort.listen((message) {
      // First message is SendPort
      if (!sendPortCompleter.isCompleted && message is SendPort) {
        sendPortCompleter.complete(message);
        return;
      }

      // All other messages go to stream (including 'ready')
      controller.add(message);
    });

    final sendPort = await sendPortCompleter.future;
    final handle = NativeWorkerHandle._internal(
      sendPort,
      receivePort,
      isolate,
      controller,
    );

    // 2. Initialize plugins (sets up message listeners)
    await initializePlugins(handle);

    // 3. Send config (triggers worker initialization)
    handle.sendMessage({
      'type': 'InitConfig',
      'config': configJson,
      'activeStorageId': activeStorageId,
      'activeRemoteIds': activeRemoteIds,
    });

    // 4. Wait for ready (worker has created SyncEngine)
    await handle.messages.firstWhere((msg) => msg == 'ready');

    return handle;
  }

  /// Generic isolate entry point that receives factory via message.
  ///
  /// This is a static function that can be spawned by Isolate.spawn().
  /// It receives the app's factory function, then waits for config via message.
  static void _isolateEntryPoint(_IsolateStartMessage message) {
    if (message.onWorkerSpawn != null) {
      try {
        message.onWorkerSpawn!();
      } catch (e, st) {
        // Print to stderr since logger might not be configured yet if initializer failed
        // ignore: avoid_print
        print('ERROR: Worker initializer failed: $e\n$st');
      }
    }
    // Call framework's isolate setup with the factory (config comes via message)
    startWorkerIsolate(message.sendPort, message.workerSetup);
  }

  @override
  void sendMessage(Object message) {
    _sendPort.send(message);
  }

  @override
  Stream<Object?> get messages => _controller.stream;

  @override
  Future<void> dispose() async {
    await _controller.close();
    _receivePort.close();
    _isolate.kill(priority: Isolate.immediate);
  }
}
