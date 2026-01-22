import 'dart:convert';

import 'package:locorda_rdf_core/core.dart';

/// Translates between application identifiers and storage IRIs for different backends.
///
/// For example:
/// - Solid Pod implementation: Uses type index to find storage location
/// - Google Drive backend: Simple strategy to convert to/from IRIs
abstract class ResourceLocator {
  /// Convert local ID and optional fragment to resource IRI.
  ///
  /// Returns the full IRI for the given resource identifier.
  IriTerm toIri(ResourceIdentifier identifier);

  /// Extract local ID and fragment from resource IRI.
  ///
  /// Returns a record with the localId and optional fragment.
  ///
  /// Throws [UnsupportedIriException] if the IRI cannot be mapped to a ResourceIdentifier.
  ResourceIdentifier fromIri(IriTerm resourceIri, {IriTerm? expectedTypeIri});

  bool isIdentifiableIri(IriTerm subjectIri) {
    try {
      fromIri(subjectIri);
      return true;
    } on UnsupportedIriException catch (_) {
      return false;
    }
  }
}

class UnsupportedIriException implements Exception {
  final String _type;
  final String _message;
  UnsupportedIriException(IriTerm iri, this._message)
      :
        // REALLY important: DO NOT use typeIri.debug here, as it may cause infinite recursion
        // since it calls fromIri again!
        _type = iri.value;
  UnsupportedIriException.forResourceIdentifier(
      ResourceIdentifier iri, this._message)
      : _type = iri.toString();

  @override
  String toString() => 'UnsupportedIriException: IRI $_type - $_message';
}

final class ResourceIdentifier {
  final IriTerm typeIri;
  final String id;
  final String? fragment;

  ResourceIdentifier(this.typeIri, this.id, String fragment)
      : assert(fragment.isNotEmpty),
        fragment = fragment;
  ResourceIdentifier.document(this.typeIri, this.id) : fragment = null;
}

class LocalResourceLocator implements ResourceLocator {
  static const prefix = 'tag:locorda.org,2025:l:';
  final IriTermFactory _iriTermFactory;

  LocalResourceLocator({required IriTermFactory iriTermFactory})
      : _iriTermFactory = iriTermFactory;

  bool isIdentifiableIri(IriTerm subjectIri) => isLocalIri(subjectIri);

  @override
  IriTerm toIri(ResourceIdentifier identifier) {
    final encodedTypeIri =
        base64Url.encode(utf8.encode(identifier.typeIri.value));
    final encodedLocalId = base64Url.encode(utf8.encode(identifier.id));
    return _iriTermFactory(
        '$prefix${encodedTypeIri}:$encodedLocalId${identifier.fragment != null ? '#${identifier.fragment}' : ''}');
  }

  @override
  ResourceIdentifier fromIri(IriTerm resourceIri, {IriTerm? expectedTypeIri}) {
    // Split off fragment if present
    final iriValue = resourceIri.value;
    final fragmentIndex = iriValue.indexOf('#');
    final documentIriValue =
        fragmentIndex >= 0 ? iriValue.substring(0, fragmentIndex) : iriValue;
    final fragment =
        fragmentIndex >= 0 ? iriValue.substring(fragmentIndex + 1) : null;

    if (!documentIriValue.startsWith(prefix)) {
      throw UnsupportedIriException(
          resourceIri, 'Does not belong to base IRI $prefix');
    }

    final encoded = documentIriValue.substring(prefix.length);
    final [encodedTypeIri, encodedLocalId] = encoded.split(':');
    final remoteTypeIri = utf8.decode(base64Url.decode(encodedTypeIri));
    final typeIri = expectedTypeIri ?? _iriTermFactory(remoteTypeIri);
    if (remoteTypeIri != typeIri.value) {
      throw UnsupportedIriException(
          resourceIri,
          // REALLY important: DO NOT use typeIri.debug here, as it may cause infinite recursion
          // since it calls fromIri again!
          'Type ${remoteTypeIri} does not match expected type IRI ${typeIri.value}');
    }

    final localId = utf8.decode(base64Url.decode(encodedLocalId));
    if (fragment == null) {
      return ResourceIdentifier.document(typeIri, localId);
    }
    return ResourceIdentifier(typeIri, localId, fragment);
  }

  ResourceIdentifier fromIriNoType(IriTerm resourceIri) {
    return fromIri(resourceIri);
  }

  static bool isLocalIri(IriTerm subjectIri) {
    return subjectIri.value.startsWith(prefix);
  }
}
