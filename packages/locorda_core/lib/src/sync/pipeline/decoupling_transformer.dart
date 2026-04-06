/// A [StreamTransformer] that decouples upstream production from downstream
/// consumption by inserting a buffered [StreamController] between them.
///
/// In a Dart stream chain, `asyncExpand` / `asyncMap` pause their upstream
/// subscription while processing. This back-pressure propagates through all
/// synchronous operators (`map`, `expand`, `where`) back to the previous
/// async barrier — preventing any interleaving of IO and CPU work.
///
/// Inserting a [DecouplingTransformer] breaks that pause-propagation chain:
/// while downstream awaits IO (yielding to the event loop), upstream can
/// continue producing into the buffer. The event loop schedules both sides
/// cooperatively, achieving true concurrency on a single isolate.
///
/// Back-pressure is maintained via [maxBuffered]: when the buffer reaches
/// capacity, the upstream subscription is paused until downstream catches up.
///
/// ## Event-loop turn tracking
///
/// The transformer instruments downstream delivery with event-loop turn
/// tracking: a `Timer.run` callback marks the boundary between event-loop
/// turns, and the transformer counts how many events were delivered in each
/// turn. If a turn delivers hundreds of events, all that work happened as
/// **microtasks** within a single turn — meaning no I/O callbacks fired in
/// between.
///
/// The summary is logged at INFO level when the stream completes:
/// ```
/// DecouplingTransformer (S04) done: peak=128/1280, upstreamPauses=0,
///   eventLoopTurns=12, maxEventsPerTurn=2015, avgEventsPerTurn=1300.2
/// ```
library;

import 'dart:async';

import 'package:logging/logging.dart';

final _log = Logger('pipeline');

/// Creates a [StreamTransformer] that decouples upstream from downstream.
///
/// Events are buffered in an internal [StreamController]. When the buffer
/// reaches [maxBuffered] events, upstream is paused until downstream
/// consumes enough to drop below the threshold.
///
/// The transformer preserves event ordering and propagates errors and
/// completion in both directions. Cancelling the downstream subscription
/// cancels the upstream subscription.
///
/// Includes event-loop turn tracking: logs how many events are delivered per
/// event-loop turn (microtask burst size). High values indicate that the
/// async [StreamController] bunches all deliveries into microtasks, starving
/// I/O callbacks.
StreamTransformer<T, T> decouplingTransformer<T>(String afterStage,
    {int maxBuffered = 64}) {
  return StreamTransformer<T, T>.fromBind((Stream<T> input) {
    final controller = StreamController<T>();
    StreamSubscription<T>? subscription;
    var buffered = 0;
    var maxObserved = 0;
    var upstreamPauses = 0;
    var upstreamDone = false;

    // TODO(cleanup): Event-loop turn tracking is diagnostic-only.
    // Consider removing once pipeline configuration is finalized.
    // A Timer.run callback fires when the event loop regains control after
    // draining the microtask queue. Between two such callbacks, every event
    // delivery was a microtask.
    var turnProbeScheduled = false;
    var eventsThisTurn = 0;
    var maxEventsPerTurn = 0;
    var totalTurns = 0;
    var totalEventsDelivered = 0;

    void resumeIfNeeded() {
      if (buffered < maxBuffered && !upstreamDone) {
        subscription?.resume();
      }
    }

    controller.onListen = () {
      subscription = input.listen(
        (event) {
          controller.add(event);
          buffered++;
          if (buffered > maxObserved) maxObserved = buffered;
          if (buffered >= maxBuffered) {
            subscription!.pause();
            upstreamPauses++;
          }
        },
        onError: controller.addError,
        onDone: () {
          upstreamDone = true;
          final avgPerTurn = totalTurns > 0
              ? (totalEventsDelivered / totalTurns).toStringAsFixed(1)
              : 'N/A';
          _log.info('DecouplingTransformer ($afterStage) done: '
              'peak=$maxObserved/$maxBuffered, upstreamPauses=$upstreamPauses, '
              'eventLoopTurns=$totalTurns, maxEventsPerTurn=$maxEventsPerTurn, '
              'avgEventsPerTurn=$avgPerTurn');
          controller.close();
        },
      );
    };

    controller.onCancel = () {
      final sub = subscription;
      subscription = null;
      return sub?.cancel() ?? Future.value();
    };

    controller.onPause = () {
      // Downstream paused — don't need to pause upstream here,
      // the controller itself buffers. But if we're already at capacity,
      // upstream is already paused.
    };

    controller.onResume = () {
      // Downstream resumed — if upstream was paused due to backpressure,
      // resume it.
      resumeIfNeeded();
    };

    // Track consumption via a wrapper stream that decrements the counter
    // and records event-loop turn statistics.
    return controller.stream.transform(
      StreamTransformer<T, T>.fromBind((Stream<T> bufferedStream) {
        return bufferedStream.map((event) {
          buffered--;
          totalEventsDelivered++;
          eventsThisTurn++;
          // Schedule a Timer.run probe (event-queue level) to detect when
          // the current microtask burst ends. All events delivered before
          // this callback fires were microtasks in the same turn.
          if (!turnProbeScheduled) {
            turnProbeScheduled = true;
            Timer.run(() {
              turnProbeScheduled = false;
              totalTurns++;
              if (eventsThisTurn > maxEventsPerTurn) {
                maxEventsPerTurn = eventsThisTurn;
              }
              _log.fine('DecouplingTransformer ($afterStage) turn $totalTurns: '
                  '$eventsThisTurn events delivered as microtasks');
              eventsThisTurn = 0;
            });
          }
          resumeIfNeeded();
          return event;
        });
      }),
    );
  });
}

