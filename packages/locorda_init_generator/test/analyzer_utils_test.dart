import 'package:locorda_init_generator/src/code_generation/analyzer_utils.dart';
import 'package:test/test.dart';

import 'test_helpers/analyzer_test_utils.dart';

void main() {
  group('typeToCode', () {
    test('converts FunctionType with named parameters and keeps imports',
        () async {
      final result = await resolveTestLibrary(files: {
        'types.dart': 'class Custom {}\n',
        'main.dart': '''
import 'types.dart';

class Holder {
  final String Function(Custom input, {required Custom other})? callback;
  const Holder(this.callback);
}
''',
      });
      final resolved = result.resolved;
      final holder = resolved.libraryElement.classes
          .firstWhere((element) => element.displayName == 'Holder');
      final callbackField =
          holder.fields.firstWhere((field) => field.displayName == 'callback');

      final code = typeToCode(callbackField.type);
      final typesUri = result.fileUris['types.dart']!.toString();

      expect(code.code, contains('Function('));
      expect(code.code, contains('required'));
      expect(code.code, contains('Custom'));
      expect(code.code, contains('?'));
      expect(code.imports.any((uri) => uri.contains('types.dart')), isTrue);
      expect(code.imports.contains(typesUri), isTrue);
    });

    test('converts RecordType and keeps imports for field types', () async {
      final result = await resolveTestLibrary(files: {
        'types.dart': 'class Custom {}\n',
        'main.dart': '''
import 'types.dart';

class Holder {
  final (Custom, {Custom right}) entry;
  const Holder(this.entry);
}
''',
      });
      final resolved = result.resolved;
      final holder = resolved.libraryElement.classes
          .firstWhere((element) => element.displayName == 'Holder');
      final entryField =
          holder.fields.firstWhere((field) => field.displayName == 'entry');

      final code = typeToCode(entryField.type);
      final typesUri = result.fileUris['types.dart']!.toString();

      expect(code.code, contains('(types.Custom'));
      expect(code.code, contains('{types.Custom right}'));
      expect(code.imports.any((uri) => uri.contains('types.dart')), isTrue);
      expect(code.imports.contains(typesUri), isTrue);
    });

    test('converts typedef aliases and keeps alias import', () async {
      final result = await resolveTestLibrary(files: {
        'types.dart': '''
class Custom {}
typedef Mapper<T> = T Function(Custom value);
''',
        'main.dart': '''
import 'types.dart';

class Holder {
  final Mapper<Custom> mapper;
  const Holder(this.mapper);
}
''',
      });
      final resolved = result.resolved;
      final holder = resolved.libraryElement.classes
          .firstWhere((element) => element.displayName == 'Holder');
      final mapperField =
          holder.fields.firstWhere((field) => field.displayName == 'mapper');

      final code = typeToCode(mapperField.type);
      final typesUri = result.fileUris['types.dart']!.toString();

      expect(code.code, contains('types.Mapper<'));
      expect(code.code, contains('types.Custom'));
      expect(code.imports.contains(typesUri), isTrue);
    });

    test('converts nullable generic typedef aliases', () async {
      final result = await resolveTestLibrary(files: {
        'types.dart': '''
class Custom {}
typedef Mapper<T> = T Function(Custom value);
''',
        'main.dart': '''
import 'types.dart';

class Holder {
  final Mapper<Custom>? maybeMapper;
  const Holder(this.maybeMapper);
}
''',
      });
      final resolved = result.resolved;
      final holder = resolved.libraryElement.classes
          .firstWhere((element) => element.displayName == 'Holder');
      final mapperField = holder.fields
          .firstWhere((field) => field.displayName == 'maybeMapper');

      final code = typeToCode(mapperField.type);
      final typesUri = result.fileUris['types.dart']!.toString();

      expect(code.code, contains('types.Mapper<types.Custom>?'));
      expect(code.imports.contains(typesUri), isTrue);
    });
  });

  group('dartObjectToCode', () {
    test('converts function constant tear-off and keeps imports', () async {
      final result = await resolveTestLibrary(files: {
        'types.dart': '''
int parseValue(String input) => input.length;
''',
        'main.dart': '''
import 'types.dart';

const parser = parseValue;
''',
      });
      final resolved = result.resolved;
      final variable = resolved.libraryElement.topLevelVariables
          .firstWhere((element) => element.displayName == 'parser');
      final constValue = variable.computeConstantValue();

      final code = dartObjectToCode(constValue);
      final typesUri = result.fileUris['types.dart']!.toString();

      expect(code.code, contains('types.parseValue'));
      expect(code.imports.contains(typesUri), isTrue);
    });
  });
}
