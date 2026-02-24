library;

import 'package:locorda_core/locorda_core.dart';

/// Thrown when initial sync fails for at least one remote.
class GroupIndexSyncFailedException implements Exception {
  final String message;
  final IndexInstanceSyncState lastState;

  const GroupIndexSyncFailedException(this.message, {required this.lastState});

  @override
  String toString() => 'GroupIndexSyncFailedException: $message';
}
