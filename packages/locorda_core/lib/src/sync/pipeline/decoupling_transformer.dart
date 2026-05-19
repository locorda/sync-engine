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
        onError: (Object error, StackTrace? stackTrace) {
          if (!controller.isClosed) {
            controller.addError(error, stackTrace);
          } else {
            _log.severe(
                'Error after stream closed in '
                'DecouplingTransformer ($afterStage)',
                error,
                stackTrace);
          }
        },
        onDone: () {
          upstreamDone = true;
          _log.info('DecouplingTransformer ($afterStage) done: '
              'peak=$maxObserved/$maxBuffered, upstreamPauses=$upstreamPauses');
          controller.close();
        },
      );
    };

    controller.onCancel = () {
      final sub = subscription;
      subscription = null;
      final isPaused = sub?.isPaused ?? false;
      final f = sub?.cancel();
      // Apparently, cancelling a paused subscription currently (Dart SDK 3.6)
      // returns a Future that never completes. The cancel IS initiated (resources ARE cleaned up),
      // but the Future doesn't resolve. So we fire-and-forget the upstream cancel in that case.
      return isPaused || f == null ? Future.value() : f;
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

    // Decrement buffer counter so upstream can be resumed when space frees.
    // Error events pass through .map() natively without calling the callback.
    return controller.stream.map((event) {
      buffered--;
      resumeIfNeeded();
      return event;
    });
  });
}

/// A [StreamTransformer] that defers a synchronous `expand` callback to the
/// **event queue**, enabling I/O interleaving between CPU-heavy expand calls.
///
/// For each upstream event:
/// 1. Pauses upstream (back-pressure during CPU work).
/// 2. Yields to the event loop via `Timer.run` — pending I/O callbacks fire.
/// 3. Executes [fn] synchronously.
/// 4. Emits results and resumes upstream.
///
/// Errors from [fn] are forwarded to downstream via [StreamController.addError]
/// without going through `addStream`, guaranteeing correct propagation.
StreamTransformer<S, T> deferredExpandTransformer<S, T>(
    String label, Iterable<T> Function(S) fn) {
  return StreamTransformer<S, T>.fromBind((Stream<S> input) {
    final controller = StreamController<T>();
    StreamSubscription<S>? subscription;

    void _cancelUpstream() {
      final sub = subscription;
      subscription = null;
      sub?.cancel();
    }

    controller.onListen = () {
      subscription = input.listen(
        (event) {
          subscription!.pause();
          void cb() {
            try {
              if (controller.isClosed) return;
              for (final item in fn(event)) {
                if (controller.isClosed) return;
                controller.add(item);
              }
            } catch (e, st) {
              // On error: forward downstream, cancel upstream, close.
              // This ensures Done is delivered even when the downstream
              // cancel-cascade races with Timer.run callbacks.
              if (!controller.isClosed) {
                controller.addError(e, st);
              }
              _cancelUpstream();
              if (!controller.isClosed) controller.close();
              return;
            }
            subscription?.resume();
          }

          Timer.run(cb);
        },
        onError: (Object error, StackTrace? stackTrace) {
          // Upstream error: forward, cancel, close — same pattern.
          if (!controller.isClosed) {
            controller.addError(error, stackTrace);
          }
          _cancelUpstream();
          if (!controller.isClosed) controller.close();
        },
        onDone: () {
          _log.fine('deferredExpandTransformer ($label) done');
          controller.close();
        },
      );
    };

    controller.onCancel = () {
      final sub = subscription;
      subscription = null;
      if (sub == null) return Future.value();
      final isPaused = sub.isPaused;
      final f = sub.cancel();
      // Dart SDK bug (3.6): cancel() on a paused subscription to an async*
      // StreamTransformer.fromBind stream returns a Future that never
      // completes. The cancel IS initiated, but the Future doesn't resolve.
      // Fire-and-forget when paused to avoid hanging the cancel cascade.
      return isPaused ? Future.value() : f;
    };
    controller.onPause = () => subscription?.pause();
    controller.onResume = () => subscription?.resume();

    return controller.stream;
  });
}

extension StreamX<T> on Stream<T> {
  /// A convenience method for `transform(deferredExpandTransformer(label, fn))`.
  Stream<V> deferredExpand<V>(String label, Iterable<V> Function(T) fn) =>
      transform(deferredExpandTransformer(label, fn));

  Stream<T> decoupled(String label, {int maxBuffered = 1280}) =>
      transform(decouplingTransformer(label, maxBuffered: maxBuffered));

  /// Drains this stream, completing on Done or the first error.
  ///
  /// Unlike [Stream.drain], this applies a timeout to the cancel Future
  /// to work around a Dart SDK bug (3.6) where `cancel()` on a paused
  /// subscription to an `async*` `StreamTransformer.fromBind` stream
  /// returns a Future that never completes.
  ///
  /// Use [onData] to inspect data events flowing through (e.g. to detect
  /// materialized error events that flow as data to bypass async*
  /// backpressure issues).
  ///
  /// On error, cancel is attempted with a [cancelTimeout] safety net.
  /// If the cancel Future doesn't complete in time, the error is still
  /// propagated and the cancel continues in the background.
  Future<void> safeDrain({
    Duration cancelTimeout = const Duration(milliseconds: 500),
    void Function(T)? onData,
  }) {
    final completer = Completer<void>();
    late final StreamSubscription<T> sub;
    sub = listen(
      onData,
      onError: (Object e, StackTrace st) {
        if (completer.isCompleted) return;
        sub.cancel().timeout(cancelTimeout, onTimeout: () {
          _log.warning(
            'safeDrain: cancel() timed out after $cancelTimeout — '
            'likely Dart SDK bug (paused async* subscription). '
            'Proceeding with error propagation.',
          );
        }).whenComplete(() {
          if (!completer.isCompleted) completer.completeError(e, st);
        });
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete();
      },
    );
    return completer.future;
  }
}
