import 'package:locorda_init_generator/src/code_generator.dart';
import 'package:locorda_init_generator/src/code_generation/code.dart';
import 'package:locorda_init_generator/src/parameter_info.dart';
import 'package:test/test.dart';

Code cType(String typeName) => Code.literal(typeName);

void main() {
  group('CodeGenerator', () {
    test('generates basic initLocorda with no detection', () {
      final generator = CodeGenerator(
        hasGeneratedWorker: false,
        hasInitMapper: false,
        hasGeneratedConfig: false,
        locordaParams: [
          ParameterInfo(
            name: 'workerSetup',
            type: cType('WorkerSetup'),
            isRequired: true,
            isNamed: true,
          ),
          ParameterInfo(
            name: 'config',
            type: cType('LocordaConfig'),
            isRequired: true,
            isNamed: true,
          ),
        ],
        mapperParams: const [],
        detectedFrameworkParams: const {},
      );

      final code = generator.generate();

      expect(code, contains('Future<Locorda> initLocorda({'));
      expect(code, contains('required WorkerSetup workerSetup,'));
      expect(code, contains('required LocordaConfig config,'));
      expect(code, contains('Locorda.create('));
    });

    test('generates initLocorda with worker detection', () {
      final generator = CodeGenerator(
        hasGeneratedWorker: true,
        hasInitMapper: false,
        hasGeneratedConfig: false,
        locordaParams: [
          ParameterInfo(
            name: 'workerSetup',
            type: cType('WorkerSetup'),
            isRequired: true,
            isNamed: true,
          ),
          ParameterInfo(
            name: 'config',
            type: cType('LocordaConfig'),
            isRequired: true,
            isNamed: true,
          ),
        ],
        mapperParams: const [],
        detectedFrameworkParams: const {},
      );

      final code = generator.generate();

      // Should not include workerSetup in signature
      expect(code, isNot(contains('required WorkerSetup workerSetup,')));

      // Should include it in the call
      expect(code, contains('generatedWorkerSetup,'));
      expect(code, contains("jsScript: 'worker_generated.dart.js',"));

      // Should import worker_generated.g.dart
      expect(code, contains("import 'worker_generated.g.dart'"));
    });

    test('generates initLocorda with mapper detection', () {
      final generator = CodeGenerator(
        hasGeneratedWorker: false,
        hasInitMapper: true,
        hasGeneratedConfig: false,
        locordaParams: [
          ParameterInfo(
            name: 'workerSetup',
            type: cType('WorkerSetup'),
            isRequired: true,
            isNamed: true,
          ),
          ParameterInfo(
            name: 'mapperInitializer',
            type: cType('MapperInitializerFunction'),
            isRequired: true,
            isNamed: true,
          ),
        ],
        mapperParams: const [],
        detectedFrameworkParams: const {'\$resourceIriFactory'},
      );

      final code = generator.generate();

      // Should not include mapperInitializer in signature
      expect(
          code,
          isNot(contains(
              'required MapperInitializerFunction mapperInitializer,')));

      // Should generate the lambda
      expect(code, contains('mapperInitializer: (context) =>'));
      expect(code, contains('initRdfMapper('));
      expect(code, contains('rdfMapper: context.baseRdfMapper,'));
      expect(
          code, contains('\$resourceIriFactory: context.resourceIriFactory,'));

      // Should import init_rdf_mapper.g.dart
      expect(code, contains("import 'init_rdf_mapper.g.dart'"));
    });

    test('propagates custom mapper parameters', () {
      final generator = CodeGenerator(
        hasGeneratedWorker: false,
        hasInitMapper: true,
        hasGeneratedConfig: false,
        locordaParams: [
          ParameterInfo(
            name: 'workerSetup',
            type: cType('WorkerSetup'),
            isRequired: true,
            isNamed: true,
          ),
        ],
        mapperParams: [
          ParameterInfo(
            name: 'categoryService',
            type: cType('CategoryService'),
            isRequired: true,
            isNamed: true,
          ),
        ],
        detectedFrameworkParams: const {},
      );

      final code = generator.generate();

      // Should include custom param in signature
      expect(code, contains('required CategoryService categoryService,'));

      // Should pass it through to initRdfMapper
      expect(code, contains('categoryService: categoryService,'));
    });

    test('generates initLocorda with config detection', () {
      final generator = CodeGenerator(
        hasGeneratedWorker: false,
        hasInitMapper: false,
        hasGeneratedConfig: true,
        locordaParams: [
          ParameterInfo(
            name: 'workerSetup',
            type: cType('WorkerSetup'),
            isRequired: true,
            isNamed: true,
          ),
          ParameterInfo(
            name: 'config',
            type: cType('LocordaConfig'),
            isRequired: true,
            isNamed: true,
          ),
        ],
        mapperParams: const [],
        detectedFrameworkParams: const {},
      );

      final code = generator.generate();

      // Should not include config in signature
      expect(code, isNot(contains('required LocordaConfig config,')));

      // Should include it in the call
      expect(code, contains('generateLocordaConfig(),'));

      // Should import locorda_config.g.dart
      expect(code, contains("import 'locorda_config.g.dart'"));
    });

    test('generates initLocorda with all detections', () {
      final generator = CodeGenerator(
        hasGeneratedWorker: true,
        hasInitMapper: true,
        hasGeneratedConfig: true,
        locordaParams: [
          ParameterInfo(
            name: 'workerSetup',
            type: cType('WorkerSetup'),
            isRequired: true,
            isNamed: true,
          ),
          ParameterInfo(
            name: 'mapperInitializer',
            type: cType('MapperInitializerFunction'),
            isRequired: true,
            isNamed: true,
          ),
          ParameterInfo(
            name: 'config',
            type: cType('LocordaConfig'),
            isRequired: true,
            isNamed: true,
          ),
          ParameterInfo(
            name: 'remotes',
            type: cType('List<RemoteIntegration>'),
            isRequired: true,
            isNamed: true,
          ),
        ],
        mapperParams: const [],
        detectedFrameworkParams: const {},
      );

      final code = generator.generate();

      // Should not include auto-configured params in signature
      expect(code, isNot(contains('required WorkerSetup workerSetup,')));
      expect(
          code,
          isNot(contains(
              'required MapperInitializerFunction mapperInitializer,')));
      expect(code, isNot(contains('required LocordaConfig config,')));

      // Should include remotes (not auto-configured)
      expect(code, contains('required List<RemoteIntegration> remotes'));

      // Should configure all auto params in the call
      expect(code, contains('generatedWorkerSetup,'));
      expect(code, contains('mapperInitializer: (context) =>'));
      expect(code, contains('initRdfMapper('));
      expect(code, contains('generateLocordaConfig(),'));

      // Should have all imports
      expect(code, contains("import 'worker_generated.g.dart'"));
      expect(code, contains("import 'init_rdf_mapper.g.dart'"));
      expect(code, contains("import 'locorda_config.g.dart'"));
    });
  });
}
