/// Proxy implementation of [SyncEngine] that forwards operations to worker.
///
/// Transparently handles serialization (RdfGraph → Turtle), request/response
/// matching via request IDs, and async stream bridging.
library;

import 'dart:async';
import 'dart:convert';

import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:logging/logging.dart';

import '../shared/worker_messages.dart';
import 'locorda_worker.dart';

final _log = Logger('ProxySyncEngine');

/// Proxy that forwards all [SyncEngine] operations to a worker isolate/thread.
///
/// This class transparently bridges the main thread and worker thread by:
/// - Serializing RDF graphs to Turtle format
/// - Managing request/response correlation via unique request IDs
/// - Forwarding async operations and propagating errors
/// - Bridging streams across isolate boundary
///
/// Used internally by worker-based setup. Application code doesn't interact
/// with this class directly.
class ProxySyncEngine implements SyncEngine {
  final LocordaWorker _workerHandle;
  final RdfGraphCodec _codec;

  /// Request counter for generating unique IDs
  int _requestCounter = 0;

  /// Pending completers keyed by request ID
  final Map<String, Completer<WorkerResponse>> _pendingRequests = {};

  /// Stream controllers for active hydration streams
  final Map<String, StreamController<HydrationBatch>> _activeStreams = {};

  late final StreamSubscription<Object?> _messageSubscription;

  /// Singleton sync manager instance
  late final _ProxySyncManager _syncManager;
  final List<Future<void> Function()> _closeFunctions;

  ProxySyncEngine._(this._workerHandle,
      {required List<Future<void> Function()> closeFunctions})
      : _codec = TurtleCodec(),
        _closeFunctions = closeFunctions {
    // Listen to worker messages and route to pending operations
    _messageSubscription = _workerHandle.messages.listen(_handleWorkerMessage);

    // Create sync manager instance
    _syncManager = _ProxySyncManager(this);
  }

  /// Create a proxy that forwards operations to the worker.
  ///
  /// Worker is already initialized (waited for 'ready' signal) before this
  /// is called, so we just need to fetch the initial sync state.
  static Future<ProxySyncEngine> create({
    required LocordaWorker workerHandle,
    required List<Future<void> Function()> closeFunctions,
  }) async {
    final proxy =
        ProxySyncEngine._(workerHandle, closeFunctions: closeFunctions);

    // Fetch initial sync state from already-initialized worker
    await proxy._syncManager._fetchInitialState();

    return proxy;
  }

  /// Generate next unique request ID
  String _nextRequestId() => 'req_${_requestCounter++}';

  /// Send request and wait for response
  Future<T> _sendAndAwait<T extends WorkerResponse>(
      WorkerRequest request) async {
    final completer = Completer<WorkerResponse>();
    _pendingRequests[request.requestId] = completer;

    // Send request to worker
    _workerHandle.sendMessage(request.toJson());

    // Wait for response
    final response = await completer.future;

    // Clean up
    _pendingRequests.remove(request.requestId);

    if (response is! T) {
      throw StateError('Expected ${T.toString()}, got ${response.runtimeType}');
    }

    return response;
  }

  /// Handle incoming messages from worker
  void _handleWorkerMessage(Object? message) {
    if (message is! Map<String, dynamic>) {
      // Ignore non-JSON messages
      return;
    }

    final workerMessage = deserializeMessage(message);

    if (workerMessage is WorkerResponse) {
      // Check if it's a streaming response (HydrationBatchMessage)
      if (workerMessage is HydrationBatchMessage) {
        _handleHydrationBatch(workerMessage);
        return;
      }

      // Regular request-response
      final completer = _pendingRequests[workerMessage.requestId];
      if (completer != null) {
        completer.complete(workerMessage);
      } else {
        _log.fine(
            'Received response for unknown request ID: ${workerMessage.requestId}');
      }
    } else if (workerMessage is SyncStateUpdateMessage) {
      // Forward sync state updates to sync manager
      _log.fine('Routing sync state update to manager');
      _syncManager._handleSyncStateUpdate(workerMessage);
    } else {
      _log.fine('Received unknown message type: ${workerMessage.runtimeType}');
    }
  }

