library;

import 'package:locorda_dir/worker.dart';
import 'package:locorda_worker/worker.dart';

final locordaAdapterManifest = [
  RemoteManifestEntry(
    key: 'local_dir',
    factory: (id) => DirWorkerHandler(id: id),
  ),
];
