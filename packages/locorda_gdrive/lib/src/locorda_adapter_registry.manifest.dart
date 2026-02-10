library;

import 'package:locorda_gdrive/src/shared/consts.dart';
import 'package:locorda_gdrive/worker.dart';
import 'package:locorda_worker/worker.dart';

final locordaAdapterManifest = [
  RemoteManifestEntry(
    key: gDriveRemoteHandlerId,
    factory: (id) => GDriveWorkerHandler(id: id),
  ),
];
