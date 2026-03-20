/// Web platform codec using turtle text format for postMessage compatibility.
library;

import 'package:locorda_rdf_core/core.dart';

import '../shared/worker_graph_codec.dart';

WorkerGraphEncoder get platformEncodeGraph =>
    (RdfGraph graph) => turtle.encode(graph);

WorkerGraphDecoder get platformDecodeGraph =>
    (Object encoded) => turtle.decode(encoded as String);