  /// Handle hydration batch messages from worker
  void _handleHydrationBatch(HydrationBatchMessage batch) {
    final controller = _activeStreams[batch.requestId];
    if (controller == null) {
      // Stream was cancelled, ignore
      return;
    }

    // Deserialize graphs from Turtle
    final updates = batch.updates
        .map((item) => (IriTerm(item.$1), _codec.decode(item.$2)))
        .toList();

    final deletions = batch.deletions
        .map((item) => (IriTerm(item.$1), _codec.decode(item.$2)))
        .toList();

    final hydrationBatch = (
      updates: updates,
      deletions: deletions,
      cursor: batch.cursor,
    );

    controller.add(hydrationBatch);

    // Close stream if this is the final batch
    if (batch.isComplete) {
      controller.close();
      _activeStreams.remove(batch.requestId);
    }
  }

  /// Serialize RDF graph to Turtle format for transmission
  String _serializeGraph(RdfGraph graph) {
    return _codec.encode(graph);
  }

  @override
  Stream<IndexInstanceSyncStateSnapshot> watchGroupIndexSyncState({
    required String indexName,
    required RdfGraph groupKeyGraph,
  }) {
    throw UnsupportedError(
        'watchGroupIndexSyncState is not yet implemented for worker proxy.');
  }

  @override
  Stream<IndexInstanceSyncStateSnapshot> watchTypeSyncState({
    required IriTerm typeIri,
    String localName = 'default',
  }) {
    throw UnsupportedError(
        'watchTypeSyncState is not yet implemented for worker proxy.');
  }

  @override
  void ensureGroupIndexSubscription({
    required String indexName,
    required RdfGraph groupKeyGraph,
    bool triggerSync = true,
  }) {
    throw UnsupportedError(
        'ensureGroupIndexSubscription is not yet implemented for worker proxy.');
  }

  @override
  Future<void> ensureGroupIndexSynced({
    required String indexName,
    required RdfGraph groupKeyGraph,
  }) {
    throw UnsupportedError(
        'ensureGroupIndexSynced is not yet implemented for worker proxy.');
  }

  @override
  Future<void> save(IriTerm type, RdfGraph appData) async {
    final request = SaveRequest(
      _nextRequestId(),
      type.value,
      _serializeGraph(appData),
    );

    final response = await _sendAndAwait<SaveResponse>(request);
    if (!response.success) {
      throw Exception('Save failed: ${response.error}');
    }
  }

  @override
  Future<void> deleteDocument(IriTerm typeIri, IriTerm externalIri) async {
    final request = DeleteDocumentRequest(
      _nextRequestId(),
      typeIri.value,
      externalIri.value,
    );

    final response = await _sendAndAwait<DeleteDocumentResponse>(request);
    if (!response.success) {
      throw Exception('Delete failed: ${response.error}');
    }
  }

  @override
  Future<RdfGraph?> ensure(
    IriTerm typeIri,
    IriTerm localIri, {
    required Future<RdfGraph?> Function(IriTerm localIri) loadFromLocal,
    Duration? timeout = const Duration(seconds: 15),
    bool skipInitialFetch = false,
  }) async {
    // ensure() is not yet fully implemented in StandardsyncEngine.
    // For now, we just execute the loadFromLocal callback in the main thread.
    // When proper implementation is added, we'll decide whether to:
    // - Keep it in main thread (Option 2: local storage access)
    // - Move to worker (requires serializing the callback somehow)
    // - Remove it entirely (if repository pattern makes it obsolete)

    return loadFromLocal(localIri);
  }

  @override
  Stream<HydrationBatch> hydrateStream({
    required IriTerm typeIri,
    String? indexName,
    String? cursor,
    int initialBatchSize = 10,
  }) {
    final requestId = _nextRequestId();

    // Create stream controller for this request
    final controller = StreamController<HydrationBatch>();
    _activeStreams[requestId] = controller;

    // Send request to worker
    final request = HydrateStreamRequest(
      requestId,
      typeIri.value,
      indexName: indexName,
      cursor: cursor,
      initialBatchSize: initialBatchSize,
    );
    _workerHandle.sendMessage(request.toJson());

    // Clean up on stream cancellation
    controller.onCancel = () {
      _activeStreams.remove(requestId);
    };

    return controller.stream;
  }

  @override
  Future<void> configureGroupIndexSubscription(
    String indexName,
    RdfGraph groupKeyGraph,
    ItemFetchPolicy itemFetchPolicy,
  ) async {
    final request = ConfigureGroupIndexSubscriptionRequest(
      _nextRequestId(),
      indexName,
      _serializeGraph(groupKeyGraph),
      jsonEncode(itemFetchPolicy.toMap()), // Serialize policy as JSON
    );

    final response =
        await _sendAndAwait<ConfigureGroupIndexSubscriptionResponse>(request);

    if (!response.success) {
      throw Exception(
          'Configure group index subscription failed: ${response.error}');
    }
  }

