library;

import 'package:locorda/worker.dart';
import 'package:locorda_dir/worker.dart';

const dirDatasetPerShardRemoteId = 'personal_notes_app:dir:dataset_sharded';
final locordaAdapterManifest = [
  RemoteManifestEntry(
    key: dirDatasetPerShardRemoteId,
    factory: (id) => DirWorkerHandler(id: id),
  ),
];
