library;

import 'package:locorda_gdrive/src/shared/consts.dart';
import 'package:locorda_gdrive/worker.dart';
import 'package:locorda_worker/worker.dart';

final storages = <StorageWorkerHandler>[];

final remotes = <RemoteWorkerHandler>[
  GDriveWorkerHandler(id: gDriveRemoteHandlerId),
];
