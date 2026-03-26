library;

import 'package:locorda/worker.dart';
import 'package:locorda_dir/worker.dart';

const dirDatasetPerShardRemoteId = 'personal_notes_app:dir:dataset_sharded';

final storages = <StorageWorkerHandler>[];

final remotes = <RemoteWorkerHandler>[
  if (DirWorkerHandler.isPlatformSupported) ...[
    DirWorkerHandler(id: dirDatasetPerShardRemoteId),
  ],
];
