library;

import 'package:locorda_drift/src/shared/consts.dart';
import 'package:locorda_drift/worker.dart';
import 'package:locorda_worker/worker.dart';

final locordaAdapterManifest = [
  StorageManifestEntry(
    key: driftStorageHandlerId,
    factory: (id) => DriftWorkerHandler(id: id),
  ),
];
