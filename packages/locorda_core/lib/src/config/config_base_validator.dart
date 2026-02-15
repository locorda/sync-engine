/// Resource-focused configuration for CRDT sync setup.
///
/// This provides a resource-centric API where all configuration flows from
/// "what resources am I working with?" rather than separate configuration
/// of indices, mappings, and paths.
library;

import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:locorda_core/src/index/regex_transform_validation.dart';

/// Configuration for the entire sync system organized by resources.
class ConfigBaseValidator {
  final String Function(ResourceConfigBase) _getDebugName;

  const ConfigBaseValidator(this._getDebugName);

  /// Validates an IRI string by attempting to construct an IriTerm from it.
  /// Adds an error to the ValidationResult if the IRI is invalid.
  static void _validateIri(IriTerm iri, ValidationResult result, String context,
      {Map<String, Object>? contextData}) {
    try {
      // Attempt to create a validated IriTerm to ensure the IRI is valid
      IriTerm.validated(iri.value);
    } catch (e) {
      result.addError('$context: Invalid IRI "$iri" - $e', details: {
        'iri': iri,
        'validation_error': e.toString(),
        ...?contextData,
      });
    }
  }

  /// Validate this configuration for consistency and correctness.
  ValidationResult validate(ConfigBase config) {
    final result = ValidationResult();

    _validateCrdtMappings(config, result);
    _validateIndexConfigurations(config, result);

    return result;
  }

  void _validateCrdtMappings(ConfigBase config, ValidationResult result) {
    for (final resource in config.resources) {
      final uri = resource.crdtMapping;

      // Check if base URI (without fragment) is absolute.
      // URIs with fragments (e.g., https://example.org/path#) are valid
      // as long as the base is absolute.
      final baseUri =
          uri.hasFragment ? uri.removeFragment() : uri;
      if (!baseUri.isAbsolute) {
        result.addError(
            'CRDT mapping URI must be absolute for ${_getDebugName(resource)}: $uri',
            details: {'type': _getDebugName(resource), 'uri': uri});
      }

      if (uri.scheme == 'http') {
        result.addWarning(
            'CRDT mapping URI should use HTTPS for ${_getDebugName(resource)}: $uri',
            details: {'type': _getDebugName(resource), 'uri': uri});
      }
    }
  }

  void _validateIndexConfigurations(
      ConfigBase config, ValidationResult result) {
    for (final resource in config.resources) {
      for (final index in resource.indices) {
        // Check for empty or invalid local names
        if (index.localName.isEmpty) {
          result.addError(
              'Index local name cannot be empty for ${_getDebugName(resource)}',
              details: {'type': _getDebugName(resource), 'index': index});
        }

        // Validate GroupIndex specific requirements
        if (index is GroupIndexConfigBase) {
          if (index.groupingProperties.isEmpty) {
            result.addError(
                'GroupIndex must have at least one grouping property for ${_getDebugName(resource)}',
                details: {'type': _getDebugName(resource), 'index': index});
          }

          // Validate grouping properties
          for (final property in index.groupingProperties) {
            // Validate predicate IRI
            _validateIri(
              property.predicate,
              result,
              'GroupingProperty predicate for ${_getDebugName(resource)}',
              contextData: {
                'type': _getDebugName(resource),
                'property': property.predicate.value,
                'index': index,
              },
            );

            // Check for zero or negative hierarchy levels
            if (property.hierarchyLevel <= 0) {
              result.addError(
                  'GroupingProperty hierarchy level must be positive for ${_getDebugName(resource)}. Got: ${property.hierarchyLevel}',
                  details: {
                    'type': _getDebugName(resource),
                    'property': property.predicate.value,
                    'hierarchyLevel': property.hierarchyLevel,
                    'index': index,
                  });
            }

            // Check for empty missing value
            if (property.missingValue != null &&
                property.missingValue!.isEmpty) {
              result.addError(
                  'GroupingProperty missing value cannot be empty for ${_getDebugName(resource)}. Use null to indicate no default value.',
                  details: {
                    'type': _getDebugName(resource),
                    'property': property.predicate.value,
                    'missingValue': property.missingValue,
                    'index': index,
                  });
            }

            // Validate regex transforms
            if (property.transforms != null &&
                property.transforms!.isNotEmpty) {
              final transformValidationResult =
                  RegexTransformValidator.validateList(property.transforms!);
              result.addSubvalidationResult(
                transformValidationResult,
                context:
                    '[${_getDebugName(resource)}][Grouping][${property.predicate.value}]',
                details: {
                  'type': _getDebugName(resource),
                  'property': property.predicate.value,
                  'index': index,
                },
              );
            }
          }

          // Check for hierarchy level gaps
          final hierarchyLevels = index.groupingProperties
              .map((p) => p.hierarchyLevel)
              .toSet()
              .toList()
            ..sort();

          for (int i = 1; i < hierarchyLevels.length; i++) {
            if (hierarchyLevels[i] - hierarchyLevels[i - 1] > 1) {
              result.addWarning(
                  'Hierarchy level gap detected in GroupIndex for ${_getDebugName(resource)}: '
                  'level ${hierarchyLevels[i - 1]} is followed by ${hierarchyLevels[i]}. '
                  'Consider using consecutive hierarchy levels for better organization.',
                  details: {
                    'type': _getDebugName(resource),
                    'gap_before': hierarchyLevels[i - 1],
                    'gap_after': hierarchyLevels[i],
                    'index': index,
                  });
            }
          }
        }
      }
    }
  }
}
