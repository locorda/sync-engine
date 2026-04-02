/// Worker entry point for isolate/web worker execution.
///
/// Provides the main message loop and context management for worker-based
/// SyncEngine instances.
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_worker/src/shared/worker_params.dart';
import 'package:locorda_worker/src/worker/worker_channel.dart';
//import 'package:locorda_worker/src/main/locorda_worker.dart';
import 'package:locorda_worker/src/shared/worker_graph_codec.dart';
import 'package:locorda_worker/src/shared/worker_messages.dart';
import 'package:locorda_worker/src/worker/worker_params_to_engine_params.dart';
import 'package:logging/logging.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:locorda_rdf_jelly/jelly.dart';

// Conditional import for web worker implementation
import 'web_worker_entry_point_stub.dart'
    if (dart.library.js_interop) 'web_worker_entry_point.dart';

final _log = Logger('WorkerEntryPoint');

/// Abstraction for sending messages back to main thread.
///
/// This allows the same worker context to work with both native isolates
/// (using SendPort) and web workers (using postMessage).
abstract class WorkerMessageSender {
  void send(Object? message);
}

/// Native isolate implementation using SendPort
class IsolateSender implements WorkerMessageSender {
  final SendPort _sendPort;

  IsolateSender(this._sendPort);

  @override
  void send(Object? message) => _sendPort.send(message);
}

abstract class WorkerHandlerContext {
  Perflog get perflog;
  WorkerHandlerChannel createChannel(String name);
}

abstract class BackendWorkerHandlerContext implements WorkerHandlerContext {
  ResourceGraphLoader get resourceGraphLoader;
  RdfCore get rdfCore;
  IriTermFactory? get iriFactory;
}

class WorkerHandlerContextImpl implements WorkerHandlerContext {
  final WorkerChannel _channel;
  final Perflog perflog;
  final Set<String> _registeredChannels = {};

  WorkerHandlerContextImpl(this._channel, {required this.perflog});

  WorkerHandlerChannel createChannel(String name) {
    if (_registeredChannels.contains(name)) {
      throw StateError('Channel "$name" already registered in this context.');
    }
    _registeredChannels.add(name);

    return _channel.createChannel(name);
  }
}

class BackendWorkerHandlerContextImpl implements BackendWorkerHandlerContext {
  final ResourceGraphLoader resourceGraphLoader;
  final WorkerHandlerContext _context;
  final RdfCore rdfCore;
  final IriTermFactory? iriFactory;

  BackendWorkerHandlerContextImpl({
    required WorkerHandlerContext context,
    required this.resourceGraphLoader,
    required this.rdfCore,
    this.iriFactory,
  }) : _context = context;

  @override
  WorkerHandlerChannel createChannel(String name) {
    return _context.createChannel(name);
  }

  @override
  Perflog get perflog => _context.perflog;
}

/// Context for worker execution.
///
/// Manages the SyncEngine instance and message routing within the worker.
class WorkerContext {
  final WorkerMessageSender _sender;
  final WorkerGraphEncoder _encodeGraph;
  final WorkerGraphDecoder _decodeGraph;

  /// Communication channel for cross-thread operations (e.g., auth)
  final WorkerChannel _channel;

  SyncEngine? _syncSystem;

  /// Active hydration streams keyed by request ID
  final Map<String, StreamSubscription<HydrationBatch>> _activeStreams = {};

  /// Active index-state watch streams keyed by request ID
  final Map<String, StreamSubscription<IndexInstanceSyncState>>
      _activeIndexStateStreams = {};

  /// Subscription to sync status stream
  StreamSubscription<SyncState>? _syncStatusSubscription;
  final Perflog _perflog;

  WorkerContext(
    this._sender,
    this._channel, {
    required WorkerGraphEncoder encodeGraph,
    required WorkerGraphDecoder decodeGraph,
    required Perflog perflog,
  })  : _encodeGraph = encodeGraph,
        _decodeGraph = decodeGraph,
        _perflog = perflog;

  late WorkerHandlerContext workerHandlerContext =
      WorkerHandlerContextImpl(_channel, perflog: _perflog);

  /// Send a message back to the main thread (package-visible for web worker).
  void sendMessage(WorkerMessage message) {
    _sender.send(message.toJson());
  }

