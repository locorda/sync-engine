/// Web Worker implementation of the worker entry point.
///
/// This file contains the dart:js_interop-based implementation for web workers.
library;

import 'dart:js_interop';

import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_worker/src/shared/worker_params.dart';
import 'package:locorda_worker/src/worker/worker_params_to_engine_params.dart';
import 'package:logging/logging.dart';
import 'package:web/web.dart' as web;

import '../shared/js_interop_utils.dart';
import 'worker_channel.dart';
import 'worker_entry_point.dart';

final _log = Logger('WebWorkerEntryPoint');

/// Sanitizes message data for logging by never exposing field values.
///
/// Returns a safe summary showing message type and field names only,
/// without exposing sensitive values like private keys or tokens.
String _sanitizeForLog(dynamic data) {
  if (data is Map) {
    final type = data['type'];
    final channelFlag = data['__channel'];
    final fieldCount = data.length;

    // For channel messages, show the nested data type
    if (channelFlag is String && data['data'] is Map) {
      final nestedData = data['data'] as Map;
      final nestedType = nestedData['type'];
      return '__channel $channelFlag message: $nestedType (${nestedData.length} fields)';
    }

    return 'type: $type, fields: $fieldCount';
  } else if (data is List) {
    return 'List(${data.length} items)';
  } else {
    return data.runtimeType.toString();
  }
}

/// Access to the global scope in a Web Worker.
///
/// In web workers, there's a global `self` object that represents the worker's
/// global scope (similar to `window` in the main thread).
@JS('self')
external web.EventTarget get workerGlobalScope;

/// Web worker message sender using postMessage on global scope
class WebWorkerSender implements WorkerMessageSender {
  @override
  void send(Object? message) {
    // Use the global postMessage function available in worker scope
    _postMessage(message.jsify());
  }
}

/// Direct access to postMessage in worker global scope
@JS('self.postMessage')
external void _postMessage(JSAny? message);

/// Start the web worker message loop.
///
/// This sets up the message handler for the web worker's global scope
/// and initializes the worker when the first setup message arrives.
void startWebWorkerLoop(WorkerSetup workerSetup) {
  _log.info('Starting web worker');

  // Create WorkerChannel early (like native implementation does)
  final channel = WorkerChannel((message) {
    _postMessage({'__channel': message.channel, 'data': message.data}.jsify());
  });
  WorkerContext? context;
  bool isInitializing = false;

  // Helper callbacks for managing initialization state
  void resetInitializing() => isInitializing = false;
  void markAsInitializing() => isInitializing = true;

  // Set up message listener on web worker global scope
  workerGlobalScope.addEventListener(
    'message',
    ((web.Event event) {
      // Extract and convert message data synchronously
      final messageEvent = event as web.MessageEvent;
      final data = dartifyAndConvert(messageEvent.data);

      // Log sanitized message info (no sensitive data)
      _log.fine('Worker received message: ${_sanitizeForLog(data)}');

      if (data is! Map) {
        _log.warning(
            'Data is not a Map, it is ${data.runtimeType}. Ignoring message.');
        return;
      }

      final messageData = data as Map<String,
          dynamic>; // Check if this is a channel message - route directly to channel (like native impl)
      if (messageData['__channel'] is String) {
        channel.deliver(
            messageData['__channel'] as String, messageData['data']);
        return;
      }

      // Handle framework messages asynchronously
      _handleWorkerMessage(
        messageData,
        () => context,
        (newContext) {
          context = newContext;
          isInitializing = false;
        },
        workerSetup,
        channel,
        () => isInitializing,
        markAsInitializing,
        resetInitializing,
      ).catchError((e, st) {
        // Log error and attempt to send error message to main thread
        _log.severe('Web worker error: $e\n$st');
        try {
          _postMessage({
            'type': 'error',
            'error': '$e',
            'stackTrace': '$st',
          }.jsify());
        } catch (_) {
          // If even error reporting fails, just log
          _log.severe('Failed to send error to main thread');
        }
      });
    }).toJS,
  );
}

/// Handle a worker message asynchronously.
///
/// Uses callbacks to access and update context to avoid mutable closure variables.
Future<void> _handleWorkerMessage(
  Map<String, dynamic> data,
  WorkerContext? Function() getContext,
  void Function(WorkerContext) setContext,
  WorkerSetup workerSetup,
  WorkerChannel channel,
  bool Function() isInitializing,
  void Function() markInitializing,
  void Function() resetInitializing,
) async {
  final context = getContext();

  if (context == null) {
    // Prevent concurrent initialization
    if (isInitializing()) {
      _log.warning('Received init message while already initializing');
      return;
    }
    markInitializing();

    try {
      // First message must be InitConfig
      if (data['type'] != 'InitConfig') {
        throw StateError(
            'Expected InitConfig as first message, got: ${data['type']}');
      }

      _log.info('Worker initializing...');

      // Parse config (recursively convert JsLinkedHashMaps)
      final configMap = data['config'] as Map<String, dynamic>;
        final activeStorageId = data['activeStorageId'] as String?;
        final activeRemoteList = data['activeRemoteIds'] as List?;
        final activeRemoteIds =
          activeRemoteList?.map((id) => id.toString()).toList();
      final config = SyncEngineConfig.fromJson(
          configMap); // Create context and initialize sync system
      final newContext = WorkerContext(WebWorkerSender(), channel);
      final workerParams = await workerSetup();
      final engineParams =
          await toEngineParams(workerParams, newContext, config,
            activeStorageId: activeStorageId,
            activeRemoteIds: activeRemoteIds);
      final syncSystem =
          await SyncEngine.create(engineParams: engineParams, config: config);
      newContext.setSyncSystem(syncSystem);

      setContext(newContext);

      // Send ready signal to main thread
      _postMessage('ready'.toJS);
      _log.info('Worker initialized and ready');
    } catch (e, st) {
      // Log error with full details
      _log.severe('Worker initialization failed: $e\n$st');

      // Send error to main thread
      _postMessage({
        'type': 'error',
        'error': 'Initialization failed: $e',
        'stackTrace': '$st',
      }.jsify());

      // CRITICAL: Reset initialization flag so worker can retry
      resetInitializing();
    }
  } else {
    // Worker is initialized - handle framework messages
    try {
      await context.handleMessage(data);
    } catch (e, st) {
      // Log but don't crash worker
      _log.severe('Error handling message: $e\n$st');
      rethrow; // Propagate to outer catchError
    }
  }
}
