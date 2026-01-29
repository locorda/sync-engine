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

  WorkerHandlerChannel(this.channel, this._workerChannel);

  /// Send a message on this plugin channel.
  void send(Object? message) {
    _workerChannel.send(channel, message);
  }

  /// Stream of incoming messages on this plugin channel.
  Stream<Object?> get messages => _workerChannel.messages
      .where((msg) => msg.channel == channel)
      .map((msg) => msg.data);
}

/// Bidirectional communication channel between main thread and worker.
///
/// Framework-agnostic: Apps define their own message types and protocols.
/// Messages are transmitted as JSON-serializable objects.
class WorkerChannel {
  final StreamController<WorkerChannelMessage> _incomingController =
      StreamController.broadcast();
  final void Function(WorkerChannelMessage message) _sendMessage;

  WorkerChannel(this._sendMessage);

  /// Send a message to the other side of the channel (main ↔ worker).
  void send(String channel, Object? message) {
    _sendMessage(WorkerChannelMessage(channel, message));
  }

  /// Stream of incoming messages from the other side.
  Stream<WorkerChannelMessage> get messages => _incomingController.stream;

  /// Internal: Deliver incoming message from transport layer.
  void deliver(String channel, Object? message) {
    _incomingController.add(WorkerChannelMessage(channel, message));
  }

  /// Close the channel and clean up resources.
  Future<void> close() async {
    await _incomingController.close();
  }
}