  /// Set the sync system instance (package-visible for web worker).
  void setSyncSystem(SyncEngine syncSystem) {
    _syncSystem = syncSystem;

    // Subscribe to sync status updates and forward to main thread
    _syncStatusSubscription =
        syncSystem.syncManager.statusStream.listen((state) {
      final statusString = switch (state.status) {
        SyncStatus.idle => 'idle',
        SyncStatus.syncing => 'syncing',
        SyncStatus.success => 'success',
        SyncStatus.error => 'error',
      };

      _log.fine(
          'Worker: Sending sync state update to main thread: $statusString (trigger: ${state.lastTrigger})');
      _sendMessage(SyncStateUpdateMessage(
        status: statusString,
        lastSyncTime: state.lastSyncTime,
        errorMessage: state.errorMessage,
        lastTrigger: state.lastTrigger,
      ));
    });
  }

  /// Send a message back to the main thread
  void _sendMessage(WorkerMessage message) {
    _sender.send(message.toJson());
  }

  /// Handle incoming message from main thread
  Future<void> handleMessage(Object? message) async {
    if (message is! Map<String, dynamic>) {
      return; // Ignore non-JSON messages
    }

    try {
      final workerMessage = deserializeMessage(message);

      if (workerMessage is SaveRequest) {
        await _handleSave(workerMessage);
      } else if (workerMessage is SaveAllRequest) {
        await _handleSaveAll(workerMessage);
      } else if (workerMessage is DeleteDocumentRequest) {
        await _handleDelete(workerMessage);
      } else if (workerMessage is DeleteDocumentsRequest) {
        await _handleDeleteDocuments(workerMessage);
      } else if (workerMessage is EnsureGroupIndexSubscriptionRequest) {
        await _handleEnsureGroupIndexSubscription(workerMessage);
      } else if (workerMessage is HydrateStreamRequest) {
        await _handleHydrateStream(workerMessage);
      } else if (workerMessage is WatchIndexInstanceSyncStateRequest) {
        await _handleWatchIndexInstanceSyncState(workerMessage);
      } else if (workerMessage is CancelWatchRequest) {
        await _handleCancelWatch(workerMessage);
      } else if (workerMessage is SyncTriggerRequest) {
        await _handleSyncTrigger(workerMessage);
      } else if (workerMessage is EnableAutoSyncRequest) {
        await _handleEnableAutoSync(workerMessage);
      } else if (workerMessage is DisableAutoSyncRequest) {
        await _handleDisableAutoSync(workerMessage);
      } else if (workerMessage is GetSyncStateRequest) {
        await _handleGetSyncState(workerMessage);
      }
      // Note: Auth updates are NOT handled by framework - use WorkerChannel for app-specific messages
    } catch (e, st) {
      // Log error but don't crash worker
      _log.severe('Worker error handling message: $e\n$st');
    }
  }

  Future<void> _handleSave(SaveRequest request) async {
    try {
      if (_syncSystem == null) {
        throw StateError('Sync system not initialized');
      }

      final typeIri = IriTerm(request.typeIri);
      final appData = _decodeGraph(request.encodedGraph);

      await _syncSystem!.save(typeIri, appData);

      _sendMessage(SaveResponse(request.requestId, success: true));
    } catch (e, st) {
      _sendMessage(SaveResponse(
        request.requestId,
        success: false,
        error: '$e\n$st',
      ));
    }
  }

  Future<void> _handleSaveAll(SaveAllRequest request) async {
    try {
      if (_syncSystem == null) {
        throw StateError('Sync system not initialized');
      }

      final items = request.items
          .map((item) => (
                IriTerm(item.$1),
                _decodeGraph(item.$2),
              ))
          .toList();

      await _syncSystem!.saveAll(items);

      _sendMessage(SaveAllResponse(request.requestId, success: true));
    } catch (e, st) {
      _sendMessage(SaveAllResponse(
        request.requestId,
        success: false,
        error: '$e\n$st',
      ));
    }
  }

  Future<void> _handleDelete(DeleteDocumentRequest request) async {
    try {
      if (_syncSystem == null) {
        throw StateError('Sync system not initialized');
      }

      final typeIri = IriTerm(request.typeIri);
      final externalIri = IriTerm(request.externalIri);

      await _syncSystem!.deleteDocument(typeIri, externalIri);

      _sendMessage(DeleteDocumentResponse(request.requestId, success: true));
    } catch (e, st) {
      _sendMessage(DeleteDocumentResponse(
        request.requestId,
        success: false,
        error: '$e\n$st',
      ));
    }
  }

