library;

import 'package:locorda_gdrive/worker.dart';
import 'package:locorda_worker/worker.dart';

final locordaAdapterManifest = [
  RemoteManifestEntry(
    key: 'gdrive',
    factory: (id) => GDriveWorkerHandler(id: id),
  ),
];
