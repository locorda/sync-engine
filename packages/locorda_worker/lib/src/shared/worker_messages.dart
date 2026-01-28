/// Message protocol for worker communication.
///
/// All messages are JSON-serializable for cross-isolate/worker transmission.
library;

import 'package:locorda_core/locorda_core.dart';

/// Base class for all worker messages.
sealed class WorkerMessage {
  Map<String, dynamic> toJson();
}

/// Message types for requests (Main → Worker)
sealed class WorkerRequest extends WorkerMessage {
  final String requestId;
  WorkerRequest(this.requestId);
}

/// Message types for responses (Worker → Main)
sealed class WorkerResponse extends WorkerMessage {
  final String requestId;
  WorkerResponse(this.requestId);
}

/// Save request
class SaveRequest extends WorkerRequest {
  final String typeIri; // Serialized IriTerm
  final String appDataTurtle; // Serialized RdfGraph in Turtle format

  SaveRequest(super.requestId, this.typeIri, this.appDataTurtle);

  @override
  Map<String, dynamic> toJson() => {
        'type': 'SaveRequest',
        'requestId': requestId,
        'typeIri': typeIri,
        'appDataTurtle': appDataTurtle,
      };

  factory SaveRequest.fromJson(Map<String, dynamic> json) {
    return SaveRequest(
      json['requestId'] as String,
      json['typeIri'] as String,
      json['appDataTurtle'] as String,
    );
  }
}

class SaveResponse extends WorkerResponse {
  final bool success;
  final String? error;

  SaveResponse(super.requestId, {required this.success, this.error});

  @override
  Map<String, dynamic> toJson() => {
        'type': 'SaveResponse',
        'requestId': requestId,
        'success': success,
        if (error != null) 'error': error,
      };

  factory SaveResponse.fromJson(Map<String, dynamic> json) {
    return SaveResponse(
      json['requestId'] as String,
      success: json['success'] as bool,
      error: json['error'] as String?,
    );
  }
}

/// Delete request
class DeleteDocumentRequest extends WorkerRequest {
  final String typeIri;
  final String externalIri;

  DeleteDocumentRequest(super.requestId, this.typeIri, this.externalIri);

  @override
  Map<String, dynamic> toJson() => {
        'type': 'DeleteDocumentRequest',
        'requestId': requestId,
        'typeIri': typeIri,
        'externalIri': externalIri,
      };

  factory DeleteDocumentRequest.fromJson(Map<String, dynamic> json) {
    return DeleteDocumentRequest(
      json['requestId'] as String,
      json['typeIri'] as String,
      json['externalIri'] as String,
    );
  }
}

class DeleteDocumentResponse extends WorkerResponse {
  final bool success;
  final String? error;

  DeleteDocumentResponse(super.requestId, {required this.success, this.error});

  @override
  Map<String, dynamic> toJson() => {
        'type': 'DeleteDocumentResponse',
        'requestId': requestId,
        'success': success,
        if (error != null) 'error': error,
      };

  factory DeleteDocumentResponse.fromJson(Map<String, dynamic> json) {
    return DeleteDocumentResponse(
      json['requestId'] as String,
      success: json['success'] as bool,
      error: json['error'] as String?,
    );
  }
}

/// Ensure request
class EnsureRequest extends WorkerRequest {
  final String typeIri;
  final String localIri;
  final int timeoutSeconds;
  final bool skipInitialFetch;

  EnsureRequest(
    super.requestId,
    this.typeIri,
    this.localIri,
    this.timeoutSeconds,
    this.skipInitialFetch,
  );

  @override
  Map<String, dynamic> toJson() => {
        'type': 'EnsureRequest',
        'requestId': requestId,
        'typeIri': typeIri,
        'localIri': localIri,
        'timeoutSeconds': timeoutSeconds,
        'skipInitialFetch': skipInitialFetch,
      };

  factory EnsureRequest.fromJson(Map<String, dynamic> json) {
    return EnsureRequest(
      json['requestId'] as String,
      json['typeIri'] as String,
      json['localIri'] as String,
      json['timeoutSeconds'] as int,
      json['skipInitialFetch'] as bool,
    );
  }
}

class EnsureResponse extends WorkerResponse {
  final String? graphTurtle; // null if not found
  final String? error;

  EnsureResponse(super.requestId, {this.graphTurtle, this.error});

