import 'dart:async';

import 'package:locorda_core/locorda_core.dart';
import 'package:logging/logging.dart';
import 'package:rxdart/rxdart.dart';

final _performanceLog = Logger('perf.backend');
//final _operationsLog = Logger('perf.ops.backend');

abstract interface class Perflog {
  static const disabled = DisabledPerflog();

  const Perflog();

  static Perflog root({
    bool includeArgs = true,
    int contextWidth = 20,
    int operationWidth = 40,
    int argsWidth = 150,
  }) =>
      LoggingPerflog.root(
          includeArgs: includeArgs,
          contextWidth: contextWidth,
          operationWidth: operationWidth,
          argsWidth: argsWidth);

  Perflog create(String name, Object target, {bool? includeArgs});

  Future<T> measure<T>(String operation, Future<T> Function() action,
      {List<String>? args,
      int? minDurationMs,
      List<String> Function(T)? resultArgsBuilder});

  Future<void> dispose() => Future.value();
}

class DisabledPerflog extends Perflog {
  const DisabledPerflog();
  @override
  Perflog create(String name, Object target, {bool? includeArgs}) => this;

  @override
  Future<T> measure<T>(String operation, Future<T> Function() action,
          {List<String>? args,
          int? minDurationMs,
          List<String> Function(T)? resultArgsBuilder}) =>
      action();
}

class CallStackEntry {
  final List<String> names;
  final List<String> targetTypeNames;
  final String operation;
  CallStackEntry(this.names, this.targetTypeNames, this.operation);
}

class CallStackTracker {
  List<CallStackEntry> _stack = [];
  CallStackEntry enter(LoggingPerflog perflog, String operation) {
    final entry =
        CallStackEntry(perflog._names, perflog._targetTypeNames, operation);
    _stack.add(entry);
    return entry;
  }

  List<CallStackEntry> exit(CallStackEntry entry) {
    // This might seem a bit unusual, but the idea is, that traced operations
    // are all async and might be interleaved in any order. Only parents that
    // were parents during both enter and exit should be considered as parents,
    // so we don't assume that we are last but simply remove ourselves, returning
    // the parents we had.
    final result = _stack.takeWhile((e) => e != entry).toList();
    _stack.removeWhere((e) => entry == e);
    return result;
  }
}

class LoggingPerflog implements Perflog {
  final List<String> _names;
  final List<String> _targetTypeNames;
  final bool _includeArgs;
  final int contextWidth;
  final int operationWidth;
  final int argsWidth;
  final CallStackTracker _tracker;

  LoggingPerflog._({
    required List<String> names,
    required List<String> targetTypeNames,
    bool includeArgs = false,
    required this.contextWidth,
    required this.operationWidth,
    required this.argsWidth,
    required CallStackTracker tracker,
  })  : _names = names,
        _targetTypeNames = targetTypeNames,
        _includeArgs = includeArgs,
        _tracker = tracker;

  static Perflog root({
    bool includeArgs = true,
    int contextWidth = 30,
    int operationWidth = 30,
    int argsWidth = 50,
  }) =>
      LoggingPerflog._(
          names: [],
          targetTypeNames: [],
          includeArgs: includeArgs,
          contextWidth: contextWidth,
          operationWidth: operationWidth,
          argsWidth: argsWidth,
          tracker: CallStackTracker());

  static String _toTargetTypeName(Object target) =>
      target is String ? target : target.runtimeType.toString();

  Perflog create(String name, Object target, {bool? includeArgs}) =>
      LoggingPerflog._(
        names: [..._names, name],
        targetTypeNames: [..._targetTypeNames, _toTargetTypeName(target)],
        includeArgs: includeArgs ?? _includeArgs,
        contextWidth: contextWidth,
        operationWidth: operationWidth,
        argsWidth: argsWidth,
        tracker: _tracker,
      );

  /// Shortens a string to maxLength by placing ellipsis in the middle
  static String _shortenMiddle(String text, int maxLength,
      {bool preferEnd = false, String borderEllipis = '...'}) {
    if (text.length <= maxLength) return text;
    if (maxLength < 3) return text.substring(0, maxLength);
    if (maxLength < 10) {
      return text.substring(0, maxLength - borderEllipis.length) +
          borderEllipis;
    }
    if (maxLength < 10 && preferEnd) {
      return borderEllipis +
          text.substring(text.length - (maxLength - borderEllipis.length));
    }
    final leftLen = (maxLength - 3) ~/ 2;
    final rightLen = maxLength - 3 - leftLen;
    return '${text.substring(0, leftLen)}...${text.substring(text.length - rightLen)}';
  }

