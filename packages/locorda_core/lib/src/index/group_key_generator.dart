/// Generates group keys from Triple lists using GroupIndex configuration.
library;

import 'package:locorda_core/src/config/sync_engine_config.dart';
import 'package:locorda_rdf_core/core.dart';
import 'filesystem_safety.dart';
import 'rdf_group_extractor.dart';

/// Generates group keys from RDF triples based on GroupIndex configuration.
///
/// This class takes the configuration for a GroupIndex and provides methods
/// to create group keys from Lists of Triple instances according to the
/// specification in REGEX-TRANSFORMS.md.
///
/// Group keys are generated hierarchically based on the groupingProperties
/// configuration, where each property contributes to a different level of
/// the group hierarchy.
class GroupKeyGenerator {
  final Map<int, List<_PropertyExtractor>> _extractorsByLevel;

  /// Creates a GroupKeyGenerator for the given GroupIndex configuration.
  ///
  /// Efficiently organizes extractors by hierarchy level and pre-compiles
  /// regex patterns for optimal performance.
  GroupKeyGenerator(GroupIndexData config)
      : _extractorsByLevel = _organizeExtractorsByLevel(config);

  /// Generates group keys from a list of triples according to ARCHITECTURE.md 5.3.3.
  ///
  /// Implements the complete GroupingRule Algorithm:
  /// 1. Property Extraction: Extract all values for each property
  /// 2. Missing Value Handling: Use missingValue or return empty set
  /// 3. Permutation Generation: Compute Cartesian product of all property value sets
  /// 4. Transform Application: Apply regex transforms to each value
  /// 5. Path Generation: Generate deterministic group paths with hierarchy
  /// 6. Set Deduplication: Remove duplicates that arise from formatting
  /// 7. Group Creation: Return all unique group identifiers
  ///
  /// Returns empty set if any required property is missing and has no missingValue.
  Set<String> generateGroupKeys(List<Triple> triples) {
    // Step 1 & 2: Property Extraction and Missing Value Handling
    final valuesByLevel = <int, List<List<String>>>{};

    final sortedLevels = _extractorsByLevel.keys.toList()..sort();

    for (final level in sortedLevels) {
      final extractors = _extractorsByLevel[level]!;
      final levelValueSets = <List<String>>[];

      for (final extractor in extractors) {
        final values = _extractAllValuesForProperty(triples, extractor);
        if (values.isEmpty) {
          // Required property missing and no fallback - return empty set
          return <String>{};
        }
        levelValueSets.add(values);
      }

      valuesByLevel[level] = levelValueSets;
    }

    // Step 3: Permutation Generation (Cartesian product)
    final allGroupKeys = <String>[];

    // Generate Cartesian product across all levels
    _generateCartesianProduct(valuesByLevel, sortedLevels, 0, [], allGroupKeys);

    // Step 6: Set Deduplication
    return allGroupKeys.toSet();
  }

  /// Extracts all values for a specific grouping property from the triples.
  ///
  /// Step 1: Property Extraction - Extract all values for idx:sourceProperty
  /// Step 2: Missing Value Handling - Use missingValue or return empty list
  /// Step 4: Transform Application - Apply idx:transform to each value
  List<String> _extractAllValuesForProperty(
      List<Triple> triples, _PropertyExtractor extractor) {
    // Find all triples with the matching predicate
    final matchingTriples = triples
        .where((triple) => triple.predicate == extractor.predicate)
        .toList();

    if (matchingTriples.isEmpty) {
      // Property not found - use missing value if specified
      if (extractor.missingValue != null) {
        return [extractor.missingValue!];
      }
      return []; // No values and no fallback
    }

    // Extract and transform all values
    final transformedValues = <String>[];
    for (final triple in matchingTriples) {
      final transformedValue =
          extractor.groupExtractor.extractGroupKey(triple.object);
      if (transformedValue != null) {
        transformedValues.add(transformedValue);
      }
    }

    return transformedValues;
  }

  /// Generates Cartesian product across all hierarchy levels.
  ///
  /// Step 3: Permutation Generation - Compute Cartesian product of all property value sets
  /// Step 5: Path Generation - Generate deterministic group paths using hierarchy levels
  void _generateCartesianProduct(
    Map<int, List<List<String>>> valuesByLevel,
    List<int> sortedLevels,
    int levelIndex,
    List<String> currentPath,
    List<String> result,
  ) {
    if (levelIndex >= sortedLevels.length) {
      // Base case: we've processed all levels, generate the group key
      if (currentPath.isNotEmpty) {
        // Join the filesystem-safe path components with '/' separator
        final groupKey = currentPath.join('/');
        result.add(groupKey);
      }
      return;
    }

    final currentLevel = sortedLevels[levelIndex];
    final levelValueSets = valuesByLevel[currentLevel]!;

    // Generate Cartesian product within this level
    _generateLevelCartesianProduct(
      levelValueSets,
      0,
      [],
      (levelCombination) {
        // Combine values at this level with hyphen separator
        final levelKey = levelCombination.join('-');
        // Apply filesystem safety to the level key before adding to path
        final safeLevelKey = FilesystemSafety.makeSafe(levelKey);
        final newPath = [...currentPath, safeLevelKey];

        // Recurse to next level
        _generateCartesianProduct(
          valuesByLevel,
          sortedLevels,
          levelIndex + 1,
          newPath,
          result,
        );
      },
    );
  }

  /// Generates Cartesian product within a single hierarchy level.
  void _generateLevelCartesianProduct(
    List<List<String>> valueSets,
    int setIndex,
    List<String> currentCombination,
    void Function(List<String>) onCombination,
  ) {
    if (setIndex >= valueSets.length) {
      // Base case: we've selected one value from each property set
      onCombination(List.from(currentCombination));
      return;
    }

    final currentSet = valueSets[setIndex];
    for (final value in currentSet) {
      currentCombination.add(value);
      _generateLevelCartesianProduct(
        valueSets,
        setIndex + 1,
        currentCombination,
        onCombination,
      );
      currentCombination.removeLast();
    }
  }

  /// Organizes property extractors by hierarchy level for efficient processing.
  ///
  /// Within each level, extractors are sorted by lexicographic IRI ordering
  /// according to the ARCHITECTURE.md specification.
  static Map<int, List<_PropertyExtractor>> _organizeExtractorsByLevel(
      GroupIndexData config) {
    final extractorsByLevel = <int, List<_PropertyExtractor>>{};

    for (final property in config.groupingProperties) {
      final level = property.hierarchyLevel;
      final extractor = _PropertyExtractor(
        predicate: property.predicate,
        groupExtractor: RdfGroupExtractor(property.transforms ?? []),
        missingValue: property.missingValue,
      );

      extractorsByLevel.putIfAbsent(level, () => []).add(extractor);
    }

    // Sort extractors within each level by lexicographic IRI ordering
    for (final extractors in extractorsByLevel.values) {
      extractors.sort((a, b) => a.predicate.value.compareTo(b.predicate.value));
    }

    return extractorsByLevel;
  }
}

/// Internal helper class for property extraction with regex transforms.
class _PropertyExtractor {
  final IriTerm predicate;
  final RdfGroupExtractor groupExtractor;
  final String? missingValue;

  const _PropertyExtractor({
    required this.predicate,
    required this.groupExtractor,
    this.missingValue,
  });
}
