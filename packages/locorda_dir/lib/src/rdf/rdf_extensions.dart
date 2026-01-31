import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_rdf_core/core.dart';

extension IriTermExtensions on IriTerm {
  // 'late final debug = _iriToDebugString(this);' would be much nicer,
  // but isn't supported yet in extension methods
  String get debug => _iriToDebugString(this);

  static String _iriToDebugString(IriTerm iri) {
    try {
      final rl = LocalResourceLocator(iriTermFactory: IriTerm.new);
      final r = rl.fromIriNoType(iri);
      final type =
          r.typeIri.value.startsWith('https://w3id.org/solid-crdt-sync/vocab/')
              ? r.typeIri.value
                  .substring('https://w3id.org/solid-crdt-sync/vocab/'.length)
                  .replaceAll('#', ':')
              : r.typeIri.value;
      return '<${type} | ${r.id}${r.fragment != null ? ' # ${r.fragment!}' : ''}>';
    } catch (_) {
      return iri.value;
    }
  }

  String get localName {
    final hashIndex = value.lastIndexOf('#');
    if (hashIndex != -1 && hashIndex <= value.length - 1) {
      return value.substring(hashIndex + 1);
    }
    final slashIndex = value.lastIndexOf('/');
    if (slashIndex != -1 && slashIndex <= value.length - 1) {
      return value.substring(slashIndex + 1);
    }
    return value; // Fallback to full IRI if no separator found
  }
}
