/// Resource-focused configuration for CRDT sync setup.
///
/// This provides a resource-centric API where all configuration flows from
/// "what resources am I working with?" rather than separate configuration
/// of indices, mappings, and paths.
library;

import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_rdf_core/core.dart';

/// Configuration for the entire sync system organized by resources.
class SyncEngineConfigValidator {
  final ConfigBaseValidator _baseValidator =
      ConfigBaseValidator((c) => (c as ResourceConfigData).typeIri.value);

  SyncEngineConfigValidator();

  /// Validate this configuration for consistency and correctness.
  ValidationResult validate(SyncEngineConfig config) {
    final result = _baseValidator.validate(config);
    _validateResourceUniqueness(config, result);

    return result;
  }

  void _validateResourceUniqueness(
      SyncEngineConfig config, ValidationResult result) {
    // Check for duplicate Dart types
    final typeIris = <IriTerm>{};

    for (final resource in config.resources) {
      // Check for duplicate Dart types
      if (typeIris.contains(resource.typeIri)) {
        result.addError(
            'Duplicate resource type: ${resource.typeIri}. Each  type can only be configured once.',
            details: {'type': resource.typeIri});
        continue; // Skip further processing for this resource
      }
      typeIris.add(resource.typeIri);
    }
  }
}
