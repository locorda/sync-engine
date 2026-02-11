// This file shows an example of what init_locorda.g.dart would look like
// for personal_notes_app, which has both worker_generated.g.dart and 
// init_rdf_mapper.g.dart with no custom parameters.

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: unused_import, depend_on_referenced_packages

import 'package:locorda_flutter/locorda_flutter.dart';
import 'worker_generated.g.dart' show generatedWorkerSetup;
import 'init_rdf_mapper.g.dart' show initRdfMapper;

/// Convenience wrapper for Locorda.create with auto-detected settings.
///
/// Auto-configures:
/// - workerSetup: generatedWorkerSetup (from worker_generated.g.dart)
/// - jsScript: 'worker_generated.dart.js'
/// - mapperInitializer: Generated from initRdfMapper
Future<Locorda> initLocorda({
  required LocordaConfig config,
  required StorageMainHandler storage,
  void Function()? onWorkerSpawn,
  List<RemoteIntegration> remotes = const [],
  List<MainHandlerFactory> plugins = const [],
  IriTermFactory? iriTermFactory,
  RdfCore? rdfCore,
  String? debugName,
}) async {
  return Locorda.create(
    workerSetup: generatedWorkerSetup,
    jsScript: 'worker_generated.dart.js',
    mapperInitializer: (context) => initRdfMapper(
      rdfMapper: context.baseRdfMapper,
      $indexItemIriFactory: context.indexItemIriFactory,
      $resourceIriFactory: context.resourceIriFactory,
      $resourceRefFactory: context.resourceRefFactory,
    ),
    config: config,
    storage: storage,
    onWorkerSpawn: onWorkerSpawn,
    remotes: remotes,
    plugins: plugins,
    iriTermFactory: iriTermFactory,
    rdfCore: rdfCore,
    debugName: debugName,
  );
}
