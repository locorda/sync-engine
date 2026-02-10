library;

import 'package:locorda_worker/src/shared/consts.dart';
import 'package:locorda_worker/worker.dart';

final locordaAdapterManifest = [
  StorageManifestEntry(
    key: inMemoryStorageHandlerId,
    factory: (id) => InMemoryStorageWorkerHandler(id: id),
  ),
];
