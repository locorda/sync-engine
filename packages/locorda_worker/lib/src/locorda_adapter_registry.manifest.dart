library;

import 'package:locorda_worker/worker.dart';

final locordaAdapterManifest = [
  StorageManifestEntry(
    key: 'in_memory',
    factory: (id) => InMemoryStorageWorkerHandler(id: id),
  ),
];