/// Forces periodic yields to the event loop by inserting `Timer.run` breaks
/// every [yieldEvery] events.
///
/// TODO(cleanup): Experimental — kept for diagnostics only. Proven not
/// beneficial as a standalone optimization; deferredExpand is preferred.
///
/// **Purpose**: Tests the microtask starvation hypothesis. The default async
/// [StreamController] delivers events via microtasks, which Dart processes
/// completely before checking the event queue for I/O callbacks. This means
/// hundreds or thousands of stream events can fire without any I/O callback
/// (DB result, ReceivePort message) getting a chance to run.
///
/// This transformer inserts explicit event-queue yield points: every
/// [yieldEvery] events it awaits a [Timer.run] callback, allowing pending
/// I/O callbacks to fire before continuing.
///
/// **Usage**: Compose after a [decouplingTransformer] to compare behavior:
/// ```dart
/// // Microtask-only delivery (baseline):
/// .transform(decouplingTransformer("S04", maxBuffered: 10000))
///
/// // With event-loop yielding (test):
/// .transform(decouplingTransformer("S04", maxBuffered: 10000))
/// .transform(eventLoopYieldTransformer("S04→S05", yieldEvery: 50))
/// ```
///
/// If yielding improves interleaving (visible in pipeperf overlap%), the
/// microtask starvation hypothesis is confirmed.
StreamTransformer<T, T> eventLoopYieldTransformer<T>(String label,
    {int yieldEvery = 50}) {
  return StreamTransformer<T, T>.fromBind((Stream<T> input) async* {
    var sinceYield = 0;
    var totalYields = 0;
    await for (final event in input) {
      yield event;
      sinceYield++;
      if (sinceYield >= yieldEvery) {
        sinceYield = 0;
        totalYields++;
        // Timer.run schedules on the event queue, NOT the microtask queue.
        // Awaiting it lets pending I/O callbacks fire before we continue.
        await _yieldToEventLoop();
      }
    }
    _log.info('EventLoopYieldTransformer ($label) done: '
        'totalYields=$totalYields, yieldEvery=$yieldEvery');
  });
}

/// Yields control to the event loop by scheduling a Timer.run callback.
///
/// Unlike `Future.value()` or `scheduleMicrotask`, `Timer.run` places the
/// callback on the **event queue**. The Dart event loop processes all pending
/// microtasks first, then checks the event queue — so awaiting this Future
/// guarantees that any pending I/O callbacks (ReceivePort messages from Drift
/// isolates, file I/O completions, etc.) get a chance to fire.
Future<void> _yieldToEventLoop() {
  final completer = Completer<void>();
  Timer.run(completer.complete);
  return completer.future;
}

/// Wraps a synchronous `expand` callback so it runs on the **event queue**
/// instead of inline on the microtask queue.
///
/// Dart's `Stream.expand` executes the callback synchronously and emits all
/// results as microtasks — no I/O callback can fire in between. This function
/// returns an `asyncExpand` callback that:
///
/// 1. Yields to the event loop via `Timer.run` **before** running [fn].
/// 2. Executes [fn] synchronously (pure CPU, same as `.expand`).
/// 3. Emits the results as a `Stream.fromIterable`.
///
/// The initial yield gives pending I/O callbacks (Drift ReceivePort messages,
/// file completions) a chance to run before the CPU-heavy expand blocks the
/// event loop again.
///
/// Usage:
/// ```dart
/// // Instead of:
/// .expand(mergeCandidates(...))
/// // Use:
/// .asyncExpand(deferredExpand(mergeCandidates(...)))
/// ```
Stream<T> Function(S) deferredExpand<S, T>(Iterable<T> Function(S) fn) {
  return (S event) async* {
    await _yieldToEventLoop();
    final results = fn(event);
    for (final item in results) {
      yield item;
    }
  };
}

/// TODO(cleanup): Experimental — unused. Remove if deferredExpand proves
/// sufficient for all CPU-stage interleaving needs.
Future<T> Function(S) deferredMap<S, T>(T Function(S) fn) {
  return (S event) async {
    await _yieldToEventLoop();
    final result = fn(event);
    return result;
  };
}
