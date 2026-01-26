/// Manages shard operations including shard determination and entry management.
///
/// Handles the algorithmic aspects of sharding:
/// - Determining which shard a resource belongs to
/// - Calculating shard names
/// - Parsing shard configuration from RDF
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:locorda_core/src/vocab/generated/_index.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_rdf_core/core.dart';

/// Manages shard-level operations for index sharding.
///
/// This class provides utilities for:
/// - Calculating which shard a resource should be placed in
/// - Generating shard names according to the spec
/// - Extracting shard configuration from index RDF
class ShardManager {
  const ShardManager();

  /// Determines which shard number a resource IRI maps to.
  ///
  /// Uses MD5 hash modulo algorithm per SHARDING.md specification:
  /// 1. Hash the resource IRI with MD5
  /// 2. Take first 8 hex characters and convert to integer
  /// 3. Calculate modulo numberOfShards
  ///
  /// Example:
  /// ```
  /// final shardNum = manager.determineShardNumber(
  ///   IriTerm('https://alice.pod/data/recipes/tomato-soup#it'),
  ///   numberOfShards: 4,
  /// );
  /// // Returns 0-3 based on hash
  /// ```
  int determineShardNumber(IriTerm resourceIri, {required int numberOfShards}) {
    // Step 1: Calculate MD5 hash of resource IRI
    final bytes = utf8.encode(resourceIri.value);
    final digest = md5.convert(bytes);
    final hashString = digest.toString();

    // Step 2: Take first 8 hex characters and convert to integer
    final first8Chars = hashString.substring(0, 8);
    final hashInt = int.parse(first8Chars, radix: 16);

    // Step 3: Calculate modulo
    return hashInt % numberOfShards;
  }

  /// Generates a shard name according to the self-describing format.
  ///
  /// Format: shard-mod-md5-{totalShards}-{shardNumber}-v{major}_{scale}_{conflict}
  ///
  /// Example:
  /// ```
  /// final name = manager.generateShardName(
  ///   totalShards: 4,
  ///   shardNumber: 0,
  ///   configVersion: '1_2_0',
  /// );
  /// // Returns 'shard-mod-md5-4-0-v1_2_0'
  /// ```
  String generateShardName({
    required int totalShards,
    required int shardNumber,
    required String configVersion,
  }) {
    return 'shard-mod-md5-$totalShards-$shardNumber-v$configVersion';
  }

  /// Parses shard configuration from an index's sharding algorithm.
  ///
  /// Extracts the sharding parameters from an idx:ModuloHashSharding blank node.
  ///
  /// Returns null if the sharding algorithm cannot be parsed.
  ShardingConfig? parseShardingConfig(
      RdfGraph indexGraph, RdfSubject indexSubject) {
    // Find sharding algorithm blank node
    final algorithmNode = indexGraph.findSingleObject<RdfSubject>(
        indexSubject, Idx.shardingAlgorithm);

    if (algorithmNode == null) {
      return null;
    }

    // Extract configuration values
    final int? numberOfShards = indexGraph
        .findSingleObject<LiteralTerm>(
            algorithmNode, IdxModuloHashSharding.numberOfShards)
        ?.tryIntegerValue;

    final String? configVersion = indexGraph
        .findSingleObject<LiteralTerm>(
            algorithmNode, IdxModuloHashSharding.configVersion)
        ?.value;

    final int? autoScaleThreshold = indexGraph
        .findSingleObject<LiteralTerm>(
            algorithmNode, IdxModuloHashSharding.autoScaleThreshold)
        ?.tryIntegerValue;

    if (numberOfShards == null || configVersion == null) {
      return null;
    }

    return ShardingConfig(
      numberOfShards: numberOfShards,
      configVersion: configVersion,
      autoScaleThreshold: autoScaleThreshold ?? 1000,
    );
  }

  /// Calculates the next shard count for auto-scaling.
  ///
  /// Doubles the current shard count: 1→2→4→8→16
  /// Maximum of 16 shards per spec.
  int calculateNextShardCount(int currentCount) {
    if (currentCount >= 16) {
      // FIXME: where does this limit come from? Do we explicitly say so in the Spec? Where?
      return 16; // Max shards
    }
    return currentCount * 2;
  }

  /// Increments the scale component of a config version.
  ///
  /// Format: major_scale_conflict
  /// Example: '1_0_0' -> '1_1_0'
  ///
  /// Returns the new version string.
  String incrementScaleVersion(String currentVersion) {
    final parts = currentVersion.split('_');
    if (parts.length != 3) {
      throw ArgumentError(
          'Invalid config version format: $currentVersion. Expected format: major_scale_conflict');
    }

    final major = parts[0];
    final scale = int.parse(parts[1]);
    final conflict = parts[2];

    return '${major}_${scale + 1}_$conflict';
  }

  /// Increments the conflict component of a config version.
  ///
  /// Format: major_scale_conflict
  /// Example: '1_0_0' -> '1_0_1'
  ///
  /// Used when shard names conflict with tombstoned entries.
  String incrementConflictVersion(String currentVersion) {
    final parts = currentVersion.split('_');
    if (parts.length != 3) {
      throw ArgumentError(
          'Invalid config version format: $currentVersion. Expected format: major_scale_conflict');
    }

    final major = parts[0];
    final scale = parts[1];
    final conflict = int.parse(parts[2]);

    return '${major}_${scale}_${conflict + 1}';
  }
}

/// Shard configuration extracted from an index.
class ShardingConfig {
  /// Number of shards to distribute resources across
  final int numberOfShards;

  /// Version string in format major_scale_conflict
  final String configVersion;

  /// Threshold for auto-scaling (default 1000)
  final int autoScaleThreshold;

  const ShardingConfig({
    required this.numberOfShards,
    required this.configVersion,
    this.autoScaleThreshold = 1000,
  });

  @override
  String toString() =>
      'ShardingConfig(shards: $numberOfShards, version: $configVersion, threshold: $autoScaleThreshold)';
}
