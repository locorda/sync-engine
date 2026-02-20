import 'dart:async';
import 'dart:isolate';

import 'package:logging/logging.dart';

import '../shared/worker_params.dart';
// the native_worker_handle will spawn a native isolate and start the actual worker within,
// so we need to cross main/worker boundary here in order to kickstart the worker isolate.
import '../worker/worker_entry_point.dart' show startWorkerIsolate;
import 'locorda_worker.dart';

final _log = Logger('NativeWorkerHandle');

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
    _log.info('Creating native worker handle (debugName: $debugName, '
        'storageId: $activeStorageId, remoteIds: $activeRemoteIds)');

    // 1. Spawn isolate
    _log.info('Step 1: Spawning worker isolate...');
    final receivePort = ReceivePort();
    final isolate = await Isolate.spawn(
      _isolateEntryPoint,
      _IsolateStartMessage(receivePort.sendPort, workerSetup,
          onWorkerSpawn: onWorkerSpawn),
      debugName: debugName,
    );
    _log.info('Worker isolate spawned');

    final sendPortCompleter = Completer<SendPort>();
    final controller = StreamController<Object?>.broadcast();

    receivePort.listen((message) {
      // First message is SendPort
      if (!sendPortCompleter.isCompleted && message is SendPort) {
        _log.fine('Received SendPort from worker isolate');
        sendPortCompleter.complete(message);
        return;
      }

      // Log non-ready messages at fine level, ready at info
      if (message == 'ready') {
        _log.info('Received \'ready\' signal from worker');
      } else if (message is Map && message.containsKey('error')) {
        _log.severe('Worker reported error: ${message['error']}');
      } else {
        _log.fine('Received message from worker: '
            '${message is Map ? message['type'] ?? message.keys.take(3) : message.runtimeType}');
      }

      // All other messages go to stream (including 'ready')
      controller.add(message);
    });

    _log.info('Step 1b: Waiting for SendPort from worker...');
    final sendPort = await sendPortCompleter.future;
    _log.info('SendPort received, creating handle');
    final handle = NativeWorkerHandle._internal(
      sendPort,
      receivePort,
      isolate,
      controller,
    );

    // 2. Initialize plugins (sets up message listeners)
    _log.info('Step 2: Initializing plugins...');
    await initializePlugins(handle);
    _log.info('Plugins initialized');

    // 3. Send config (triggers worker initialization)
    _log.info('Step 3: Sending InitConfig to worker '
        '(storageId: $activeStorageId, remoteIds: $activeRemoteIds)...');
    handle.sendMessage({
      'type': 'InitConfig',
      'config': configJson,
      'activeStorageId': activeStorageId,
      'activeRemoteIds': activeRemoteIds,
    });
    _log.info('InitConfig sent, waiting for worker to be ready...');

    // 4. Wait for ready (worker has created SyncEngine)
    _log.info('Step 4: Waiting for \'ready\' signal from worker...');
    await handle.messages.firstWhere((msg) {
      if (msg is Map && msg.containsKey('error')) {
        _log.severe(
            'Worker initialization error while waiting for ready: ${msg['error']}');
        throw StateError('Worker failed to initialize: ${msg['error']}');
      }
      return msg == 'ready';
    });
    _log.info('Worker is ready!');

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
