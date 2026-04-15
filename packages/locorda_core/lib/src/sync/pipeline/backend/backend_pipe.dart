/// Deque-based cross-shard batching pipe for backend I/O stages.
///
/// Shared infrastructure for [FilePerResourceRemoteSyncStorage] and
/// [ShardDatasetRemoteSyncStorage]. Pipes input events through a backend
/// stream (download or upload), matching results by composite key
/// (document IRI + request ETag) rather than positional order.
///
/// Supports three event classifications:
/// - [BackendRequest] → dispatched to the backend stream
/// - [BackendBoundary] → blocks flush until all preceding entries resolve
/// - [BackendPassThrough] → pre-resolved, emitted in deque order
library;

import 'dart:async';

import 'package:locorda_rdf_core/core.dart';
import 'package:logging/logging.dart';

import '../pipeperf.dart';

/// Composite key for matching backend results to deque entries.
/// Combines document IRI with the conditional request ETag to distinguish
/// requests for the same resource with different ETags across shards.
typedef CacheKey = (IriTerm iri, String? requestETag);

// ---------------------------------------------------------------------------
// PipeEntry — event classification and deque entry
// ---------------------------------------------------------------------------

/// Classification of an input event for [backendPipe].
/// Also used directly as deque entries in [_DequeState].
sealed class PipeEntry<TData, TOut, TReq> {
  const PipeEntry();
}

/// Backend request to be dispatched. Contains the cache key, original data,
/// and the pre-built request object.
final class BackendRequest<TData, TOut, TReq>
    extends PipeEntry<TData, TOut, TReq> {
  final CacheKey key;
  final TData data;
  final TReq request;
  const BackendRequest(this.key, this.data, this.request);
}

/// Segment delimiter (ShardComplete, PhaseComplete, etc.). Blocks flush
/// until all preceding entries have resolved.
final class BackendBoundary<TData, TOut, TReq>
    extends PipeEntry<TData, TOut, TReq> {
  final TOut outputEvent;
  const BackendBoundary(this.outputEvent);
}

/// Pre-resolved event (ResourceError, non-fetched candidates). Emitted
/// in deque order — never blocks flush.
final class BackendPassThrough<TData, TOut, TReq>
    extends PipeEntry<TData, TOut, TReq> {
  final TOut outputEvent;
  const BackendPassThrough(this.outputEvent);
}

// ---------------------------------------------------------------------------
// backendPipe — the shared pipe function
// ---------------------------------------------------------------------------

/// Pipes events through a backend stream using deque-based cross-shard
/// batching. Requests are sent immediately without waiting for shard
/// boundaries; results are matched by composite key (documentIri +
/// requestETag).
///
/// Each input event is classified by [classify] into one of:
/// - [BackendRequest] → dispatched to the backend stream
/// - [BackendBoundary] → blocks flush until all preceding entries resolve
/// - [BackendPassThrough] → pre-resolved, emitted in deque order
Stream<TOut> backendPipe<TData, TIn, TOut, TReq, TRes>({
  required Stream<TIn> stream,
  required PipeEntry<TData, TOut, TReq> Function(TIn) classify,
  required CacheKey Function(TRes) resultKey,
  required TOut Function(TData, TRes) toOutput,
  TOut Function(TData, Object error, StackTrace stackTrace)? onError,
  required Stream<TRes> Function(Stream<TReq>) backendCall,
  required Logger logger,
  PipeperfCollector? perf,
  String? perfStage,
}) {
  final out = StreamController<TOut>();
  final requestSink = StreamController<TReq>();
  final backendStream = backendCall(requestSink.stream);

  late final _DequeState<TData, TOut, TReq, TRes> deque;
  StreamSubscription<TIn>? inputSub;
  StreamSubscription<TRes>? backendSub;

  var inputDone = false;
  var backendFailed = false;
  Object? backendError;
  StackTrace? backendStack;

  void checkDone() {
    if (inputDone && deque.isEmpty && !out.isClosed) {
      out.close();
    }
  }

  deque = _DequeState<TData, TOut, TReq, TRes>(
    toOutput: toOutput,
    onError: onError,
    resultKey: resultKey,
    emit: (event) {
      if (!out.isClosed) out.add(event);
    },
  );

  out.onListen = () {
    // Active-interval I/O tracking: measures the union of all in-flight
    // backend request intervals, avoiding double-counting of overlapping
    // batch requests. Stopwatch runs while pendingIo > 0.
    var pendingIo = 0;
    PipeperfClock? swIo;

    backendSub = backendStream.listen(
      (result) {
        if (--pendingIo == 0) {
          swIo?.stop();
          swIo = null;
        }
        deque.addResult(result);
        checkDone();
      },
      onDone: () {
        // A non-empty deque here means at least one BackendRequest is
        // unresolved: _flushLeading drains leading Boundary/PassThrough
        // entries eagerly, so they never block behind a BackendRequest.
        // errorRemaining correctly errors only BackendRequest entries and
        // emits Boundaries/PassThroughs normally — no events are lost.
        if (!deque.isEmpty) {
          backendFailed = true;
          backendError = StateError(
              'Backend stream ended with items pending in $perfStage');
          backendStack = StackTrace.current;
          logger.warning('$backendError');
          deque.errorRemaining(backendError!, backendStack!);
        }
        checkDone();
      },
      onError: (Object e, StackTrace st) {
        backendFailed = true;
        backendError = e;
        backendStack = st;
        logger.warning('Backend failed in $perfStage: $e', e, st);
        deque.errorRemaining(e, st);
        checkDone();
      },
    );

    inputSub = stream.listen(
      (event) {
        final entry = classify(event);
        switch (entry) {
          case BackendRequest<TData, TOut, TReq>():
            if (backendFailed) {
              if (onError != null && !out.isClosed) {
                out.add(onError(entry.data, backendError!,
                    backendStack ?? StackTrace.current));
              }
            } else {
              deque.addData(entry);
              if (pendingIo++ == 0) {
                swIo = perf?.start('$perfStage.io');
              }
              requestSink.add(entry.request);
            }
          case BackendBoundary<TData, TOut, TReq>():
            deque.addBoundary(entry);
          case BackendPassThrough<TData, TOut, TReq>():
            deque.addPassThrough(entry);
        }
      },
      onDone: () {
        inputDone = true;
        unawaited(requestSink.close());
        checkDone();
      },
      onError: (Object e, StackTrace st) {
        if (!out.isClosed) out.addError(e, st);
        inputDone = true;
        unawaited(requestSink.close());
        checkDone();
      },
    );
  };

  out.onCancel = () async {
    await inputSub?.cancel();
    await backendSub?.cancel();
    unawaited(requestSink.close());
  };

  return out.stream;
}

