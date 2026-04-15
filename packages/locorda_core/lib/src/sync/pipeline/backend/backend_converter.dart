import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';
import 'package:locorda_rdf_core/core.dart';

class BackendDatasetConverter {
  final RdfCore _rdfCore;
  final bool _isBinary;
  final String _contentType;

  BackendDatasetConverter(
      {required RdfCore rdfCore,
      required bool isBinary,
      required String contentType})
      : _rdfCore = rdfCore,
        _isBinary = isBinary,
        _contentType = contentType;

  /// Decode [RawContent] from backend into an [RdfDataset].
  RdfDataset decodeDataset(RawContent raw) => switch (raw) {
        TextContent(:final text, :final contentType) =>
          _rdfCore.decodeDataset(text, contentType: contentType),
        BinaryContent(:final bytes, :final contentType) =>
          _rdfCore.decodeBinaryDataset(bytes, contentType: contentType),
      };

  /// Encode an [RdfDataset] to [RawContent] for the backend.
  RawContent encodeDataset(RdfDataset dataset) {
    if (_isBinary) {
      final encodedBytes =
          _rdfCore.encodeBinaryDataset(dataset, contentType: _contentType);
      return BinaryContent(encodedBytes, contentType: _contentType);
    }

    final encoded = _rdfCore.encodeDataset(dataset, contentType: _contentType);
    return TextContent(encoded, contentType: _contentType);
  }
}

class BackendGraphConverter {
  final RdfCore _rdfCore;
  final bool _isBinary;
  final String _contentType;

  BackendGraphConverter({
    required RdfCore rdfCore,
    required bool isBinary,
    required String contentType,
  })  : _rdfCore = rdfCore,
        _isBinary = isBinary,
        _contentType = contentType;

  /// Convert [RawContent] from backend to pipeline [RdfGraphSource].
  RdfGraphSource toGraphSource(RawContent raw) => switch (raw) {
        TextContent(:final text, :final contentType) =>
          TextGraphSource(text, contentType: contentType),
        BinaryContent(:final bytes, :final contentType) =>
          BinaryGraphSource(bytes, contentType: contentType),
      };

  /// Encode a [DecodedGraphSource] to [RawContent] for the backend.
  RawContent encodeGraph(DecodedGraphSource source) {
    // If already encoded in the target content type, reuse raw bytes.
    final orig = source.originalSource;
    if (orig != null && orig.contentType == _contentType) {
      return switch (orig) {
        TextGraphSource(:final text, :final contentType) =>
          TextContent(text, contentType: contentType),
        BinaryGraphSource(:final bytes, :final contentType) =>
          BinaryContent(bytes, contentType: contentType),
      };
    }
    // Encode graph to target content type.
    if (_isBinary) {
      final encodedBytes =
          _rdfCore.encodeBinary(source.graph, contentType: _contentType);
      return BinaryContent(encodedBytes, contentType: _contentType);
    }

    final encoded = _rdfCore.encode(source.graph, contentType: _contentType);
    return TextContent(encoded, contentType: _contentType);
  }
}
