import 'package:locorda_init_generator/src/code_generator.dart';
import 'package:locorda_init_generator/src/parameter_info.dart';
import 'package:test/test.dart';

void main() {
  group('CodeGenerator', () {
    test('generates basic initLocorda with no detection', () {
      final generator = CodeGenerator(
        hasGeneratedWorker: false,
        hasInitMapper: false,
        locordaParams: const [
          ParameterInfo(
            name: 'workerSetup',
            type: 'WorkerSetup',
            isRequired: true,
            isNamed: true,
          ),
          ParameterInfo(
            name: 'config',
            type: 'LocordaConfig',
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
        locordaParams: const [
          ParameterInfo(
            name: 'workerSetup',
            type: 'WorkerSetup',
            isRequired: true,
            isNamed: true,
          ),
          ParameterInfo(
            name: 'config',
            type: 'LocordaConfig',
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
      expect(code, contains('workerSetup: generatedWorkerSetup,'));
      expect(code, contains("jsScript: 'worker_generated.dart.js',"));
      
      // Should import worker_generated.g.dart
      expect(code, contains("import 'worker_generated.g.dart'"));
    });

    test('generates initLocorda with mapper detection', () {
      final generator = CodeGenerator(
        hasGeneratedWorker: false,
        hasInitMapper: true,
        locordaParams: const [
          ParameterInfo(
            name: 'workerSetup',
            type: 'WorkerSetup',
            isRequired: true,
            isNamed: true,
          ),
          ParameterInfo(
            name: 'mapperInitializer',
            type: 'MapperInitializerFunction',
            isRequired: true,
            isNamed: true,
          ),
        ],
        mapperParams: const [],
        detectedFrameworkParams: const {'\$resourceIriFactory'},
      );

      final code = generator.generate();

      // Should not include mapperInitializer in signature
      expect(code, isNot(contains('required MapperInitializerFunction mapperInitializer,')));
      
      // Should generate the lambda
      expect(code, contains('mapperInitializer: (context) => initRdfMapper('));
      expect(code, contains('rdfMapper: context.baseRdfMapper,'));
      expect(code, contains('\$resourceIriFactory: context.resourceIriFactory,'));
      
      // Should import init_rdf_mapper.g.dart
      expect(code, contains("import 'init_rdf_mapper.g.dart'"));
    });

    test('propagates custom mapper parameters', () {
      final generator = CodeGenerator(
        hasGeneratedWorker: false,
        hasInitMapper: true,
        locordaParams: const [
          ParameterInfo(
            name: 'workerSetup',
            type: 'WorkerSetup',
            isRequired: true,
            isNamed: true,
          ),
        ],
        mapperParams: const [
          ParameterInfo(
            name: 'categoryService',
            type: 'CategoryService',
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
  });
}