  /// Formats args for display: shows first and last (if multiple), shortened with ellipsis
  static String _formatArgs(List<String> args, int maxLength) {
    if (args.isEmpty) return '';
    if (args.length == 1) return _shortenMiddle(args[0], maxLength);
    //final listMiddle=', ..., ';
    final listMiddle = '|||';
    var maxArgLength = (maxLength - listMiddle.length) ~/ 2;
    final first = _shortenMiddle(args.first, maxArgLength,
        borderEllipis: ''); // No ellipsis for first arg to maximize info
    maxArgLength = (maxLength - listMiddle.length) - first.length;
    final last = _shortenMiddle(args.last, maxArgLength,
        preferEnd: true, borderEllipis: '');
    return '$first$listMiddle$last';
  }

  Future<T> measure<T>(String operation, Future<T> Function() action,
      {List<String>? args,
      int? minDurationMs,
      List<String> Function(T)? resultArgsBuilder}) async {
    //_operationsLog.info('$contextStr.$opPadded $argsStr');
    final entry = _tracker.enter(this, operation);
    final stopwatch = Stopwatch()..start();
    T? result;
    try {
      final r = await action();
      result = r;
      return r;
    } finally {
      stopwatch.stop();
      final parentStack = _tracker.exit(entry);
      final elapsedMs = stopwatch.elapsedMilliseconds;
      final threshold = minDurationMs ?? 0;
      if (elapsedMs >= threshold) {
        final opPadded = _shortenMiddle(
                ('.' * parentStack.length) + operation, operationWidth)
            .padRight(operationWidth);
        final resultArgs = resultArgsBuilder != null && result != null
            ? resultArgsBuilder(result)
            : <String>[];
        final argsStr = _includeArgs
            ? _formatAndPadList(
                resultArgs.isEmpty
                    ? args
                    : [if (args != null) ...args, ...resultArgs],
                argsWidth)
            : '';
        final contextStr = _formatAndPadList(_names, contextWidth);
        final duration = '$elapsedMs ms'.padLeft(8);
        _performanceLog.info('$contextStr $opPadded $duration $argsStr');
      }
    }
  }

  String _formatAndPadList(List<String>? args, int argsWidth) {
    return (args != null && args.isNotEmpty ? _formatArgs(args, argsWidth) : '')
        .padRight(argsWidth);
  }

  Future<void> dispose() async {
    // No resources to clean up in this implementation, but method provided for symmetry and future extensibility.
  }
}

class PerflogPipelineBackend implements PipelineBackend {
  final PipelineBackend _inner;
  final Perflog _perflog;
  late final BehaviorSubject<List<PipelineRemoteStorage>> _remotesSubject;
  late final StreamSubscription<List<PipelineRemoteStorage>>
      _remotesSubscription;

  PerflogPipelineBackend(
    this._inner, {
    String name = 'PipelineBackend',
    bool? includeArgs,
    required Perflog perflog,
  }) : _perflog = perflog.create(name, _inner, includeArgs: includeArgs) {
    _remotesSubject =
        BehaviorSubject.seeded(wrapRemotes(_inner.pipelineRemotes));
    _remotesSubscription = _inner.pipelineRemotesChanged.listen((remotes) {
      _remotesSubject.add(wrapRemotes(remotes));
    });
  }
  List<PipelineRemoteStorage> wrapRemotes(
          List<PipelineRemoteStorage> remotes) =>
      remotes
          .map((r) => PerflogPipelineRemoteStorage(r, perflog: _perflog))
          .toList();

  @override
  Future<void> dispose() async {
    await _perflog.measure('PipelineBackend.dispose', () async {
      await _remotesSubscription.cancel();
      return _inner.dispose();
    });
    await _perflog.dispose();
  }

  @override
  String get name => _inner.name;

  @override
  List<PipelineRemoteStorage> get pipelineRemotes => _remotesSubject.value;

  @override
  Stream<List<PipelineRemoteStorage>> get pipelineRemotesChanged =>
      _remotesSubject.stream;

  @override
  String toString() => 'Perflog(${_inner.toString()})';
}

class PerflogPipelineRemoteStorage implements PipelineRemoteStorage {
  final PipelineRemoteStorage _inner;
  final Perflog _perflog;

  PerflogPipelineRemoteStorage(
    this._inner, {
    required Perflog perflog,
    String name = 'RemoteStorage',
    bool? includeArgs,
  }) : _perflog = perflog.create(name, _inner, includeArgs: includeArgs);

  @override
  Future<PipelineRemoteSyncStorage> createPipelineSyncStorage(
          SyncEngineConfig config) =>
      _perflog.measure(
        'createPipelineSyncStorage',
        () => _inner.createPipelineSyncStorage(config),
      );

  @override
  Future<bool> isAvailable() =>
      _perflog.measure('isAvailable', () => _inner.isAvailable());

  @override
  RemoteId get remoteId => _inner.remoteId;

  @override
  Future<void> dispose() async {
    await _perflog.dispose();
  }

  @override
  String toString() => 'Perflog(${_inner.toString()})';
}