  Future<void> _handleDeleteDocuments(DeleteDocumentsRequest request) async {
    try {
      if (_syncSystem == null) {
        throw StateError('Sync system not initialized');
      }

      final typeIri = IriTerm(request.typeIri);
      final externalIris =
          request.externalIris.map((iri) => IriTerm(iri)).toList();

      await _syncSystem!.deleteDocuments(typeIri, externalIris);

      _sendMessage(DeleteDocumentsResponse(request.requestId, success: true));
    } catch (e, st) {
      _sendMessage(DeleteDocumentsResponse(
        request.requestId,
        success: false,
        error: '$e\n$st',
      ));
    }
  }

  Future<void> _handleEnsureGroupIndexSubscription(
      EnsureGroupIndexSubscriptionRequest request) async {
    try {
      if (_syncSystem == null) {
        throw StateError('Sync system not initialized');
      }

      final groupKeyGraph = _decodeGraph(request.encodedGroupKeyGraph);

      await _syncSystem!.ensureGroupIndexSubscription(
        indexName: request.indexName,
        groupKeyGraph: groupKeyGraph,
        rootResourceFetchPolicy: request.rootResourceFetchPolicyMap != null
            ? RootResourceFetchPolicy.fromMap(
                request.rootResourceFetchPolicyMap!)
            : null,
        triggerSync: request.triggerSync,
      );

      _sendMessage(EnsureGroupIndexSubscriptionResponse(
        request.requestId,
        success: true,
      ));
    } catch (e, st) {
      _sendMessage(EnsureGroupIndexSubscriptionResponse(
        request.requestId,
        success: false,
        error: '$e\n$st',
      ));
    }
  }

  Future<void> _handleHydrateStream(HydrateStreamRequest request) async {
    try {
      if (_syncSystem == null) {
        throw StateError('Sync system not initialized');
      }

      final typeIri = IriTerm(request.typeIri);

      final stream = _syncSystem!.hydrateStream(
        typeIri: typeIri,
        indexName: request.indexName,
        cursor: request.cursor,
        initialBatchSize: request.initialBatchSize,
      );

      // Subscribe to stream and forward batches to main thread
      final subscription = stream.listen(
        (batch) {
          final updates = batch.updates
              .map((item) => (item.$1.value, _encodeGraph(item.$2)))
              .toList();

          final deletions = batch.deletions
              .map((item) => (item.$1.value, _encodeGraph(item.$2)))
              .toList();

          _sendMessage(HydrationBatchMessage(
            request.requestId,
            updates: updates,
            deletions: deletions,
            cursor: batch.cursor,
            isComplete: false,
          ));
        },
        onError: (e, st) {
          // Send error as final batch
          _sendMessage(HydrationBatchMessage(
            request.requestId,
            updates: [],
            deletions: [],
            isComplete: true,
          ));
          _activeStreams.remove(request.requestId);
        },
        onDone: () {
          // Send completion marker
          _sendMessage(HydrationBatchMessage(
            request.requestId,
            updates: [],
            deletions: [],
            isComplete: true,
          ));
          _activeStreams.remove(request.requestId);
        },
      );

      _activeStreams[request.requestId] = subscription;
    } catch (e) {
      // Send error as immediate completion
      _sendMessage(HydrationBatchMessage(
        request.requestId,
        updates: [],
        deletions: [],
        isComplete: true,
      ));
    }
  }