  @override
  SyncManager get syncManager => _syncManager;

  @override
  Future<void> close() async {
    for (final closeFunction in _closeFunctions) {
      try {
        await closeFunction();
      } catch (e, st) {
        _log.severe('Error during close function', e, st);
      }
    }

    // Cancel all active streams
    for (final controller in _activeStreams.values) {
      await controller.close();
    }
    _activeStreams.clear();

    // Cancel pending requests
    for (final completer in _pendingRequests.values) {
      completer.completeError(
          StateError('SyncEngine closed before response received'));
    }
    _pendingRequests.clear();

    // Cancel message subscription
    await _messageSubscription.cancel();

    // Worker handle remains active for potential cleanup operations
    // Actual worker shutdown happens at application level
  }
}

/// Proxy implementation of [SyncManager] that forwards operations to worker.
///
/// Bridges sync manager operations across the worker boundary, maintaining
/// a local cache of sync state and streaming updates from the worker.
class _ProxySyncManager implements SyncManager {
  final ProxySyncEngine _proxy;

  /// Stream controller for sync state updates
  final StreamController<SyncState> _statusController =
      StreamController<SyncState>.broadcast();

  /// Current cached sync state
  SyncState _currentState = const SyncState.idle();

  _ProxySyncManager(this._proxy);

  @override
  @override
  Future<void> sync({SyncTrigger trigger = SyncTrigger.manual}) async {
    _log.info('Triggering sync (trigger: $trigger)...');
    final request = SyncTriggerRequest(
      _proxy._nextRequestId(),
      trigger: trigger,
    );
    final response = await _proxy._sendAndAwait<SyncTriggerResponse>(request);

    if (!response.success) {
      _log.severe('Sync trigger failed: ${response.error}');
      throw Exception('Sync trigger failed: ${response.error}');
    }
    _log.fine('Sync triggered successfully');
  }

  /// Fetch initial sync state from worker
  Future<void> _fetchInitialState() async {
    _log.fine('Fetching initial sync state from worker...');
    final request = GetSyncStateRequest(_proxy._nextRequestId());
    final response = await _proxy._sendAndAwait<GetSyncStateResponse>(request);

    _log.fine(
        'Received initial sync state: ${response.status}, lastSync: ${response.lastSyncTime}, trigger: ${response.lastTrigger}');
    _updateState(response.status, response.lastSyncTime, response.errorMessage,
        response.lastTrigger);
  }

  /// Update local state from status string and optional metadata
  void _updateState(
    String statusString,
    DateTime? lastSyncTime,
    String? errorMessage, [
    SyncTrigger? lastTrigger,
  ]) {
    final status = switch (statusString) {
      'idle' => SyncStatus.idle,
      'syncing' => SyncStatus.syncing,
      'success' => SyncStatus.success,
      'error' => SyncStatus.error,
      _ => SyncStatus.idle,
    };

    _currentState = SyncState(
      status: status,
      lastSyncTime: lastSyncTime,
      errorMessage: errorMessage,
      lastTrigger: lastTrigger,
    );

    _log.info(
        'Sync state updated: $statusString (trigger: $lastTrigger)${errorMessage != null ? ' - $errorMessage' : ''}');
    _statusController.add(_currentState);
  }

  @override
  void enableAutoSync({Duration interval = const Duration(minutes: 5)}) {
    _log.info('Enabling auto-sync with interval: $interval');
    final request =
        EnableAutoSyncRequest(_proxy._nextRequestId(), interval.inMinutes);
    _proxy._sendAndAwait<EnableAutoSyncResponse>(request);
    // Fire and forget - don't await
  }

  @override
  void disableAutoSync() {
    _log.info('Disabling auto-sync');
    final request = DisableAutoSyncRequest(_proxy._nextRequestId());
    _proxy._sendAndAwait<DisableAutoSyncResponse>(request);
    // Fire and forget - don't await
  }

  @override
  Stream<SyncState> get statusStream => _statusController.stream;

  @override
  SyncState get currentState => _currentState;

  @override
  bool get isSyncing => _currentState.status == SyncStatus.syncing;

  /// Handle sync state update from worker
  void _handleSyncStateUpdate(SyncStateUpdateMessage message) {
    _log.fine(
        'Received sync state update from worker: ${message.status} (trigger: ${message.lastTrigger})');
    _updateState(message.status, message.lastSyncTime, message.errorMessage,
        message.lastTrigger);
  }

  @override
  Future<void> dispose() async {
    await _statusController.close();
  }
}
