// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: unused_import, depend_on_referenced_packages, unnecessary_import, implementation_imports

/// Convenience wrapper for Locorda.create with auto-detected settings.
///
/// Auto-configures:
/// - workerSetup: generatedWorkerSetup (from worker_generated.g.dart)
/// - jsScript: 'worker_generated.dart.js'
/// - mapperInitializer: Generated from initRdfMapper
/// - config: Generated from annotations via generateLocordaConfig()

library;

import 'dart:core';
import 'init_rdf_mapper.g.dart' as mpr;
import 'locorda_config.g.dart' as cfg;
import 'package:locorda_flutter/locorda_flutter.dart';
import 'package:locorda_flutter_core/src/integration.dart' as integration;
import 'package:locorda_rdf_core/core.dart' as core;
import 'package:locorda_rdf_core/src/graph/rdf_term.dart' as rdf_term;
import 'package:locorda_worker/src/main/main_handler.dart' as main_handler;
import 'package:locorda_worker/src/main/storage_main_handler.dart' as smh;
import 'worker_generated.g.dart' as wrk;

Future<Locorda> initLocorda({
  void Function()? onWorkerSpawn,
  required smh.StorageMainHandler storage,
  List<integration.RemoteIntegration> remotes = const [],
  List<main_handler.MainHandlerFactory> plugins = const [],
  rdf_term.IriTermFactory? iriTermFactory,
  core.RdfCore? rdfCore,
  String? debugName,
}) async => Locorda.create(
  workerSetup: wrk.generatedWorkerSetup,
  jsScript: 'worker_generated.dart.js',
  mapperInitializer: (context) => mpr.initRdfMapper(
    rdfMapper: context.baseRdfMapper,
    $resourceIriFactory: context.resourceIriFactory,
  ),
  config: cfg.generateLocordaConfig(),
  onWorkerSpawn: onWorkerSpawn,
  storage: storage,
  remotes: remotes,
  plugins: plugins,
  iriTermFactory: iriTermFactory,
  rdfCore: rdfCore,
  debugName: debugName,
);
