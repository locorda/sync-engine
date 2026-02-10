library;

import 'package:locorda_drift/src/shared/consts.dart';
import 'package:locorda_drift/worker.dart';
import 'package:locorda_worker/worker.dart';

final storages = <StorageWorkerHandler>[
  DriftWorkerHandler(id: driftStorageHandlerId),
];

final remotes = <RemoteWorkerHandler>[];
