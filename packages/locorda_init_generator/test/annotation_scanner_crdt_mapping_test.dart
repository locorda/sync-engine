import 'package:locorda_init_generator/src/config/annotation_scanner.dart';
import 'package:test/test.dart';

import 'test_helpers/analyzer_test_utils.dart';

// TODO(annotations-tests): These tests intentionally use synthetic annotation
// class shapes to validate low-level DartObject field extraction behavior in
// AnnotationScanner. This is fast, but only partially representative.
//
// Problem:
// - Synthetic classes can drift from the real API in locorda_annotations.
// - Passing tests here do not guarantee end-to-end behavior with real
//   RootResource constructors.
//
// Follow-up (must be implemented):
// 1) Keep only one narrow synthetic regression test for legacy field extraction.
// 2) Move constructor-variant coverage to integration-style tests using real
//    locorda_annotations definitions and real builder/scanner flow.
// 3) Treat private-field-name assertions as implementation detail and avoid
//    depending on copied class internals in test fixtures.
//
// Status: deferred for now due to delivery timing; tracked explicitly here to
// prevent this test style from becoming the long-term default.
void main() {
  test('resolves RootResource.externalVocab generated contract', () async {
    const source = r'''
library;

class IriTerm {
  final String value;
  const IriTerm(this.value);
}

class MergeContract {
  final String version;
  final String? path;
  final bool generate;
  const MergeContract({this.version = 'v1', this.path, this.generate = true});
}

class RootResource {
  final Object? _vocab;
  final IriTerm? _explicitClassIri;
  final String? _contractAppBaseUri;
  final String? _explicitContractIri;
  final MergeContract? contract;
  final bool _generateContract;

  const RootResource.externalVocab(
    IriTerm classIri,
    String mergeContractAppBaseUri, {
    MergeContract mergeContract = const MergeContract(),
  })  : _vocab = null,
        _explicitClassIri = classIri,
        _contractAppBaseUri = mergeContractAppBaseUri,
        _explicitContractIri = null,
        contract = mergeContract,
        _generateContract = true;
}

@RootResource.externalVocab(
  IriTerm('https://schema.org/Article'),
  'https://example.dev',
)
class BlogPost {}
''';

    final resolved = await resolveTestLibrary(files: {'main.dart': source});
    final library = resolved.resolved.libraryElement;

    final result = AnnotationScanner().scanLibrary(library, 'package:a/a.dart');
    final root = result.rootResources.single;

    expect(root.crdtMapping.codeWithoutAlias,
        "'https://example.dev/mappings/blogpost-v1#'");
    expect(root.generateCrdtMapping, isTrue);
  });

  test('normalizes trailing slash in app base uri for generated contract',
      () async {
    const source = r'''
library;

class IriTerm {
  final String value;
  const IriTerm(this.value);
}

class MergeContract {
  final String version;
  final String? path;
  final bool generate;
  const MergeContract({this.version = 'v1', this.path, this.generate = true});
}

class RootResource {
  final Object? _vocab;
  final IriTerm? _explicitClassIri;
  final String? _contractAppBaseUri;
  final String? _explicitContractIri;
  final MergeContract? contract;
  final bool _generateContract;

  const RootResource.externalVocab(
    IriTerm classIri,
    String mergeContractAppBaseUri, {
    MergeContract mergeContract = const MergeContract(),
  })  : _vocab = null,
        _explicitClassIri = classIri,
        _contractAppBaseUri = mergeContractAppBaseUri,
        _explicitContractIri = null,
        contract = mergeContract,
        _generateContract = true;
}

@RootResource.externalVocab(
  IriTerm('https://schema.org/Article'),
  'https://example.dev/',
)
class BlogPost {}
''';

    final resolved = await resolveTestLibrary(files: {'main.dart': source});
    final library = resolved.resolved.libraryElement;

    final result = AnnotationScanner().scanLibrary(library, 'package:a/a.dart');
    final root = result.rootResources.single;

    expect(root.crdtMapping.codeWithoutAlias,
        "'https://example.dev/mappings/blogpost-v1#'");
  });

  test('resolves RootResource.externalContract as non-generated', () async {
    const source = r'''
library;

class AppVocab {
  final String appBaseUri;
  const AppVocab({required this.appBaseUri});
}

class RootResource {
  final AppVocab? _vocab;
  final Object? _explicitClassIri;
  final String? _contractAppBaseUri;
  final String? _explicitContractIri;
  final Object? contract;
  final bool _generateContract;

  const RootResource.externalContract(
    AppVocab vocab,
    String mergeContractIri,
  )   : _vocab = vocab,
        _explicitClassIri = null,
        _contractAppBaseUri = null,
        _explicitContractIri = mergeContractIri,
        contract = null,
        _generateContract = false;
}

const appVocab = AppVocab(appBaseUri: 'https://example.dev');

@RootResource.externalContract(
  appVocab,
  'https://contracts.example.com/note-v1#',
)
class StandardNote {}
''';

    final resolved = await resolveTestLibrary(files: {'main.dart': source});
    final library = resolved.resolved.libraryElement;

    final result = AnnotationScanner().scanLibrary(library, 'package:a/a.dart');
    final root = result.rootResources.single;

    expect(root.crdtMapping.codeWithoutAlias,
        "'https://contracts.example.com/note-v1#'");
    expect(root.generateCrdtMapping, isFalse);
  });

  test('resolves RootResource.external as non-generated', () async {
    const source = r'''
library;

class IriTerm {
  final String value;
  const IriTerm(this.value);
}

class RootResource {
  final Object? _vocab;
  final IriTerm? _explicitClassIri;
  final String? _contractAppBaseUri;
  final String? _explicitContractIri;
  final Object? contract;
  final bool _generateContract;

  const RootResource.external(
    IriTerm classIri,
    String mergeContractIri,
  )   : _vocab = null,
        _explicitClassIri = classIri,
        _contractAppBaseUri = null,
        _explicitContractIri = mergeContractIri,
        contract = null,
        _generateContract = false;
}

@RootResource.external(
  IriTerm('https://schema.org/Recipe'),
  'https://schema.org/contracts/recipe-v1#',
)
class Recipe {}
''';

    final resolved = await resolveTestLibrary(files: {'main.dart': source});
    final library = resolved.resolved.libraryElement;

    final result = AnnotationScanner().scanLibrary(library, 'package:a/a.dart');
    final root = result.rootResources.single;

    expect(root.crdtMapping.codeWithoutAlias,
        "'https://schema.org/contracts/recipe-v1#'");
    expect(root.generateCrdtMapping, isFalse);
  });
}