  @override
  Map<String, dynamic> toJson() => {
        'type': 'EnsureResponse',
        'requestId': requestId,
        if (graphTurtle != null) 'graphTurtle': graphTurtle,
        if (error != null) 'error': error,
      };

  factory EnsureResponse.fromJson(Map<String, dynamic> json) {
    return EnsureResponse(
      json['requestId'] as String,
      graphTurtle: json['graphTurtle'] as String?,
      error: json['error'] as String?,
    );
  }
}

/// Configure group index subscription request
class ConfigureGroupIndexSubscriptionRequest extends WorkerRequest {
  final String indexName;
  final String groupKeyGraphTurtle;
  final String itemFetchPolicy; // 'prefetch' or 'onRequest'

  ConfigureGroupIndexSubscriptionRequest(
    super.requestId,
    this.indexName,
    this.groupKeyGraphTurtle,
    this.itemFetchPolicy,
  );

  @override
  Map<String, dynamic> toJson() => {
        'type': 'ConfigureGroupIndexSubscriptionRequest',
        'requestId': requestId,
        'indexName': indexName,
        'groupKeyGraphTurtle': groupKeyGraphTurtle,
        'itemFetchPolicy': itemFetchPolicy,
      };

  factory ConfigureGroupIndexSubscriptionRequest.fromJson(
      Map<String, dynamic> json) {
    return ConfigureGroupIndexSubscriptionRequest(
      json['requestId'] as String,
      json['indexName'] as String,
      json['groupKeyGraphTurtle'] as String,
      json['itemFetchPolicy'] as String,
    );
  }
}

class ConfigureGroupIndexSubscriptionResponse extends WorkerResponse {
  final bool success;
  final String? error;

  ConfigureGroupIndexSubscriptionResponse(super.requestId,
      {required this.success, this.error});

  @override
  Map<String, dynamic> toJson() => {
        'type': 'ConfigureGroupIndexSubscriptionResponse',
        'requestId': requestId,
        'success': success,
        if (error != null) 'error': error,
      };

  factory ConfigureGroupIndexSubscriptionResponse.fromJson(
      Map<String, dynamic> json) {
    return ConfigureGroupIndexSubscriptionResponse(
      json['requestId'] as String,
      success: json['success'] as bool,
      error: json['error'] as String?,
    );
  }
}

/// Hydration stream request
class HydrateStreamRequest extends WorkerRequest {
  final String typeIri;
  final String? indexName;
  final String? cursor;
  final int initialBatchSize;

  HydrateStreamRequest(
    super.requestId,
    this.typeIri, {
    this.indexName,
    this.cursor,
    required this.initialBatchSize,
  });

  @override
  Map<String, dynamic> toJson() => {
        'type': 'HydrateStreamRequest',
        'requestId': requestId,
        'typeIri': typeIri,
        if (indexName != null) 'indexName': indexName,
        if (cursor != null) 'cursor': cursor,
        'initialBatchSize': initialBatchSize,
      };

  factory HydrateStreamRequest.fromJson(Map<String, dynamic> json) {
    return HydrateStreamRequest(
      json['requestId'] as String,
      json['typeIri'] as String,
      indexName: json['indexName'] as String?,
      cursor: json['cursor'] as String?,
      initialBatchSize: json['initialBatchSize'] as int,
    );
  }
}

/// Hydration batch message (streaming response)
class HydrationBatchMessage extends WorkerResponse {
  final List<(String id, String turtleGraph)> updates;
  final List<(String id, String turtleGraph)> deletions;
  final String? cursor;
  final bool isComplete; // true for final batch

  HydrationBatchMessage(
    super.requestId, {
    required this.updates,
    required this.deletions,
    this.cursor,
    required this.isComplete,
  });

  @override
  Map<String, dynamic> toJson() => {
        'type': 'HydrationBatchMessage',
        'requestId': requestId,
        'updates':
            updates.map((item) => {'id': item.$1, 'graph': item.$2}).toList(),
        'deletions':
            deletions.map((item) => {'id': item.$1, 'graph': item.$2}).toList(),
        if (cursor != null) 'cursor': cursor,
        'isComplete': isComplete,
      };

  factory HydrationBatchMessage.fromJson(Map<String, dynamic> json) {
    final updatesJson = json['updates'] as List<dynamic>;
    final updates = updatesJson
        .map((item) => (item['id'] as String, item['graph'] as String))
        .toList();

    final deletionsJson = json['deletions'] as List<dynamic>;
    final deletions = deletionsJson
        .map((item) => (item['id'] as String, item['graph'] as String))
        .toList();

    return HydrationBatchMessage(
      json['requestId'] as String,
      updates: updates,
      deletions: deletions,
      cursor: json['cursor'] as String?,
      isComplete: json['isComplete'] as bool,
    );
  }
}

