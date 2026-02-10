/// Pure Dart implementation of Drift native options receiver.
///
/// Shared by both drift_native_options_connector_worker.dart (exported via worker.dart)
/// and drift_native_options_connector.dart (main thread can also call receiver).
///
/// This file has no Flutter dependencies and can be used in web workers.
library;

import 'dart:async';

import 'package:locorda_worker/worker.dart';
import 'package:logging/logging.dart';

import '../drift_options.dart';
import '../shared/messages.dart';

final _log = Logger('DriftNativeOptionsReceiver');

/// Pure Dart implementation of the receiver side.
///
/// Contains the actual logic for waiting for database paths from main thread.
/// This is used by both DriftNativeOptionsConnector (main) and
/// DriftNativeOptionsConnectorWorker (worker export).
class DriftNativeOptionsReceiver {
  /// Receives database paths from main thread and creates LocordaDriftNativeOptions.
  ///
  /// Uses Request/Response pattern: Sends RequestDriftOptions to main thread,
  /// waits for ResponseDriftOptions, then creates the options object.
  ///
  /// Call this in the worker's engine params factory to get native options:
  ///
  /// ```dart
  /// Future<EngineParams> createEngineParams(
  ///   SyncEngineConfig config,
  ///   WorkerContext context,
  /// ) async {
  ///   final nativeOptions = await DriftNativeOptionsConnector.receiver(context);
  ///   final storage = await DriftStorage.create(
  ///     web: LocordaDriftWebOptions(...),
  ///     native: nativeOptions,
  ///   );
  ///   // ... return EngineParams
  /// }
  /// ```
  ///
  /// Throws [TimeoutException] after 5 seconds if no response is received,
  /// with helpful error message about missing plugin registration.
  static Future<LocordaDriftNativeOptions> receiver(
    WorkerHandlerContext context,
    String id, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final channel =
        context.createChannel('locorda_drift/$id/drift_native_options');
    _log.info('Worker: Starting provider...');

    final completer = Completer<LocordaDriftNativeOptions>();
    late final StreamSubscription subscription;

    // Listen for response from main thread via __channel
    subscription = channel.messages.listen((message) {
      _log.fine(
          'Worker: Received __channel message: ${message is Map ? message['type'] : message.runtimeType}');

      if (message is Map<String, dynamic> &&
          message['type'] == 'ResponseDriftOptions') {
        _log.info('Worker: Got ResponseDriftOptions from __channel!');

        final response = ResponseDriftOptionsMessage.fromJson(message);
        _log.fine(
            'Worker: Parsed response: databaseDirectory=${response.databaseDirectory}, tempDirectory=${response.tempDirectoryPath}, databasePath=${response.databasePath}');

        final options = LocordaDriftNativeOptions(
          databaseDirectory: response.databaseDirectory != null
              ? () => Future.value(response.databaseDirectory!)
              : null,
          databasePath: response.databasePath != null
              ? () => Future.value(response.databasePath!)
              : null,
          tempDirectoryPath: response.tempDirectoryPath != null
              ? () => Future.value(response.tempDirectoryPath!)
              : null,
        );

        _log.info('Worker: Completing with LocordaDriftNativeOptions');
        completer.complete(options);
        subscription.cancel();
      }
    });

    // Send request to main thread via __channel
    _log.info('Worker: Sending RequestDriftOptions via __channel...');
    channel.send({'type': 'RequestDriftOptions'});
    _log.info('Worker: Request sent, waiting for response...');

    // Wait for response with timeout
    try {
      return await completer.future.timeout(
        timeout,
        onTimeout: () {
          subscription.cancel();
          throw TimeoutException(
            'DriftNativeOptionsConnector: No response received from main thread after ${timeout.inSeconds}s.\n'
            '\n'
            'Did you forget to register the plugin?\n'
            '\n'
            'Add this to your Locorda.createWithWorker() call:\n'
            '  plugins: [\n'
            '    DriftNativeOptionsConnector.sender(),\n'
            '  ],\n',
          );
        },
      );
    } catch (e) {
      subscription.cancel();
      rethrow;
    }
  }
}