  Future<void> _handleWatchIndexInstanceSyncState(
      WatchIndexInstanceSyncStateRequest request) async {
    try {
      if (_syncSystem == null) {
        throw StateError('Sync system not initialized');
      }

      final stream = switch (request.watchKind) {
        'group' => _syncSystem!.watchGroupIndexSyncState(
            indexName: request.indexName!,
            groupKeyGraph: _decodeGraph(request.encodedGroupKeyGraph!)),
        'type' => _syncSystem!.watchSyncState(
            typeIri: IriTerm(request.typeIri!), indexName: request.indexName),
        _ => throw ArgumentError('Unknown watch kind: ${request.watchKind}'),
      };

      var isInitial = true;
      final subscription = stream.listen(
        (snapshot) {
          _sendMessage(IndexInstanceSyncStateMessage(
            request.requestId,
            indexInstanceIri: snapshot.indexInstanceIri.value,
            perRemote: snapshot.perRemote.values
                .map((entry) => {
                      'backend': entry.remoteId.backend,
                      'id': entry.remoteId.id,
                      'phase': entry.phase.name,
                      'lastSuccessfulSyncAt':
                          entry.lastSuccessfulSyncAt?.toIso8601String(),
                      'lastAttemptStartedAt':
                          entry.lastAttemptStartedAt?.toIso8601String(),
                      'lastAttemptFinishedAt':
                          entry.lastAttemptFinishedAt?.toIso8601String(),
                      'lastErrorMessage': entry.lastErrorMessage,
                    })
                .toList(growable: false),
            isInitial: isInitial,
            isComplete: false,
          ));
          isInitial = false;
        },
        onError: (error, stackTrace) {
          _sendMessage(IndexInstanceSyncStateMessage(
            request.requestId,
            indexInstanceIri: '',
            perRemote: const [],
            isInitial: false,
            isComplete: true,
          ));
          _activeIndexStateStreams.remove(request.requestId);
        },
        onDone: () {
          _sendMessage(IndexInstanceSyncStateMessage(
            request.requestId,
            indexInstanceIri: '',
            perRemote: const [],
            isInitial: false,
            isComplete: true,
          ));
          _activeIndexStateStreams.remove(request.requestId);
        },
      );

      _activeIndexStateStreams[request.requestId] = subscription;
    } catch (error) {
      _sendMessage(IndexInstanceSyncStateMessage(
        request.requestId,
        indexInstanceIri: '',
        perRemote: const [],
        isInitial: false,
        isComplete: true,
      ));
    }
  }

  Future<void> _handleCancelWatch(CancelWatchRequest request) async {
    try {
      await _activeIndexStateStreams.remove(request.targetRequestId)?.cancel();
      await _activeStreams.remove(request.targetRequestId)?.cancel();
      _sendMessage(CancelWatchResponse(request.requestId, success: true));
    } catch (error, stackTrace) {
      _sendMessage(CancelWatchResponse(
        request.requestId,
        success: false,
        error: '$error\n$stackTrace',
      ));
    }
  }

  Future<void> _handleSyncTrigger(SyncTriggerRequest request) async {
    try {
      if (_syncSystem == null) {
        throw StateError('Sync system not initialized');
      }

      await _syncSystem!.syncManager.sync(trigger: request.trigger);

      _sendMessage(SyncTriggerResponse(request.requestId, success: true));
    } catch (e, st) {
      _sendMessage(SyncTriggerResponse(
        request.requestId,
        success: false,
        error: '$e\n$st',
      ));
    }
  }

  Future<void> _handleEnableAutoSync(EnableAutoSyncRequest request) async {
    try {
      if (_syncSystem == null) {
        throw StateError('Sync system not initialized');
      }

      _syncSystem!.syncManager.enableAutoSync(
        interval: Duration(minutes: request.intervalMinutes),
      );

      _sendMessage(EnableAutoSyncResponse(request.requestId, success: true));
    } catch (e) {
      // On error, still send success=false response
      _sendMessage(EnableAutoSyncResponse(request.requestId, success: false));
    }
  }

  Future<void> _handleDisableAutoSync(DisableAutoSyncRequest request) async {
    try {
      if (_syncSystem == null) {
        throw StateError('Sync system not initialized');
      }

      _syncSystem!.syncManager.disableAutoSync();

      _sendMessage(DisableAutoSyncResponse(request.requestId, success: true));
    } catch (e) {
      // On error, still send success=false response
      _sendMessage(DisableAutoSyncResponse(request.requestId, success: false));
    }
  }

