import 'dart:async';

import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/storage/remote_storage.dart';
import 'package:locorda_rdf_core/src/dataset/rdf_dataset.dart';
import 'package:locorda_rdf_core/src/graph/rdf_graph.dart';
import 'package:locorda_rdf_core/src/graph/rdf_term.dart';
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
    if (maxLength < 10)
      return text.substring(0, maxLength - borderEllipis.length) +
          borderEllipis;
    if (maxLength < 10 && preferEnd)
      return borderEllipis +
          text.substring(text.length - (maxLength - borderEllipis.length));
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
            : [];
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

class PerflogBackend implements Backend {
  final Backend _inner;
  final Perflog _perflog;
  late final BehaviorSubject<List<RemoteStorage>> _remotesSubject;
  late final StreamSubscription _remotesSubscription;

  PerflogBackend(
    this._inner, {
    String name = 'Backend',
    bool? includeArgs,
    required Perflog perflog,
  }) : _perflog = perflog.create(name, _inner, includeArgs: includeArgs) {
    _remotesSubject = BehaviorSubject.seeded(wrapRemotes(_inner.remotes));
    _remotesSubscription = _inner.remotesChanged.listen((remotes) {
      _remotesSubject.add(wrapRemotes(remotes));
    });
  }
  List<RemoteStorage> wrapRemotes(List<RemoteStorage> remotes) =>
      remotes.map((r) => PerflogRemoteStorage(r, perflog: _perflog)).toList();

  @override
  Future<void> dispose() async {
    await _perflog.measure('Backend.dispose', () async {
      await _remotesSubscription.cancel();
      return _inner.dispose();
    });
    await _perflog.dispose();
  }

  @override
  String get name => _inner.name;

  @override
  List<RemoteStorage> get remotes => _remotesSubject.value;

  @override
  Stream<List<RemoteStorage>> get remotesChanged => _remotesSubject.stream;

  @override
  String toString() => 'Perflog(${_inner.toString()})';
}

class PerflogRemoteStorage implements RemoteStorage {
  final RemoteStorage _inner;
  final Perflog _perflog;

  PerflogRemoteStorage(
    this._inner, {
    required Perflog perflog,
    String name = 'RemoteStorage',
    bool? includeArgs,
  }) : _perflog = perflog.create(name, _inner, includeArgs: includeArgs);

  @override
  Future<RemoteSyncStorage> createSyncStorage(SyncEngineConfig config) =>
      _perflog.measure(
          'createSyncStorage',
          () async => PerflogRemoteSyncStorage(
              await _inner.createSyncStorage(config),
              perflog: _perflog));

  @override
  Future<bool> isAvailable() =>
      _perflog.measure('isAvailable', () => _inner.isAvailable());

  @override
  RemoteId get remoteId => _inner.remoteId;

  @override
  bool get useShardDatasets => _inner.useShardDatasets;

  @override
  Future<void> dispose() async {
    await _perflog.dispose();
  }

  @override
  String toString() => 'Perflog(${_inner.toString()})';
}

class PerflogRemoteSyncStorage implements RemoteSyncStorage {
  final RemoteSyncStorage _inner;
  final Perflog perflog;
  final LocalResourceLocator _localResourceLocator =
      LocalResourceLocator(iriTermFactory: IriTerm.validated);
  PerflogRemoteSyncStorage(this._inner,
      {required Perflog perflog,
      String name = 'RemoteSyncStorage',
      bool? includeArgs})
      : this.perflog = perflog.create(name, _inner, includeArgs: includeArgs);

  @override
  Future<RemoteDownloadResult<RdfGraph>> download(IriTerm documentIri,
          {String? ifNoneMatch}) =>
      perflog.measure('download',
          () => _inner.download(documentIri, ifNoneMatch: ifNoneMatch),
          args: [documentIri.debug]);

  @override
  Future<List<RemoteDownloadResult<RdfGraph>>> downloadMany(
          Iterable<RemoteDownloadRequest> requests) =>
      perflog
          .measure('downloadMany', () => _inner.downloadMany(requests), args: [
        'count=${requests.length}',
        if (requests.isNotEmpty)
          'firstType=${getType(requests.first.documentIri)}'
      ]);

  @override
  Future<RemoteDownloadResult<RdfDataset>> downloadDataset(IriTerm documentIri,
          {String? ifNoneMatch}) =>
      perflog.measure('downloadDataset',
          () => _inner.downloadDataset(documentIri, ifNoneMatch: ifNoneMatch),
          args: [documentIri.debug]);

  @override
  Future<List<RemoteDownloadResult<RdfDataset>>> downloadManyDatasets(
          Iterable<RemoteDownloadRequest> requests) =>
      perflog.measure(
          'downloadManyDatasets', () => _inner.downloadManyDatasets(requests),
          args: [
            'count=${requests.length}',
            if (requests.isNotEmpty)
              'firstType=${getType(requests.first.documentIri)}'
          ]);

  String getType(IriTerm documentIri) =>
      _localResourceLocator.fromIri(documentIri).typeIri.localName;

  @override
  Future<void> finalizeSync() async {
    await perflog.measure('finalizeSync', () => _inner.finalizeSync());
    await perflog.dispose();
  }

  @override
  int get maxConcurrentDocumentSyncs => _inner.maxConcurrentDocumentSyncs;

  @override
  int get maxConcurrentIndexSyncs => _inner.maxConcurrentIndexSyncs;

  @override
  int get maxConcurrentShardSyncs => _inner.maxConcurrentShardSyncs;
  @override
  Future<RemoteUploadResult> upload(IriTerm documentIri, RdfGraph graph,
          {String? ifMatch}) =>
      perflog.measure(
          'upload', () => _inner.upload(documentIri, graph, ifMatch: ifMatch),
          args: [documentIri.debug]);

  @override
  Future<List<RemoteUploadResult>> uploadMany(
          Iterable<RemoteUploadRequest<RdfGraph>> requests) =>
      perflog.measure('uploadMany', () => _inner.uploadMany(requests), args: [
        'count=${requests.length}',
        if (requests.isNotEmpty)
          'firstType=${getType(requests.first.documentIri)}'
      ]);

  @override
  Future<RemoteUploadResult> uploadDataset(
          IriTerm documentIri, RdfDataset dataset, {String? ifMatch}) =>
      perflog.measure('uploadDataset',
          () => _inner.uploadDataset(documentIri, dataset, ifMatch: ifMatch),
          args: [documentIri.debug]);

  @override
  Future<List<RemoteUploadResult>> uploadManyDatasets(
          Iterable<RemoteUploadRequest<RdfDataset>> requests) =>
      perflog.measure(
          'uploadManyDatasets', () => _inner.uploadManyDatasets(requests),
          args: [
            'count=${requests.length}',
            if (requests.isNotEmpty)
              'firstType=${getType(requests.first.documentIri)}/${requests.first.document.graphNames.isNotEmpty ? getType(requests.first.document.graphNames.first as IriTerm) : 'empty'}'
          ]);
  @override
  String toString() => 'Perflog(${_inner.toString()})';
}
