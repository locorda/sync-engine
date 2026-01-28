/// Service providing IRI mapping factories for resources.
///
/// This service creates factory functions that handle resource identification
/// and referencing within the CRDT sync system. The factories work together
/// to provide consistent IRI mapping across the application.
library;

import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:locorda_rdf_mapper/mapper.dart';
import '../config/locorda_config_util.dart';

/// Offline-first IRI mapping service for offline and pre-pod-connection usage.
///
/// This service generates stable, deterministic local IRIs using the scheme:
/// `app://local/{type-name}/{id}` for both resources and references.
///
/// This service implements a two-phase state machine:
///
/// **Setup Phase**: Mappers can be created via:
/// - [createResourceIriMapper]: Creates mappers for primary resource identification
/// - [createResourceRefMapper]: Creates mappers for resource references
///
/// **Runtime Phase**: After [finishSetupAndValidate] is called, no new mappers
/// can be created. The service validates that all referenced types were properly
/// registered as resource types.
///
/// Local IRIs are stable and collision-free, making them suitable for offline
/// usage and later migration to pod-based IRIs when connecting to a Solid Pod.
class LocalResourceIriService {
  bool _isSetupComplete = false;
  Map<Type, RootIriConfig> _registeredTypes = {};
  Set<Type> _referencedTypes = {};

  final List<ValidationError> _setupErrors = [];

  final LocalResourceLocator _resourceLocator;
  final _DelegatingReferenceConverter _converter;
  LocalResourceIriService(this._resourceLocator)
      : _converter = _DelegatingReferenceConverter();

  /// Creates a mapper for primary resource IRI mapping during setup phase.
  ///
  /// **Setup Phase Only**: This method must only be called before
  /// [finishSetupAndValidate].
  ///
  /// Creates an [IriTermMapper] for primary resource identification using ID tuples
  /// and the provided [RootIriConfig]. Each type can only be registered once.
  ///
  /// Throws [StateError] if called after setup phase is complete.
  /// Validation errors will be collected if type T is already registered.
  IriTermMapper<(String id,)> createResourceIriMapper<T>(RootIriConfig config) {
    // This is a programming constraint - throw immediately
    if (_isSetupComplete) {
      throw StateError(
          'Resource IRI mapper cannot be created after setup is complete');
    }

    // This is a configuration validation issue - collect for later reporting
    if (_registeredTypes.containsKey(T)) {
      _setupErrors.add(ValidationError(
          [], 'Resource IRI mapper for type $T is already registered',
          details: {'type': T, 'operation': 'createResourceIriMapper'}));
    } else {
      _registeredTypes[T] = config;
    }

    // Create local IRI mapper for type T using the tuple (String id,) pattern
    return _LocalResourceIriMapper<T>(_converter);
  }

  /// Creates a mapper for resource reference mapping during setup phase.
  ///
  /// **Setup Phase Only**: This method must only be called before
  /// [finishSetupAndValidate].
  ///
  /// Creates an [IriTermMapper] for resource references using string identifiers.
  /// The [targetType] specifies which resource type this mapper references.
  /// Multiple references to the same type are allowed.
  ///
  /// Throws [StateError] if called after setup phase is complete.
  IriTermMapper<String> createResourceRefMapper<T>(Type targetType) {
    // This is a programming constraint - throw immediately
    if (_isSetupComplete) {
      throw StateError(
          'Resource reference mapper cannot be created after setup is complete');
    }
    // referencing the same type multiple times of course is fine
    _referencedTypes.add(targetType);

    // Create local reference mapper that uses the same IRI scheme as resources
    return _LocalReferenceIriMapper(_converter, targetType);
  }

  IriTermMapper<(String,)> createIndexItemIriMapper<T>(Type targetType) {
    // This is a programming constraint - throw immediately
    if (_isSetupComplete) {
      throw StateError(
          'Index item IRI mapper cannot be created after setup is complete');
    }
    // referencing the same type multiple times of course is fine
    _referencedTypes.add(targetType);

    // Create local reference mapper that uses the same IRI scheme as resources
    return _LocalIndexItemIriMapper(_converter, targetType);
  }

  /// Validates the current setup configuration.
  ///
  /// Returns a [ValidationResult] containing any errors or warnings found
  /// during setup. This should be called before [finishSetupAndValidate]
  /// to check for issues.
  ///
  /// Validates:
  /// - Setup errors collected during mapper creation
  /// - Referenced types have corresponding registered types
  /// - Resource type cache consistency
  ValidationResult validate(ResourceTypeCache resourceTypeCache) {
    final result = ValidationResult();

    // Add any setup errors that were collected during mapper creation
    for (final error in _setupErrors) {
      result.errors.add(error);
    }

    // Validate that all referenced types were registered as resource types
    _validateReferencedTypes(result);

    // Validate resource type cache consistency
    _validateResourceTypeCache(result, resourceTypeCache);

    return result;
  }

  void _validateReferencedTypes(ValidationResult result) {
    for (final refType in _referencedTypes) {
      if (!_registeredTypes.containsKey(refType)) {
        result.addError(
            'Referenced type $refType was not registered as a resource type. '
            'All types used in resource references must be registered via createResourceIriMapper.',
            details: {
              'referencedType': refType,
              'registeredTypes': _registeredTypes.keys.toList()
            });
      }
    }
  }

