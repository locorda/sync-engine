library;

import 'package:locorda_solid/worker.dart';
import 'package:locorda_worker/worker.dart';

final locordaAdapterManifest = [
  RemoteManifestEntry(
    key: 'solid',
    factory: (id) => SolidWorkerHandler(id: id),
  ),
];
