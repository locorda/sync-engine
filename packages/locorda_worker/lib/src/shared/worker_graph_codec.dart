/// Codec typedefs for encoding/decoding RdfGraph for worker transport.
///
/// On native platforms, this can use a binary codec (jelly) for performance.
/// On web, this should use a text codec (turtle) since web workers use JSON.
library;

import 'package:locorda_rdf_core/core.dart';

/// Encodes an [RdfGraph] into a transport-friendly format (String or Uint8List).
typedef WorkerGraphEncoder = Object Function(RdfGraph graph);

/// Decodes an encoded graph back into an [RdfGraph].
typedef WorkerGraphDecoder = RdfGraph Function(Object encoded);