  void _validateResourceTypeCache(
      ValidationResult result, ResourceTypeCache resourceTypeCache) {
    for (final type in _registeredTypes.keys) {
      final hasIriTerm = resourceTypeCache.hasIri(type);
      if (!hasIriTerm) {
        result.addError(
            'Missing IRI term for registered type $type in resource type cache. '
            'This indicates a configuration error in the RDF mapper setup.',
            details: {'type': type});
      }
    }
  }

  /// Transitions from setup phase to runtime phase and validates configuration.
  ///
  /// This method:
  /// 1. Validates the entire setup configuration
  /// 2. Marks the service as setup complete (prevents further mapper creation)
  /// 3. Caches the resource type IRI mappings for runtime use if validation passes
  ///
  /// Returns a [ValidationResult] that should be checked before proceeding.
  /// If validation fails, the service remains in setup phase and no state changes occur.
  ValidationResult finishSetupAndValidate(ResourceTypeCache resourceTypeCache) {
    // First validate the configuration
    final validationResult = validate(resourceTypeCache);

    final _resourceConfigCache = <Type, (IriTerm, RootIriConfig)>{};
    // Only proceed with setup completion if validation passes
    if (validationResult.isValid) {
      _isSetupComplete = true;

      // Cache the IRI terms for registered types
      _registeredTypes.forEach((type, config) {
        final iriTerm = resourceTypeCache.getIri(type);
        _resourceConfigCache[type] = (iriTerm, config);
      });
    }
    _converter._inner = LocalReferenceConverter(
        resourceLocator: _resourceLocator,
        resourceConfigCache: _resourceConfigCache);
    return validationResult;
  }
}

/// Local IRI mapper for primary resources using the app://local/{type}/{id} scheme.
class _LocalResourceIriMapper<T> implements IriTermMapper<(String,)> {
  final ReferenceConverter _converter;

  const _LocalResourceIriMapper(this._converter);

  @override
  (String,) fromRdfTerm(IriTerm term, DeserializationContext context) {
    final id = _converter.fromIri(T, term);
    return (id,);
  }

  @override
  IriTerm toRdfTerm((String,) value, SerializationContext context) {
    final (id,) = value;
    return _converter.toIri(T, id);
  }
}

/// Local IRI mapper for resource references using the same scheme as resources.
class _LocalReferenceIriMapper implements IriTermMapper<String> {
  final Type targetType;
  final ReferenceConverter _converter;

  const _LocalReferenceIriMapper(this._converter, this.targetType);

  @override
  String fromRdfTerm(IriTerm term, DeserializationContext context) {
    return _converter.fromIri(targetType, term);
  }

  @override
  IriTerm toRdfTerm(String value, SerializationContext context) {
    return _converter.toIri(targetType, value);
  }
}

class _LocalIndexItemIriMapper implements IriTermMapper<(String,)> {
  final Type targetType;
  final ReferenceConverter _converter;

  const _LocalIndexItemIriMapper(this._converter, this.targetType);

  @override
  (String,) fromRdfTerm(IriTerm term, DeserializationContext context) {
    final id = _converter.fromIri(targetType, term);
    return (id,);
  }

  @override
  IriTerm toRdfTerm((String,) value, SerializationContext context) {
    final (id,) = value;
    return _converter.toIri(targetType, id);
  }
}

abstract interface class ReferenceConverter {
  String fromIri(Type targetType, IriTerm term);
  IriTerm toIri(Type targetType, String value);
}

class _DelegatingReferenceConverter implements ReferenceConverter {
  late final ReferenceConverter _inner;

  _DelegatingReferenceConverter();

  @override
  String fromIri(Type targetType, IriTerm term) {
    return _inner.fromIri(targetType, term);
  }

  @override
  IriTerm toIri(Type targetType, String value) {
    return _inner.toIri(targetType, value);
  }
}

/// Local IRI mapper for resource references using the same scheme as resources.
class LocalReferenceConverter implements ReferenceConverter {
  final ResourceLocator _resourceLocator;
  final Map<Type, (IriTerm, RootIriConfig)> _resourceConfigCache;

  const LocalReferenceConverter(
      {required ResourceLocator resourceLocator,
      required Map<Type, (IriTerm, RootIriConfig)> resourceConfigCache})
      : _resourceLocator = resourceLocator,
        _resourceConfigCache = resourceConfigCache;

  String fromIri(Type targetType, IriTerm term) {
    final (typeIri, config) = _resourceConfigCache[targetType]!;
    final result = _resourceLocator.fromIri(term, expectedTypeIri: typeIri);
    if (result.fragment != config.fragment) {
      throw ArgumentError(
          'Resource IRI ${term.value} does not match expected fragment "${config.fragment}" for type $targetType');
    }
    return result.id;
  }

  IriTerm toIri(Type targetType, String value) {
    assert(_resourceConfigCache.containsKey(targetType),
        'No resource configuration found for target type $targetType');

    final (typeIri, config) = _resourceConfigCache[targetType]!;
    return _resourceLocator
        .toIri(ResourceIdentifier(typeIri, value, config.fragment));
  }
}