  Future<void> _handleGetSyncState(GetSyncStateRequest request) async {
    try {
      if (_syncSystem == null) {
        throw StateError('Sync system not initialized');
      }

      final state = _syncSystem!.syncManager.currentState;
      final statusString = switch (state.status) {
        SyncStatus.idle => 'idle',
        SyncStatus.syncing => 'syncing',
        SyncStatus.success => 'success',
        SyncStatus.error => 'error',
      };

      _log.fine(
          'Worker: Responding to GetSyncState request with status: $statusString (trigger: ${state.lastTrigger})');
      _sendMessage(GetSyncStateResponse(
        request.requestId,
        status: statusString,
        lastSyncTime: state.lastSyncTime,
        errorMessage: state.errorMessage,
        lastTrigger: state.lastTrigger,
      ));
    } catch (e, st) {
      // On error, return error state
      _sendMessage(GetSyncStateResponse(
        request.requestId,
        status: 'error',
        errorMessage: '$e\n$st',
      ));
    }
  }

  /// Clean up resources
  Future<void> dispose() async {
    // Cancel sync status subscription
    await _syncStatusSubscription?.cancel();

    // Cancel all active streams
    for (final subscription in _activeStreams.values) {
      await subscription.cancel();
    }
    _activeStreams.clear();

    for (final subscription in _activeIndexStateStreams.values) {
      await subscription.cancel();
    }
    _activeIndexStateStreams.clear();

    // Close sync system
    await _syncSystem?.close();
  }
}

/// Standard worker entry point for native isolates.
///
/// This function registers the app's setup function and returns a reference
/// to the static entry point that can be passed to Isolate.spawn().
///
/// Framework responsibilities:
/// - Establish communication with main thread
/// - Receive and deserialize SyncEngineConfig
/// - Call app's params factory with config + context
/// - Create SyncEngine from returned EngineParams
/// - Wrap SyncEngine in message handler
/// - Forward all messages to/from SyncEngine
///
/// App responsibilities (via params factory):
/// - Create Storage (e.g., DriftStorage)
/// - Create Backends (e.g., SolidBackend with WorkerSolidAuthProvider)
/// - Return EngineParams containing storage and backends
///
/// Example usage in app's worker.dart:
/// ```dart
/// void main() {
///   workerMain((config, context) async {
///     final storage = DriftStorage(...);
///     final backends = [SolidBackend(auth: WorkerSolidAuthProvider(context.channel))];
///     return EngineParams(storage: storage, backends: backends);
///   });
/// }
/// ```
///
/// Then in main thread setup:
/// ```dart
/// import 'worker.dart' show createEngineParams;
///
/// final handle = await LocordaWorker.start(
///   engineParamsFactory: createEngineParams,
///   jsScript: 'worker.dart.js',
/// );
/// ```

// FIXME: if this is needed, why is it unused?
/// Global setup function storage (needed for web workers where main() is called)
// ignore: unused_element
WorkerSetup? _currentSetupFunction;

/// Entry point for web workers - called when worker JS loads.
///
/// Web workers start by calling the compiled main() function.
/// Apps must call this with their setup function in worker.dart's main().
///
/// The optional [onWorkerSpawn] runs **before** engine setup, allowing
/// apps to configure logging or other worker-global state. Must be a
/// **top-level function** (not a closure) for native platform compatibility.
///
/// ```dart
/// // lib/worker.dart
/// import 'package:logging/logging.dart';
///
/// void main() {
///   workerMain(
///     createEngineParams,
///     workerInitializer: setupLogging,  // Top-level function
///   );
/// }
///
/// // Top-level function for worker initialization
/// void setupLogging() {
///   Logger.root.level = Level.INFO;
///   Logger.root.onRecord.listen((record) {
///     print('[Worker] ${record.level.name}: ${record.message}');
///   });
/// }
/// ```
void workerMain(WorkerSetup setupFn, {void onWorkerSpawn()?}) {
  if (onWorkerSpawn != null) {
    try {
      onWorkerSpawn();
    } catch (e, st) {
      // Print to stderr since logger might not be configured yet if initializer failed
      // ignore: avoid_print
      print('ERROR: Worker initializer failed: $e\n$st');
    }
  }
  // FIXME: wtf?
  // Store setup function for later (not currently needed but kept for consistency)
  _currentSetupFunction = setupFn;

  // Start web worker message loop (delegates to platform-specific implementation)
  startWebWorkerLoop(setupFn);
}

