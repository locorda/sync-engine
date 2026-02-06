/// Configuration for Solid backend synchronization behavior.
///
/// This config is shared between main and worker isolates and is transferred
/// as JSON during worker initialization.
class SolidConfig {
  /// Maximum number of documents to sync concurrently.
  final int maxConcurrentDocumentSyncs;

  /// Maximum number of shards to sync concurrently.
  final int maxConcurrentShardSyncs;

  /// Maximum number of indices to sync concurrently.
  final int maxConcurrentIndexSyncs;

  /// Whether to sync shard datasets instead of individual documents.
  final bool useShardDatasets;

  const SolidConfig({
    this.maxConcurrentDocumentSyncs = 1,
    this.maxConcurrentShardSyncs = 1,
    this.maxConcurrentIndexSyncs = 1,
    this.useShardDatasets = false,
  });

  /// Encode config to JSON.
  Map<String, dynamic> toJson() => {
        'maxConcurrentDocumentSyncs': maxConcurrentDocumentSyncs,
        'maxConcurrentShardSyncs': maxConcurrentShardSyncs,
        'maxConcurrentIndexSyncs': maxConcurrentIndexSyncs,
        'useShardDatasets': useShardDatasets,
      };

  /// Decode config from JSON.
  factory SolidConfig.fromJson(Map<String, dynamic> json) {
    return SolidConfig(
      maxConcurrentDocumentSyncs:
          json['maxConcurrentDocumentSyncs'] as int? ?? 1,
      maxConcurrentShardSyncs: json['maxConcurrentShardSyncs'] as int? ?? 1,
      maxConcurrentIndexSyncs: json['maxConcurrentIndexSyncs'] as int? ?? 1,
      useShardDatasets: json['useShardDatasets'] as bool? ?? true,
    );
  }

  SolidConfig copyWith({
    int? maxConcurrentDocumentSyncs,
    int? maxConcurrentShardSyncs,
    int? maxConcurrentIndexSyncs,
    bool? useShardDatasets,
  }) {
    return SolidConfig(
      maxConcurrentDocumentSyncs:
          maxConcurrentDocumentSyncs ?? this.maxConcurrentDocumentSyncs,
      maxConcurrentShardSyncs:
          maxConcurrentShardSyncs ?? this.maxConcurrentShardSyncs,
      maxConcurrentIndexSyncs:
          maxConcurrentIndexSyncs ?? this.maxConcurrentIndexSyncs,
      useShardDatasets: useShardDatasets ?? this.useShardDatasets,
    );
  }
}
