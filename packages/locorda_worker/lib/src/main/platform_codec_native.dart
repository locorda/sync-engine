/// Native platform codec using jelly binary format for performance.
library;

import 'dart:typed_data';

import 'package:locorda_rdf_core/core.dart';
import 'package:locorda_rdf_jelly/jelly.dart';

import '../shared/worker_graph_codec.dart';

WorkerGraphEncoder get platformEncodeGraph =>
    (RdfGraph graph) => jellyGraph.encode(graph);

WorkerGraphDecoder get platformDecodeGraph =>
    (Object encoded) => jellyGraph.decode(encoded as Uint8List);
