import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_core/src/util/lru_cache.dart';
import 'package:locorda_rdf_core/core.dart';

extension IriTermExtensions on IriTerm {
  static final LRUCache<IriTerm, String> _debugStringCache =
      LRUCache<IriTerm, String>(maxCacheSize: 100);

  // 'late final debug = _iriToDebugString(this);' would be much nicer,
  // but isn't supported yet in extension methods
  String get debug => _debugStringCache.putIfAbsent(this, _iriToDebugString);

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
}