// ---------------------------------------------------------------------------
// _DequeState — internal deque and result cache
// ---------------------------------------------------------------------------

/// Manages the deque and result cache for cross-shard batching.
///
/// Uses [PipeEntry] directly as deque entries. Backend requests for multiple
/// shards can be in-flight simultaneously. Results are matched by composite
/// key (IRI + request ETag) rather than positional order.
class _DequeState<TData, TOut, TReq, TRes> {
  final List<PipeEntry<TData, TOut, TReq>> _deque = [];
  final Map<CacheKey, List<TRes>> _resultCache = {};
  final TOut Function(TData, TRes) _toOutput;
  final TOut Function(TData, Object error, StackTrace stackTrace)? _onError;
  final void Function(TOut) _emit;
  final CacheKey Function(TRes) _resultKey;

  _DequeState({
    required TOut Function(TData, TRes) toOutput,
    TOut Function(TData, Object error, StackTrace stackTrace)? onError,
    required CacheKey Function(TRes) resultKey,
    required void Function(TOut) emit,
  })  : _toOutput = toOutput,
        _onError = onError,
        _emit = emit,
        _resultKey = resultKey;

  bool get isEmpty => _deque.isEmpty;

  /// Adds an in-flight data entry. Call after sending the request to backend.
  void addData(BackendRequest<TData, TOut, TReq> entry) {
    _deque.add(entry);
    _flushLeading();
  }

  /// Adds a segment boundary (ShardComplete, PhaseComplete, etc.).
  /// Emitted directly if the deque is empty (fast path).
  void addBoundary(BackendBoundary<TData, TOut, TReq> entry) {
    if (_deque.isEmpty) {
      _emit(entry.outputEvent);
    } else {
      _deque.add(entry);
      _flushLeading();
    }
  }

  /// Adds a pre-resolved pass-through entry (ResourceError, non-fetched items).
  /// Emitted directly if the deque is empty (fast path).
  void addPassThrough(BackendPassThrough<TData, TOut, TReq> entry) {
    if (_deque.isEmpty) {
      _emit(entry.outputEvent);
    } else {
      _deque.add(entry);
      _flushLeading();
    }
  }

  /// Scans the deque from front to the next boundary. If a matching
  /// [BackendRequest] is found before a boundary, it is emitted immediately
  /// and removed. Otherwise the result stays cached for later resolution
  /// via [_flushLeading].
  void addResult(TRes result) {
    final key = _resultKey(result);
    _resultCache.putIfAbsent(key, () => []).add(result);
    // Try response-order emit: scan to next boundary.
    for (var i = 0; i < _deque.length; i++) {
      final entry = _deque[i];
      if (entry is BackendBoundary<TData, TOut, TReq>) break;
      if (entry is BackendRequest<TData, TOut, TReq> && entry.key == key) {
        final cached = _resultCache[key]!;
        final res = cached.removeAt(0);
        if (cached.isEmpty) _resultCache.remove(key);
        _emit(_toOutput(entry.data, res));
        _deque.removeAt(i);
        // After removal, leading entries may now be unblocked.
        _flushLeading();
        return;
      }
    }
    // No match before boundary — result stays cached, try leading flush.
    _flushLeading();
  }

  /// Flushes resolved entries from the front of the deque.
  void _flushLeading() {
    while (_deque.isNotEmpty) {
      final entry = _deque.first;
      switch (entry) {
        case BackendRequest<TData, TOut, TReq>():
          final cached = _resultCache[entry.key];
          if (cached != null && cached.isNotEmpty) {
            final result = cached.removeAt(0);
            if (cached.isEmpty) _resultCache.remove(entry.key);
            _emit(_toOutput(entry.data, result));
            _deque.removeAt(0);
          } else {
            return; // blocked — waiting for backend result
          }
        case BackendBoundary<TData, TOut, TReq>():
          _emit(entry.outputEvent);
          _deque.removeAt(0);
        case BackendPassThrough<TData, TOut, TReq>():
          _emit(entry.outputEvent);
          _deque.removeAt(0);
      }
    }
  }

  /// Errors all remaining [BackendRequest] entries and emits remaining
  /// [BackendBoundary]/[BackendPassThrough] entries.
  /// Called when the backend stream ends prematurely or errors.
  void errorRemaining(Object error, StackTrace stackTrace) {
    for (final entry in _deque) {
      switch (entry) {
        case BackendRequest<TData, TOut, TReq>():
          if (_onError != null) {
            _emit(_onError(entry.data, error, stackTrace));
          }
        case BackendBoundary<TData, TOut, TReq>():
          _emit(entry.outputEvent);
        case BackendPassThrough<TData, TOut, TReq>():
          _emit(entry.outputEvent);
      }
    }
    _deque.clear();
    _resultCache.clear();
  }
}
