library;

import 'package:locorda_solid/src/solid/shared/consts.dart';
import 'package:locorda_solid/worker.dart';
import 'package:locorda_worker/worker.dart';

final locordaAdapterManifest = [
  RemoteManifestEntry(
    key: solidRemoteHandlerId,
    factory: (id) => SolidWorkerHandler(id: id),
  ),
];
