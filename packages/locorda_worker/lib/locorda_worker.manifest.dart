library;

import 'package:locorda_worker/src/shared/consts.dart';
import 'package:locorda_worker/worker.dart';

final storages = <StorageWorkerHandler>[
  InMemoryStorageWorkerHandler(id: inMemoryStorageHandlerId),
];

final remotes = <RemoteWorkerHandler>[];
