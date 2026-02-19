import 'package:locorda_init_generator/src/config/annotation_scanner.dart';
import 'package:test/test.dart';

import 'test_helpers/analyzer_test_utils.dart';

void main() {
  test('strips trailing # for string mapping IRIs', () async {
    const source = r'''
library;

class IriTerm {
  final String value;
  const IriTerm(this.value);
}

class MergeContract {
  final String mappingIri;
  final bool generate;
  const MergeContract(this.mappingIri, {this.generate = true});
}

class RootResource {
  final IriTerm? classIri;
  final MergeContract crdt;
  const RootResource(this.classIri, this.crdt);
}

@RootResource(
  IriTerm('https://example.dev/vocab#Note'),
  MergeContract('https://example.dev/mappings/note-v1#'),
)
class Note {}
''';

    final resolved = await resolveTestLibrary(files: {
      'main.dart': source,
    });
    final library = resolved.resolved.libraryElement;

    final result = AnnotationScanner().scanLibrary(library, 'package:a/a.dart');
    final root = result.rootResources.single;

    expect(
      root.crdtMapping.codeWithoutAlias,
      "'https://example.dev/mappings/note-v1#'",
    );
  });
}
