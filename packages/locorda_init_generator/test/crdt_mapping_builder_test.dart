import 'package:locorda_init_generator/src/config/crdt_mapping_builder.dart';
import 'package:test/test.dart';

void main() {
  group('mappingFileNameFromIri', () {
    test('keeps .ttl basename unchanged', () {
      const iri =
          'https://locorda.dev/example/personal_notes_app/mappings/category-v1.ttl';

      expect(mappingFileNameFromIri(iri), 'category-v1.ttl');
    });

    test('keeps .ttl basename unchanged when ending with #', () {
      const iri =
          'https://locorda.dev/example/personal_notes_app/mappings/category-v1.ttl#';

      expect(mappingFileNameFromIri(iri), 'category-v1.ttl');
    });

    test('converts trailing # basename to .ttl', () {
      const iri =
          'https://locorda.dev/example/personal_notes_app/mappings/category-v1#';

      expect(mappingFileNameFromIri(iri), 'category-v1.ttl');
    });
  });
}
