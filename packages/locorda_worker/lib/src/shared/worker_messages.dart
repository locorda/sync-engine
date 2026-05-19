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
  final Object encodedGraph; // Serialized RdfGraph (String or Uint8List)

  SaveRequest(super.requestId, this.typeIri, this.encodedGraph);

  @override
  Map<String, dynamic> toJson() => {
        'type': 'SaveRequest',
        'requestId': requestId,
        'typeIri': typeIri,
        'encodedGraph': encodedGraph,
      };

  factory SaveRequest.fromJson(Map<String, dynamic> json) {
    return SaveRequest(
      json['requestId'] as String,
      json['typeIri'] as String,
      json['encodedGraph'] as Object,
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

/// SaveAll request
class SaveAllRequest extends WorkerRequest {
  final List<(String typeIri, Object encodedGraph)> items;

  SaveAllRequest(super.requestId, this.items);

  @override
  Map<String, dynamic> toJson() => {
        'type': 'SaveAllRequest',
        'requestId': requestId,
        'items': items
            .map((item) => {'typeIri': item.$1, 'encodedGraph': item.$2})
            .toList(),
      };

  factory SaveAllRequest.fromJson(Map<String, dynamic> json) {
    final itemsList = (json['items'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .map((item) => (
              item['typeIri'] as String,
              item['encodedGraph'] as Object,
            ))
        .toList();
    return SaveAllRequest(
      json['requestId'] as String,
      itemsList,
    );
  }
}

class SaveAllResponse extends WorkerResponse {
  final bool success;
  final String? error;

  SaveAllResponse(super.requestId, {required this.success, this.error});

  @override
  Map<String, dynamic> toJson() => {
        'type': 'SaveAllResponse',
        'requestId': requestId,
        'success': success,
        if (error != null) 'error': error,
      };

  factory SaveAllResponse.fromJson(Map<String, dynamic> json) {
    return SaveAllResponse(
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

/// Batch delete request
class DeleteDocumentsRequest extends WorkerRequest {
  final String typeIri;
  final List<String> externalIris;

  DeleteDocumentsRequest(super.requestId, this.typeIri, this.externalIris);

  @override
  Map<String, dynamic> toJson() => {
        'type': 'DeleteDocumentsRequest',
        'requestId': requestId,
        'typeIri': typeIri,
        'externalIris': externalIris,
      };

  factory DeleteDocumentsRequest.fromJson(Map<String, dynamic> json) {
    return DeleteDocumentsRequest(
      json['requestId'] as String,
      json['typeIri'] as String,
      (json['externalIris'] as List).cast<String>(),
    );
  }
}

class DeleteDocumentsResponse extends WorkerResponse {
  final bool success;
  final String? error;

  DeleteDocumentsResponse(super.requestId, {required this.success, this.error});

  @override
  Map<String, dynamic> toJson() => {
        'type': 'DeleteDocumentsResponse',
        'requestId': requestId,
        'success': success,
        if (error != null) 'error': error,
      };

  factory DeleteDocumentsResponse.fromJson(Map<String, dynamic> json) {
    return DeleteDocumentsResponse(
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
  final Object? encodedGraph; // null if not found
  final String? error;

  EnsureResponse(super.requestId, {this.encodedGraph, this.error});

  @override
  Map<String, dynamic> toJson() => {
        'type': 'EnsureResponse',
        'requestId': requestId,
        if (encodedGraph != null) 'encodedGraph': encodedGraph,
        if (error != null) 'error': error,
      };

  factory EnsureResponse.fromJson(Map<String, dynamic> json) {
    return EnsureResponse(
      json['requestId'] as String,
      encodedGraph: json['encodedGraph'],
      error: json['error'] as String?,
    );
  }
}

/// Ensure group index subscription request.
class EnsureGroupIndexSubscriptionRequest extends WorkerRequest {
  final String indexName;
  final Object encodedGroupKeyGraph;

  /// `null` means: use the policy configured on the GroupIndexData in the engine.
  final Map<String, dynamic>? rootResourceFetchPolicyMap;
  final bool triggerSync;

  EnsureGroupIndexSubscriptionRequest(
    super.requestId,
    this.indexName,
    this.encodedGroupKeyGraph,
    this.rootResourceFetchPolicyMap,
    this.triggerSync,
  );

  @override
  Map<String, dynamic> toJson() => {
        'type': 'EnsureGroupIndexSubscriptionRequest',
        'requestId': requestId,
        'indexName': indexName,
        'encodedGroupKeyGraph': encodedGroupKeyGraph,
        if (rootResourceFetchPolicyMap != null)
          'rootResourceFetchPolicyMap': rootResourceFetchPolicyMap,
        'triggerSync': triggerSync,
      };

  factory EnsureGroupIndexSubscriptionRequest.fromJson(
      Map<String, dynamic> json) {
    final policyMap = json['rootResourceFetchPolicyMap'];
    return EnsureGroupIndexSubscriptionRequest(
      json['requestId'] as String,
      json['indexName'] as String,
      json['encodedGroupKeyGraph'] as Object,
      policyMap != null ? (policyMap as Map).cast<String, dynamic>() : null,
      json['triggerSync'] as bool? ?? true,
    );
  }
}

class EnsureGroupIndexSubscriptionResponse extends WorkerResponse {
  final bool success;
  final String? error;

  EnsureGroupIndexSubscriptionResponse(super.requestId,
      {required this.success, this.error});

  @override
  Map<String, dynamic> toJson() => {
        'type': 'EnsureGroupIndexSubscriptionResponse',
        'requestId': requestId,
        'success': success,
        if (error != null) 'error': error,
      };

  factory EnsureGroupIndexSubscriptionResponse.fromJson(
      Map<String, dynamic> json) {
    return EnsureGroupIndexSubscriptionResponse(
      json['requestId'] as String,
      success: json['success'] as bool,
      error: json['error'] as String?,
    );
  }
}

/// Watch index-instance sync state request (streaming).
class WatchIndexInstanceSyncStateRequest extends WorkerRequest {
  final String watchKind; // 'group' | 'type'
  final String? indexName;
  final Object? encodedGroupKeyGraph;
  final String? typeIri;

  WatchIndexInstanceSyncStateRequest(
    super.requestId, {
    required this.watchKind,
    this.indexName,
    this.encodedGroupKeyGraph,
    this.typeIri,
  });

  @override
  Map<String, dynamic> toJson() => {
        'type': 'WatchIndexInstanceSyncStateRequest',
        'requestId': requestId,
        'watchKind': watchKind,
        if (indexName != null) 'indexName': indexName,
        if (encodedGroupKeyGraph != null)
          'encodedGroupKeyGraph': encodedGroupKeyGraph,
        if (typeIri != null) 'typeIri': typeIri,
      };

  factory WatchIndexInstanceSyncStateRequest.fromJson(
      Map<String, dynamic> json) {
    return WatchIndexInstanceSyncStateRequest(
      json['requestId'] as String,
      watchKind: json['watchKind'] as String,
      indexName: json['indexName'] as String?,
      encodedGroupKeyGraph: json['encodedGroupKeyGraph'],
      typeIri: json['typeIri'] as String?,
    );
  }
}

/// Cancel watch request for a previously registered stream.
class CancelWatchRequest extends WorkerRequest {
  final String targetRequestId;

  CancelWatchRequest(super.requestId, {required this.targetRequestId});

  @override
  Map<String, dynamic> toJson() => {
        'type': 'CancelWatchRequest',
        'requestId': requestId,
        'targetRequestId': targetRequestId,
      };

  factory CancelWatchRequest.fromJson(Map<String, dynamic> json) {
    return CancelWatchRequest(
      json['requestId'] as String,
      targetRequestId: json['targetRequestId'] as String,
    );
  }
}

class CancelWatchResponse extends WorkerResponse {
  final bool success;
  final String? error;

  CancelWatchResponse(super.requestId, {required this.success, this.error});

  @override
  Map<String, dynamic> toJson() => {
        'type': 'CancelWatchResponse',
        'requestId': requestId,
        'success': success,
        if (error != null) 'error': error,
      };

  factory CancelWatchResponse.fromJson(Map<String, dynamic> json) {
    return CancelWatchResponse(
      json['requestId'] as String,
      success: json['success'] as bool,
      error: json['error'] as String?,
    );
  }
}

/// Streaming message carrying index-instance sync state snapshots.
class IndexInstanceSyncStateMessage extends WorkerResponse {
  final String indexInstanceIri;
  final List<Map<String, dynamic>> perRemote;
  final bool isInitial;
  final bool isComplete;

  IndexInstanceSyncStateMessage(
    super.requestId, {
    required this.indexInstanceIri,
    required this.perRemote,
    required this.isInitial,
    required this.isComplete,
  });

  @override
  Map<String, dynamic> toJson() => {
        'type': 'IndexInstanceSyncStateMessage',
        'requestId': requestId,
        'indexInstanceIri': indexInstanceIri,
        'perRemote': perRemote,
        'isInitial': isInitial,
        'isComplete': isComplete,
      };

  factory IndexInstanceSyncStateMessage.fromJson(Map<String, dynamic> json) {
    return IndexInstanceSyncStateMessage(
      json['requestId'] as String,
      indexInstanceIri: json['indexInstanceIri'] as String,
      perRemote: (json['perRemote'] as List<dynamic>)
          .map((entry) => (entry as Map).cast<String, dynamic>())
          .toList(),
      isInitial: json['isInitial'] as bool,
      isComplete: json['isComplete'] as bool,
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
  final List<(String id, Object encodedGraph)> updates;
  final List<(String id, Object encodedGraph)> deletions;
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
        .map((item) => (item['id'] as String, item['graph'] as Object))
        .toList();

    final deletionsJson = json['deletions'] as List<dynamic>;
    final deletions = deletionsJson
        .map((item) => (item['id'] as String, item['graph'] as Object))
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
    'SaveAllRequest' => SaveAllRequest.fromJson(json),
    'SaveAllResponse' => SaveAllResponse.fromJson(json),
    'DeleteDocumentRequest' => DeleteDocumentRequest.fromJson(json),
    'DeleteDocumentResponse' => DeleteDocumentResponse.fromJson(json),
    'DeleteDocumentsRequest' => DeleteDocumentsRequest.fromJson(json),
    'DeleteDocumentsResponse' => DeleteDocumentsResponse.fromJson(json),
    'EnsureGroupIndexSubscriptionRequest' =>
      EnsureGroupIndexSubscriptionRequest.fromJson(json),
    'EnsureGroupIndexSubscriptionResponse' =>
      EnsureGroupIndexSubscriptionResponse.fromJson(json),
    'WatchIndexInstanceSyncStateRequest' =>
      WatchIndexInstanceSyncStateRequest.fromJson(json),
    'CancelWatchRequest' => CancelWatchRequest.fromJson(json),
    'CancelWatchResponse' => CancelWatchResponse.fromJson(json),
    'IndexInstanceSyncStateMessage' =>
      IndexInstanceSyncStateMessage.fromJson(json),
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
