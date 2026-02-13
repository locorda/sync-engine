import 'dart:io';

import 'package:locorda_rdf_core/core.dart';
import 'package:test/test.dart';

import '../bin/deploy_mappings.dart';

void main() {
  test('extractBootstrapMappings reads multiline raw string list', () {
    const source = '''
const List<String> bootstrapMappings = [
  r"""
@prefix ex: <https://example.com/> .
<https://example.com/mappings/a#> a <https://w3id.org/solid-crdt-sync/vocab/merge-contract#DocumentMapping> .
""",
  r"""
<https://example.com/mappings/b#> {
  <https://example.com/mappings/b#> a <https://w3id.org/solid-crdt-sync/vocab/merge-contract#DocumentMapping> .
}
""",
];
''';

    final mappings = extractBootstrapMappings(source);
    expect(mappings, hasLength(2));
    expect(mappings.first, contains('mappings/a#'));
    expect(mappings.last, contains('mappings/b#'));
  });

  test('deriveMappingFileName appends ttl and disambiguates collisions', () {
    final used = <String, int>{};

    final first = deriveMappingFileName(
      IriTerm('https://example.com/mappings/note-v1#'),
      used,
    );
    final second = deriveMappingFileName(
      IriTerm('https://example.com/mappings/note-v1#other'),
      used,
    );

    expect(first, 'note-v1.ttl');
    expect(second, 'note-v1-2.ttl');
  });

  test('deployMappings writes ttl files for default and named graphs',
      () async {
    final rdfCore = RdfCore.withStandardCodecs();
    final outDir =
        await Directory.systemTemp.createTemp('deploy-mappings-test');
    addTearDown(() async {
      if (await outDir.exists()) {
        await outDir.delete(recursive: true);
      }
    });

    const turtleDoc = '''
<https://example.com/mappings/default-v1#> a <https://w3id.org/solid-crdt-sync/vocab/merge-contract#DocumentMapping> .
''';

    const trigDoc = '''
<https://example.com/mappings/named-v1#> {
  <https://example.com/mappings/named-v1#> a <https://w3id.org/solid-crdt-sync/vocab/merge-contract#DocumentMapping> .
}
''';

    final deployed = await deployMappings(
      rdfCore: rdfCore,
      mappings: const [turtleDoc, trigDoc],
      outputDirectory: outDir,
    );

    expect(deployed, 2);
    expect(await File('${outDir.path}/default-v1.ttl').exists(), isTrue);
    expect(await File('${outDir.path}/named-v1.ttl').exists(), isTrue);
  });
}
