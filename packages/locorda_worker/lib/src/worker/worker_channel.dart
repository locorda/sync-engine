/// Generic message channel for worker-main thread communication.
///
/// Provides a bidirectional pub/sub message bus for app-specific communication
/// that goes beyond the framework's standard SyncEngine operations.
///
/// Use cases:
/// - Authentication credential updates (Solid, OAuth, etc.)
/// - Custom background tasks
/// - App-specific sync strategies
/// - Plugin/extension communication
///
/// The framework provides the channel, apps define their own message types.
library;

import 'dart:async';

class WorkerChannelMessage {
  final String channel;
  final Object? data;

  WorkerChannelMessage(this.channel, this.data);
}

class WorkerHandlerChannel {
  final String channel;
  final WorkerChannel _workerChannel;
  final List<Object?> _buffer = [];
  StreamController<Object?>? _controller;
  late final StreamSubscription<Object?> _subscription;
  bool _hasListener = false;

  WorkerHandlerChannel._(this.channel, this._workerChannel) {
    // Subscribe immediately to start buffering messages
    _subscription = _workerChannel.messages
        .where((msg) => msg.channel == channel)
        .map((msg) => msg.data)
        .listen(_onMessage);
  }

  void _onMessage(Object? data) {
    if (_controller != null) {
      // Controller exists - deliver directly
      _controller!.add(data);
    } else {
      // No listener yet - buffer message
      _buffer.add(data);
    }
  }

  /// Send a message on this plugin channel.
  void send(Object? message) {
    _workerChannel.send(channel, message);
  }

  /// Stream of incoming messages on this plugin channel.
  /// First listener triggers replay of buffered messages.
  Stream<Object?> get messages {
    if (_controller == null) {
      _controller = StreamController<Object?>.broadcast(
        onListen: _onFirstListen,
      );
    }
    return _controller!.stream;
  }

  void _onFirstListen() {
    if (_hasListener) return;
    _hasListener = true;

    // Replay all buffered messages
    for (final msg in _buffer) {
      _controller!.add(msg);
    }
    _buffer.clear();
  }

  void dispose() {
    _subscription.cancel();
    _controller?.close();
    _buffer.clear();
  }
}

/// Bidirectional communication channel between main thread and worker.
///
/// Framework-agnostic: Apps define their own message types and protocols.
/// Messages are transmitted as JSON-serializable objects.
class WorkerChannel {
  final StreamController<WorkerChannelMessage> _incomingController =
      StreamController.broadcast();
  final void Function(WorkerChannelMessage message) _sendMessage;
  final Map<String, WorkerHandlerChannel> _cachedChannels = {};

  WorkerChannel(this._sendMessage);

  /// Send a message to the other side of the channel (main ↔ worker).
  void send(String channel, Object? message) {
    _sendMessage(WorkerChannelMessage(channel, message));
  }

  /// Stream of incoming messages from the other side.
  Stream<WorkerChannelMessage> get messages => _incomingController.stream;

  /// Internal: Deliver incoming message from transport layer.
  /// Lazily creates and caches channel to buffer messages before first subscription.
  void deliver(String channel, Object? message) {
    // Ensure channel exists to start buffering immediately
    _getOrCreateChannel(channel);
    _incomingController.add(WorkerChannelMessage(channel, message));
  }

  /// Creates or retrieves a buffering channel for the plugin with the given [name].
  WorkerHandlerChannel createChannel(String name) {
    return _getOrCreateChannel(name);
  }

  WorkerHandlerChannel _getOrCreateChannel(String name) {
    return _cachedChannels.putIfAbsent(
      name,
      () => WorkerHandlerChannel._(name, this),
    );
  }

  /// Close the channel and clean up resources.
  Future<void> close() async {
    for (final channel in _cachedChannels.values) {
      channel.dispose();
    }
    _cachedChannels.clear();
    await _incomingController.close();
  }
}
