library;

import 'package:locorda_dir/src/shared/consts.dart';
import 'package:locorda_dir/worker.dart';
import 'package:locorda_worker/worker.dart';

final storages = <StorageWorkerHandler>[];

final remotes = <RemoteWorkerHandler>[
  if (DirWorkerHandler.isPlatformSupported) ...[
    DirWorkerHandler(id: directoryRemoteHandlerId),
  ],
];
