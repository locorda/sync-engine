// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: unused_import, depend_on_referenced_packages

import 'package:locorda_flutter/locorda_flutter.dart';
import 'worker_generated.g.dart' show generatedWorkerSetup;
import 'init_rdf_mapper.g.dart' show initRdfMapper;
import 'dart:async';
import 'package:locorda_core/locorda_core.dart' as locorda_core;
import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_flutter_core/locorda_flutter_core.dart';
import 'package:locorda_objects/locorda_objects.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:locorda_rdf_mapper/mapper.dart';
import 'package:locorda_ui/locorda_ui.dart';
import 'package:locorda_worker/worker_main.dart';
import 'package:minimal_task_sync/task.dart' as task;
import 'package:minimal_task_sync/task.rdf_mapper.g.dart' as trmg;

/// Convenience wrapper for Locorda.create with auto-detected settings.
///
/// Auto-configures:
/// - workerSetup: generatedWorkerSetup (from worker_generated.g.dart)
/// - jsScript: 'worker_generated.dart.js'
/// - mapperInitializer: Generated from initRdfMapper
Future<Locorda> initLocorda({
  void Function()? onWorkerSpawn,
  required LocordaConfig config,
  required StorageMainHandler storage,
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
      $resourceIriFactory: context.resourceIriFactory,
    ),
    onWorkerSpawn: onWorkerSpawn,
    config: config,
    storage: storage,
    remotes: remotes,
    plugins: plugins,
    iriTermFactory: iriTermFactory,
    rdfCore: rdfCore,
    debugName: debugName,
  );
}
