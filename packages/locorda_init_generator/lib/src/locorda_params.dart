import 'parameter_info.dart';

/// Hardcoded Locorda.create parameters from locorda_flutter package.
/// 
/// This is a pragmatic approach for the initial implementation.
/// Future enhancement: Use analyzer to parse dynamically.
List<ParameterInfo> getLocordaCreateParameters() {
  return const [
    ParameterInfo(
      name: 'workerSetup',
      type: 'WorkerSetup',
      isRequired: true,
      isNamed: true,
    ),
    ParameterInfo(
      name: 'onWorkerSpawn',
      type: 'void Function()?',
      isRequired: false,
      isNamed: true,
    ),
    ParameterInfo(
      name: 'config',
      type: 'LocordaConfig',
      isRequired: true,
      isNamed: true,
    ),
    ParameterInfo(
      name: 'mapperInitializer',
      type: 'MapperInitializerFunction',
      isRequired: true,
      isNamed: true,
    ),
    ParameterInfo(
      name: 'storage',
      type: 'StorageMainHandler',
      isRequired: true,
      isNamed: true,
    ),
    ParameterInfo(
      name: 'jsScript',
      type: 'String',
      isRequired: false,
      isNamed: true,
      defaultValue: "'worker.dart.js'",
    ),
    ParameterInfo(
      name: 'remotes',
      type: 'List<RemoteIntegration>',
      isRequired: false,
      isNamed: true,
      defaultValue: 'const []',
    ),
    ParameterInfo(
      name: 'plugins',
      type: 'List<MainHandlerFactory>',
      isRequired: false,
      isNamed: true,
      defaultValue: 'const []',
    ),
    ParameterInfo(
      name: 'iriTermFactory',
      type: 'IriTermFactory?',
      isRequired: false,
      isNamed: true,
    ),
    ParameterInfo(
      name: 'rdfCore',
      type: 'RdfCore?',
      isRequired: false,
      isNamed: true,
    ),
    ParameterInfo(
      name: 'debugName',
      type: 'String?',
      isRequired: false,
      isNamed: true,
    ),
  ];
}