/// Sync trigger request
class SyncTriggerRequest extends WorkerRequest {
  final SyncTrigger trigger;

  SyncTriggerRequest(
    super.requestId, {
    this.trigger = SyncTrigger.manual,
  });

  @override
  Map<String, dynamic> toJson() => {
        'type': 'SyncTriggerRequest',
        'requestId': requestId,
        'trigger': trigger.name,
      };

  factory SyncTriggerRequest.fromJson(Map<String, dynamic> json) {
    return SyncTriggerRequest(
      json['requestId'] as String,
      trigger: SyncTrigger.values.firstWhere(
        (t) => t.name == json['trigger'],
        orElse: () => SyncTrigger.manual,
      ),
    );
  }
}

class SyncTriggerResponse extends WorkerResponse {
  final bool success;
  final String? error;

  SyncTriggerResponse(super.requestId, {required this.success, this.error});

  @override
  Map<String, dynamic> toJson() => {
        'type': 'SyncTriggerResponse',
        'requestId': requestId,
        'success': success,
        if (error != null) 'error': error,
      };

  factory SyncTriggerResponse.fromJson(Map<String, dynamic> json) {
    return SyncTriggerResponse(
      json['requestId'] as String,
      success: json['success'] as bool,
      error: json['error'] as String?,
    );
  }
}

/// Enable auto-sync request
class EnableAutoSyncRequest extends WorkerRequest {
  final int intervalMinutes;

  EnableAutoSyncRequest(super.requestId, this.intervalMinutes);

  @override
  Map<String, dynamic> toJson() => {
        'type': 'EnableAutoSyncRequest',
        'requestId': requestId,
        'intervalMinutes': intervalMinutes,
      };

  factory EnableAutoSyncRequest.fromJson(Map<String, dynamic> json) {
    return EnableAutoSyncRequest(
      json['requestId'] as String,
      json['intervalMinutes'] as int,
    );
  }
}

class EnableAutoSyncResponse extends WorkerResponse {
  final bool success;

  EnableAutoSyncResponse(super.requestId, {required this.success});

  @override
  Map<String, dynamic> toJson() => {
        'type': 'EnableAutoSyncResponse',
        'requestId': requestId,
        'success': success,
      };

  factory EnableAutoSyncResponse.fromJson(Map<String, dynamic> json) {
    return EnableAutoSyncResponse(
      json['requestId'] as String,
      success: json['success'] as bool,
    );
  }
}

/// Disable auto-sync request
class DisableAutoSyncRequest extends WorkerRequest {
  DisableAutoSyncRequest(super.requestId);

  @override
  Map<String, dynamic> toJson() => {
        'type': 'DisableAutoSyncRequest',
        'requestId': requestId,
      };

  factory DisableAutoSyncRequest.fromJson(Map<String, dynamic> json) {
    return DisableAutoSyncRequest(json['requestId'] as String);
  }
}

class DisableAutoSyncResponse extends WorkerResponse {
  final bool success;

  DisableAutoSyncResponse(super.requestId, {required this.success});

  @override
  Map<String, dynamic> toJson() => {
        'type': 'DisableAutoSyncResponse',
        'requestId': requestId,
        'success': success,
      };

  factory DisableAutoSyncResponse.fromJson(Map<String, dynamic> json) {
    return DisableAutoSyncResponse(
      json['requestId'] as String,
      success: json['success'] as bool,
    );
  }
}

/// Get sync state request
class GetSyncStateRequest extends WorkerRequest {
  GetSyncStateRequest(super.requestId);

  @override
  Map<String, dynamic> toJson() => {
        'type': 'GetSyncStateRequest',
        'requestId': requestId,
      };

  factory GetSyncStateRequest.fromJson(Map<String, dynamic> json) {
    return GetSyncStateRequest(json['requestId'] as String);
  }
}

class GetSyncStateResponse extends WorkerResponse {
  final String status; // 'idle', 'syncing', 'success', 'error'
  final DateTime? lastSyncTime;
  final String? errorMessage;
  final SyncTrigger? lastTrigger;

