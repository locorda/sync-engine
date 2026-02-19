import 'package:build/build.dart';
import 'package:build_test/build_test.dart';
import 'package:locorda_init_generator/src/config/crdt_mapping_builder.dart';
import 'package:test/test.dart';

// TODO(annotations-tests): This file uses synthetic inlined annotation class
// definitions to exercise CrdtMappingBuilder behavior for RootResource
// constructor variants. This is quick to run, but only partially realistic.
//
// Problem:
// - Fixture classes can drift from real locorda_annotations API semantics.
// - Passing tests here do not guarantee that real annotations work end-to-end.
//
// Follow-up (must be implemented):
// 1) Keep only one narrow synthetic regression case if needed.
// 2) Move variant coverage to integration tests with real
//    locorda_annotations types and build pipeline.
// 3) Avoid depending on copied internal field shapes as primary contract.
//
// Status: deferred for delivery timing; explicitly tracked to avoid normalizing
// synthetic fixture coverage as the main test strategy.
void main() {
  test('generates contract and predicates for RootResource(AppVocab)',
      () async {
    final builder = crdtMappingBuilder(BuilderOptions.empty);

    const source = r'''
library;

class IriTerm {
  final String value;
  const IriTerm(this.value);
}

class AppVocab {
  final String appBaseUri;
  final String vocabPath;
  final Map<String, IriTerm> wellKnownProperties;

  const AppVocab({
    required this.appBaseUri,
    this.vocabPath = '/vocab',
    this.wellKnownProperties = const {},
  });
}

class MergeContract {
  final String version;
  final String? path;
  final List<IriTerm> imports;
  final String? label;
  final String? comment;
  final bool generate;

  const MergeContract({
    this.version = 'v1',
    this.path,
    this.imports = const [],
    this.label,
    this.comment,
    this.generate = true,
  });
}

class RootResource {
  final AppVocab? generatorVocab;
  final IriTerm? explicitClassIri;
  final String? contractAppBaseUri;
  final String? explicitContractIri;
  final MergeContract? contract;
  final bool generateContract;

  const RootResource(
    AppVocab vocab, {
    MergeContract mergeContract = const MergeContract(),
    })  : generatorVocab = vocab,
      explicitClassIri = null,
      contractAppBaseUri = null,
      explicitContractIri = null,
      contract = mergeContract,
      generateContract = true;
}

class CrdtImmutable {
  const CrdtImmutable();
}

const appVocab = AppVocab(
  appBaseUri: 'https://example.dev/',
  wellKnownProperties: {
    'title': IriTerm('http://purl.org/dc/terms/title'),
  },
);

@RootResource(appVocab)
class Task {
  final String title = '';

  @CrdtImmutable()
  final bool completed = false;
}
''';

    final result = await testBuilder(
      builder,
      {'a|lib/domain/task.dart': source},
      rootPackage: 'a',
      outputs: {
        'a|lib/domain/task.crdt.cache.trig': decodedMatches(
          allOf(
            anyOf(
              contains('https://example.dev/mappings/task-v1#'),
              contains('<mappings/task-v1#>'),
            ),
            anyOf(
              contains('https://example.dev/vocab#Task'),
              contains('ex:Task'),
              contains('<vocab#Task>'),
            ),
            anyOf(
              contains('http://purl.org/dc/terms/title'),
              contains('dcterms:title'),
            ),
            anyOf(
              contains('https://example.dev/vocab#completed'),
              contains('ex:completed'),
              contains('<vocab#completed>'),
            ),
          ),
        ),
      },
    );

    expect(result.outputs,
        contains(AssetId('a', 'lib/domain/task.crdt.cache.trig')));
  });

  test('does not generate file for RootResource.external contract', () async {
    final builder = crdtMappingBuilder(BuilderOptions.empty);

    const source = r'''
library;

class IriTerm {
  final String value;
  const IriTerm(this.value);
}

class RootResource {
  final Object? generatorVocab;
  final IriTerm? explicitClassIri;
  final String? contractAppBaseUri;
  final String? explicitContractIri;
  final Object? contract;
  final bool generateContract;

  const RootResource.external(
    IriTerm classIri,
    String mergeContractIri,
    )   : generatorVocab = null,
      explicitClassIri = classIri,
      contractAppBaseUri = null,
      explicitContractIri = mergeContractIri,
      contract = null,
      generateContract = false;
}

@RootResource.external(
  IriTerm('https://schema.org/Recipe'),
  'https://schema.org/contracts/recipe-v1#',
)
class Recipe {
  final String name = '';
}
''';

    final result = await testBuilder(
      builder,
      {'a|lib/domain/recipe.dart': source},
      rootPackage: 'a',
    );

    expect(result.outputs, isEmpty);
  });
}
