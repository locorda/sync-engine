import 'package:build/build.dart';
import 'package:build_test/build_test.dart';
import 'package:locorda_mapping_bootstrap_generator/src/mapping_bootstrap_builder.dart';
import 'package:test/test.dart';

void main() {
  test('collects cache trig and asset rdf files into bootstrapMappings',
      () async {
    final builder = mappingBootstrapBuilder(
      BuilderOptions(
        {
          'mapping_roots': ['assets/contracts/mappings'],
        },
      ),
    );

    await testBuilder(
      builder,
      {
        'a|pubspec.yaml': 'name: a',
        'a|lib/domain/category.crdt.cache.trig': '''
<https://example.com/mappings/category-v1#> {
  <https://example.com/mappings/category-v1#> a <https://w3id.org/solid-crdt-sync/vocab/merge-contract#DocumentMapping> .
}
''',
        'a|assets/contracts/mappings/manual.ttl': '''
<https://example.com/mappings/manual-v1#> a <https://w3id.org/solid-crdt-sync/vocab/merge-contract#DocumentMapping> .
''',
      },
      rootPackage: 'a',
      outputs: {
        'a|lib/src/generated/mapping_bootstrap.g.dart': decodedMatches(
          allOf(
            contains('const List<String> bootstrapMappings = ['),
            contains('r"""'),
            contains('category-v1#'),
            contains('manual-v1#'),
          ),
        ),
      },
    );
  });
}