  GetSyncStateResponse(
    super.requestId, {
    required this.status,
    this.lastSyncTime,
    this.errorMessage,
    this.lastTrigger,
  });

  @override
  Map<String, dynamic> toJson() => {
        'type': 'GetSyncStateResponse',
        'requestId': requestId,
        'status': status,
        if (lastSyncTime != null)
          'lastSyncTime': lastSyncTime!.toIso8601String(),
        if (errorMessage != null) 'errorMessage': errorMessage,
        if (lastTrigger != null) 'lastTrigger': lastTrigger!.name,
      };

  factory GetSyncStateResponse.fromJson(Map<String, dynamic> json) {
    return GetSyncStateResponse(
      json['requestId'] as String,
      status: json['status'] as String,
      lastSyncTime: json['lastSyncTime'] != null
          ? DateTime.parse(json['lastSyncTime'] as String)
          : null,
      errorMessage: json['errorMessage'] as String?,
      lastTrigger: json['lastTrigger'] != null
          ? SyncTrigger.values.firstWhere(
              (t) => t.name == json['lastTrigger'],
              orElse: () => SyncTrigger.manual,
            )
          : null,
    );
  }
}

/// Sync state update notification (Worker → Main, no request ID)
class SyncStateUpdateMessage extends WorkerMessage {
  final String status; // 'idle', 'syncing', 'success', 'error'
  final DateTime? lastSyncTime;
  final String? errorMessage;
  final SyncTrigger? lastTrigger;

  SyncStateUpdateMessage({
    required this.status,
    this.lastSyncTime,
    this.errorMessage,
    this.lastTrigger,
  });

  @override
  Map<String, dynamic> toJson() => {
        'type': 'SyncStateUpdateMessage',
        'status': status,
        if (lastSyncTime != null)
          'lastSyncTime': lastSyncTime!.toIso8601String(),
        if (errorMessage != null) 'errorMessage': errorMessage,
        if (lastTrigger != null) 'lastTrigger': lastTrigger!.name,
      };

  factory SyncStateUpdateMessage.fromJson(Map<String, dynamic> json) {
    return SyncStateUpdateMessage(
      status: json['status'] as String,
      lastSyncTime: json['lastSyncTime'] != null
          ? DateTime.parse(json['lastSyncTime'] as String)
          : null,
      errorMessage: json['errorMessage'] as String?,
      lastTrigger: json['lastTrigger'] != null
          ? SyncTrigger.values.firstWhere(
              (t) => t.name == json['lastTrigger'],
              orElse: () => SyncTrigger.manual,
            )
          : null,
    );
  }
}

/// Helper to deserialize messages from JSON
WorkerMessage deserializeMessage(Map<String, dynamic> json) {
  final type = json['type'] as String?;

  return switch (type) {
    'SaveRequest' => SaveRequest.fromJson(json),
    'SaveResponse' => SaveResponse.fromJson(json),
    'DeleteDocumentRequest' => DeleteDocumentRequest.fromJson(json),
    'DeleteDocumentResponse' => DeleteDocumentResponse.fromJson(json),
    'ConfigureGroupIndexSubscriptionRequest' =>
      ConfigureGroupIndexSubscriptionRequest.fromJson(json),
    'ConfigureGroupIndexSubscriptionResponse' =>
      ConfigureGroupIndexSubscriptionResponse.fromJson(json),
    'HydrateStreamRequest' => HydrateStreamRequest.fromJson(json),
    'HydrationBatchMessage' => HydrationBatchMessage.fromJson(json),
    'SyncTriggerRequest' => SyncTriggerRequest.fromJson(json),
    'SyncTriggerResponse' => SyncTriggerResponse.fromJson(json),
    'EnableAutoSyncRequest' => EnableAutoSyncRequest.fromJson(json),
    'EnableAutoSyncResponse' => EnableAutoSyncResponse.fromJson(json),
    'DisableAutoSyncRequest' => DisableAutoSyncRequest.fromJson(json),
    'DisableAutoSyncResponse' => DisableAutoSyncResponse.fromJson(json),
    'GetSyncStateRequest' => GetSyncStateRequest.fromJson(json),
    'GetSyncStateResponse' => GetSyncStateResponse.fromJson(json),
    'SyncStateUpdateMessage' => SyncStateUpdateMessage.fromJson(json),
    null => throw ArgumentError('Message type is missing in JSON: $json'),
    _ => throw ArgumentError('Unknown message type: $type'),
  };
}
