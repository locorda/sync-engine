import 'package:locorda_rdf_core/core.dart';
import 'package:locorda_solid_core/src/solid_backend.dart';
import 'package:test/test.dart';

void main() {
  group('SolidPhysicalDocumentUrlMapper', () {
    test('keeps URL unchanged for file-per-resource semantics', () {
      final mapper = SolidPhysicalDocumentUrlMapper(
        appendFileExtension: false,
        fileExtension: 'ttl',
      );

      final iri = IriTerm.validated('https://pod.example/data/type/resource');

      expect(mapper.toDocumentUrl(iri), iri.value);
    });

    test('appends extension for dataset layouts', () {
      final mapper = SolidPhysicalDocumentUrlMapper(
        appendFileExtension: true,
        fileExtension: 'trig',
      );

      final iri = IriTerm.validated('https://pod.example/indices/type/shard-a');

      expect(
        mapper.toDocumentUrl(iri),
        'https://pod.example/indices/type/shard-a.trig',
      );
    });

    test('does not append extension twice', () {
      final mapper = SolidPhysicalDocumentUrlMapper(
        appendFileExtension: true,
        fileExtension: 'trig',
      );

      final iri =
          IriTerm.validated('https://pod.example/indices/type/shard-a.trig');

      expect(
        mapper.toDocumentUrl(iri),
        'https://pod.example/indices/type/shard-a.trig',
      );
    });
  });
}
