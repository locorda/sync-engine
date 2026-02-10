library;

import 'package:locorda_drift/worker.dart';
import 'package:locorda_worker/worker.dart';

final locordaAdapterManifest = [
  StorageManifestEntry(
    key: 'drift',
    factory: (id) => DriftWorkerHandler(id: id),
  ),
];