/// Entry point for native isolates - receives factory via parameter.
///
/// This is called by NativeWorkerHandle after Isolate.spawn().
/// The factory function is passed in spawn, config arrives via first message.
void startWorkerIsolate(SendPort mainSendPort, WorkerSetup workerSetup) async {
  _log.info('Starting native worker isolate');
  // 1. Establish bidirectional communication
  final receivePort = ReceivePort();

  // 2. Create WorkerChannel for app-specific messages
  final channel = WorkerChannel((message) {
    // Send app-specific messages with special marker
    _log.fine('Worker sending channel message: channel=${message.channel}');
    mainSendPort.send({'__channel': message.channel, 'data': message.data});
  });

  // 3. Create WorkerContext (native: use jelly binary codec for performance)
  final context = WorkerContext(
    IsolateSender(mainSendPort),
    channel,
    encodeGraph: (graph) => jellyGraph.encode(graph),
    decodeGraph: (encoded) => jellyGraph.decode(encoded as Uint8List),
    perflog: Perflog.root(),
  );

  // 4. Wait for InitConfig message with configuration
  SyncEngineConfig? config;
  final configCompleter = Completer<SyncEngineConfig>();
  String? activeStorageId;
  List<String>? activeRemoteIds;

  _log.info('Worker: Listening on receivePort, sending sendPort to main...');
  receivePort.listen((message) async {
    // After config received, handle normal messages
    if (message is Map<String, dynamic>) {
      // Check if it's a channel message
      if (message['__channel'] is String) {
        final channelName = message['__channel'] as String;
        _log.fine('Worker: Delivering channel message: channel=$channelName');
        channel.deliver(channelName, message['data']);
        return;
      }

      // First non-channel message must be InitConfig
      if (config == null) {
        if (message['type'] == 'InitConfig') {
          _log.info('Worker: Received InitConfig message');
          config = SyncEngineConfig.fromJson(
              message['config'] as Map<String, dynamic>);
          activeStorageId = message['activeStorageId'] as String?;
          final activeRemoteList = message['activeRemoteIds'] as List?;
          activeRemoteIds =
              activeRemoteList?.map((id) => id.toString()).toList();
          _log.info('Worker: Config parsed - storageId=$activeStorageId, '
              'remoteIds=$activeRemoteIds');
          configCompleter.complete(config);
          return;
        } else {
          _log.warning(
              'Expected InitConfig message but received: $message. Ignoring.');
          return;
        }
      } else {
        _log.fine('Worker: Handling framework message type=${message['type']}');
        // Framework message - handle normally
        await context.handleMessage(message);
      }
    } else {
      _log.warning('Worker: Received unexpected non-map message: '
          '${message.runtimeType}: $message');
    }
  });

  // VERY IMPORTANT: Send our SendPort to main isolate **after** we started listening
  // else we might miss messages
  mainSendPort.send(receivePort.sendPort);
  _log.info('Worker: SendPort sent to main, waiting for InitConfig...');

  // Wait for config
  final receivedConfig = await configCompleter.future;
  _log.info('Worker: InitConfig received, starting engine setup '
      '(storageId=$activeStorageId, remoteIds=$activeRemoteIds)');

  // 5. Call app's setup function and initialize SyncEngine
  try {
    _log.info('Worker: Step 5a - Calling workerSetup()...');
    final workerParams = await workerSetup();
    _log.info('Worker: Step 5b - WorkerParams obtained '
        '(${workerParams.storages.length} storages, '
        '${workerParams.remotes.length} remotes), converting to EngineParams...');
    final engineParams = await toEngineParams(
        workerParams, context, receivedConfig,
        activeStorageId: activeStorageId, activeRemoteIds: activeRemoteIds);
    _log.info('Worker: Step 5c - EngineParams ready, creating SyncEngine...');
    final syncSystem = await SyncEngine.create(
        config: receivedConfig,
        engineParams: engineParams,
        perflog: context._perflog);
    _log.info('Worker: Step 5d - SyncEngine created, setting sync system...');
    context.setSyncSystem(syncSystem);
    _log.info('Worker: Step 5e - SyncSystem set up successfully');
  } catch (e, st) {
    _log.severe('Worker: Engine initialization failed: $e\n$st');
    // Send error and abort worker
    mainSendPort.send({
      'error': 'Worker initialization failed: $e\n$st',
    });
    return;
  }

  // 6. Send 'ready' signal to main thread
  _log.info('Worker: Step 6 - Sending \'ready\' signal to main thread...');
  mainSendPort.send('ready');
  _log.info('Worker: Initialization complete, ready to handle messages');
}
