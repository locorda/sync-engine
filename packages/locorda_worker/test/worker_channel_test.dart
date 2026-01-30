import 'dart:async';

import 'package:locorda_worker/src/worker/worker_channel.dart';
import 'package:test/test.dart';

void main() {
  group('WorkerChannel', () {
    test('sends messages through provided callback', () async {
      final sentMessages = <Object?>[];
      final channel = testChannel((msg) => sentMessages.add(msg));

      channel.send('test message');
      channel.send({'key': 'value'});
      channel.send(42);

      expect(sentMessages, [
        'test message',
        {'key': 'value'},
        42
      ]);
    });

    test('delivers messages to stream', () async {
      final channel = WorkerChannel((_) {});
      final receivedMessages = <Object?>[];

      // Listen to incoming messages
      final subscription = channel.messages.listen(receivedMessages.add);

      // Simulate receiving messages from transport layer
      channel.deliver('test', 'message 1');
      channel.deliver('test', {'data': 'message 2'});
      channel.deliver('test', null);

      // Wait for stream to process
      await Future.delayed(Duration.zero);

      expect(receivedMessages, [
        'message 1',
        {'data': 'message 2'},
        null
      ]);

      await subscription.cancel();
    });

    test('supports multiple listeners (broadcast stream)', () async {
      final channel = WorkerChannel((_) {});
      final listener1Messages = <Object?>[];
      final listener2Messages = <Object?>[];

      // Multiple listeners should work (broadcast stream)
      final sub1 = channel.messages.listen(listener1Messages.add);
      final sub2 = channel.messages.listen(listener2Messages.add);

      channel.deliver('test', 'broadcast message');
      await Future.delayed(Duration.zero);

      expect(listener1Messages, ['broadcast message']);
      expect(listener2Messages, ['broadcast message']);

      await sub1.cancel();
      await sub2.cancel();
    });

    test('bidirectional communication', () async {
      // Simulate two sides of the channel
      final messagesFromA = <Object?>[];
      final messagesFromB = <Object?>[];

      // Create channels with late initialization
      late final WorkerChannel channelA;
      late final WorkerChannel channelB;

      channelA = WorkerChannel((msg) => channelB.deliver('test', msg));
      channelB = WorkerChannel((msg) => channelA.deliver('test', msg));

      channelA.messages.listen(messagesFromA.add);
      channelB.messages.listen(messagesFromB.add);

      // A sends to B
      channelA.send('test', 'hello from A');
      await Future.delayed(Duration.zero);
      expect(messagesFromB, ['hello from A']);

      // B sends to A
      channelB.send('test', 'reply from B');
      await Future.delayed(Duration.zero);
      expect(messagesFromA, ['reply from B']);
    });

    test('close stops accepting new deliveries', () async {
      final channel = WorkerChannel((_) {});
      final receivedMessages = <Object?>[];
      bool streamDone = false;

      final subscription = channel.messages.listen(
        receivedMessages.add,
        onDone: () => streamDone = true,
      );

      channel.deliver('test', 'before close');
      await Future.delayed(Duration.zero);

      await channel.close();
      await Future.delayed(Duration.zero);

      // After close, stream should be done
      expect(streamDone, isTrue);
      expect(receivedMessages, ['before close']);

      await subscription.cancel();
    });

    test('handles JSON-serializable types', () async {
      final sentMessages = <Object?>[];
      final channel = testChannel((msg) => sentMessages.add(msg));

      // Common JSON-serializable types
      channel.send('string');
      channel.send(123);
      channel.send(45.67);
      channel.send(true);
      channel.send(null);
      channel.send(['list', 'of', 'items']);
      channel.send({
        'nested': {'map': 'structure'}
      });

      expect(sentMessages, [
        'string',
        123,
        45.67,
        true,
        null,
        ['list', 'of', 'items'],
        {
          'nested': {'map': 'structure'}
        },
      ]);
    });

    test('multiple sends and delivers in sequence', () async {
      final sentMessages = <Object?>[];
      final channel = WorkerChannel((msg) => sentMessages.add(msg));
      final receivedMessages = <Object?>[];

      channel.messages.listen(receivedMessages.add);

      // Interleaved sends and delivers
      channel.send('test', 'send 1');
      channel.deliver('test', 'receive 1');
      channel.send('test', 'send 2');
      channel.deliver('test', 'receive 2');

      await Future.delayed(Duration.zero);

      expect(sentMessages, ['send 1', 'send 2']);
      expect(receivedMessages, ['receive 1', 'receive 2']);
    });
  });
}

WorkerHandlerChannel testChannel(void Function(Object?) messageSender) {
  return WorkerChannel((msg) => messageSender(msg.data)).createChannel("test");
}
