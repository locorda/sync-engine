import 'package:build/build.dart';
import 'package:build_test/build_test.dart';
import 'package:locorda_init_generator/src/config/crdt_mapping_builder.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

// TODO(annotations-tests): This file currently uses synthetic inlined
// annotation class copies to validate predicate mapping generation behavior.
//
// Problem:
// - It validates a reconstructed shape of annotations, not the real API.
// - This can pass while real locorda_annotations-based flows break.
//
// Follow-up (must be implemented):
// 1) Keep only a minimal synthetic regression case for parser edge behavior.
// 2) Add/shift primary coverage to integration tests with real
//    locorda_annotations classes and builder execution.
// 3) Remove reliance on copied internal fields as test contract.
//
// Status: deferred for now due to delivery timing; tracked explicitly.
String _sourceWithMappingIri(String mappingIri) => '''
library;

class IriTerm {
  final String value;
  const IriTerm(this.value);
}

class MergeContract {
  final String mappingIri;
  final String? label;
  final String? comment;
  final List<IriTerm> imports;
  final bool generate;

  const MergeContract(this.mappingIri,
      {this.label, this.comment, this.imports = const [], this.generate = true});
}

class RootResource {
  final IriTerm? classIri;
  final MergeContract crdt;
  const RootResource(this.classIri, this.crdt);
}

class LocalResource {
  final IriTerm? classIri;
  const LocalResource({this.classIri});
}

class RdfProperty {
  final IriTerm predicate;
  const RdfProperty(this.predicate);
}

class CrdtLwwRegister {
  const CrdtLwwRegister();
}

class CrdtImmutable {
  const CrdtImmutable();
}

@LocalResource()
class CategoryDisplaySettings {
  @RdfProperty(IriTerm('https://example.dev/vocab#categoryColor'))
  @CrdtLwwRegister()
  final String? color = null;

  @RdfProperty(IriTerm('https://example.dev/vocab#categoryIcon'))
  @CrdtLwwRegister()
  final String? icon = null;
}

@RootResource(
  IriTerm('https://example.dev/vocab#Category'),
  MergeContract('$mappingIri'),
)
class Category {
  @RdfProperty(IriTerm('https://example.dev/vocab#displaySettings'))
  @CrdtImmutable()
  final CategoryDisplaySettings? settings = null;
}
''';

void main() {
  test('generates mc:predicateMapping for typeless local resource', () async {
    final builder = crdtMappingBuilder(BuilderOptions.empty);

    final source = _sourceWithMappingIri(
      'https://example.dev/mappings/category-v1#',
    );

    final result = await testBuilder(
      builder,
      {
        'a|lib/domain/category.dart': source,
      },
      rootPackage: 'a',
      outputs: {
        'a|lib/domain/category.crdt.cache.trig': decodedMatches(
          allOf(
            contains('mc:predicateMapping'),
            contains('mc:PredicateMapping'),
            contains('categoryColor'),
            contains('categoryIcon'),
          ),
        ),
      },
    );

    final outputId = AssetId('a', 'lib/domain/category.crdt.cache.trig');
    expect(result.outputs, contains(outputId));
  });

  test('preserves mapping IRI as-is without fragment', () async {
    final builder = crdtMappingBuilder(BuilderOptions.empty);

    final source = _sourceWithMappingIri(
      'https://example.dev/mappings/category-v1',
    );

    final result = await testBuilder(
      builder,
      {
        'a|lib/domain/category.dart': source,
      },
      rootPackage: 'a',
      outputs: {
        'a|lib/domain/category.crdt.cache.trig': decodedMatches(
          allOf(
            contains('GRAPH'),
            contains('mc:DocumentMapping'),
            // IRI appears in prefix or as namespace
            anyOf(
              contains('@prefix mappings: <https://example.dev/mappings/>'),
              contains('mappings:category-v1'),
            ),
          ),
        ),
      },
    );

    final outputId = AssetId('a', 'lib/domain/category.crdt.cache.trig');
    expect(result.outputs, contains(outputId));
  });

  test('accepts mapping IRI with non-empty fragment', () async {
    final builder = crdtMappingBuilder(BuilderOptions.empty);

    final source = _sourceWithMappingIri(
      'https://example.dev/mappings/category-v1#v1',
    );

    final result = await testBuilder(
      builder,
      {
        'a|lib/domain/category.dart': source,
      },
      rootPackage: 'a',
      outputs: {
        'a|lib/domain/category.crdt.cache.trig': decodedMatches(
          allOf(
            contains('GRAPH'),
            contains('mc:DocumentMapping'),
            // IRI with fragment appears in prefix declaration
            contains('https://example.dev/mappings/category-v1#'),
          ),
        ),
      },
    );

    final outputId = AssetId('a', 'lib/domain/category.crdt.cache.trig');
    expect(result.outputs, contains(outputId));
  });

  test('rejects mapping IRI without absolute base', () async {
    final builder = crdtMappingBuilder(BuilderOptions.empty);

    final source = _sourceWithMappingIri('mappings/category-v1#');

    final logs = <LogRecord>[];

    await testBuilder(
      builder,
      {
        'a|lib/domain/category.dart': source,
      },
      rootPackage: 'a',
      onLog: logs.add,
    );

    expect(
      logs.any(
        (log) =>
            log.message.contains('CRDT mapping IRI') &&
            log.message.contains('must be absolute'),
      ),
      isTrue,
    );
  });
}
