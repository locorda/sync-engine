// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: unused_import, depend_on_referenced_packages, unnecessary_import, implementation_imports

/// Generated LocordaConfig from annotations.
///
/// All crdtMapping IRIs are static, app-owned, absolute IRIs
/// fully determined at compile time from annotation values.
library;

import 'dart:core';
import 'package:locorda_objects/locorda_objects.dart';
import 'package:minimal_task_sync/task.dart' as task;

LocordaConfig generateLocordaConfig() => LocordaConfig(
  resources: [
    ResourceConfig(
      type: task.Task,
      crdtMapping: Uri.parse(
        'https://locorda.dev/example/minimal/mappings/task-v1#',
      ),
      indices: [FullIndexConfig()],
    ),
  ],
);
