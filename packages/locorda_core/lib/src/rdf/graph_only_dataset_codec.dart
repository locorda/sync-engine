import 'package:locorda_rdf_core/core.dart';

class DatasetCodecResolver {
  final RdfCore _rdfCore;
  final bool _wrapGraphCodecs;
  final Map<String, RdfCodec<RdfDataset>> _codecCache = {};

  // Private constructor
  DatasetCodecResolver._(this._rdfCore, this._wrapGraphCodecs);

  /// Creates resolver that only returns native dataset codecs.
  ///
  /// Throws [CodecNotSupportedException] if contentType has no dataset codec.
  factory DatasetCodecResolver(RdfCore rdfCore) {
    return DatasetCodecResolver._(rdfCore, false);
  }

  /// Creates resolver with automatic graph-to-dataset codec wrapping.
  ///
  /// Falls back to [GraphOnlyDatasetCodec] if no native dataset codec exists.
  factory DatasetCodecResolver.withGraphCodecFallback(RdfCore rdfCore) {
    return DatasetCodecResolver._(rdfCore, true);
  }

  RdfCodec<RdfDataset> datasetCodec(String contentType) {
    return _codecCache.putIfAbsent(
      contentType,
      () => _getCodec(contentType),
    );
  }

  RdfCodec<RdfDataset> _getCodec(String contentType) {
    try {
      return _rdfCore.datasetCodec(contentType: contentType);
    } on CodecNotSupportedException {
      if (_wrapGraphCodecs) {
        return GraphOnlyDatasetCodec(_rdfCore.codec(contentType: contentType));
      }
      rethrow;
    }
  }
}

class _GraphOnlyDatasetDecoder extends RdfDecoder<RdfDataset> {
  final RdfDecoder<RdfGraph> _graphDecoder;

  _GraphOnlyDatasetDecoder(this._graphDecoder);

  @override
  RdfDataset convert(String input, {String? documentUrl}) {
    final graph = _graphDecoder.convert(input, documentUrl: documentUrl);
    return RdfDataset.fromDefaultGraph(graph);
  }

  @override
  RdfDecoder<RdfDataset> withOptions(RdfGraphDecoderOptions options) =>
      _GraphOnlyDatasetDecoder(
        _graphDecoder.withOptions(options),
      );
}

class _GraphOnlyDatasetEncoder extends RdfEncoder<RdfDataset> {
  final RdfEncoder<RdfGraph> _graphEncoder;

  _GraphOnlyDatasetEncoder(this._graphEncoder);

  @override
  RdfEncoder<RdfDataset> withOptions(RdfGraphEncoderOptions options) =>
      _GraphOnlyDatasetEncoder(
        _graphEncoder.withOptions(options),
      );

  @override
  String convert(RdfDataset data, {String? baseUri}) {
    if (data.namedGraphs.isNotEmpty) {
      throw ArgumentError(
          'Dataset contains named graphs, cannot encode with GraphOnlyDatasetEncoder.');
    }
    return _graphEncoder.convert(data.defaultGraph, baseUri: baseUri);
  }
}

class GraphOnlyDatasetCodec extends RdfCodec<RdfDataset> {
  final RdfCodec<RdfGraph> _graphCodec;

  GraphOnlyDatasetCodec(this._graphCodec);

  @override
  bool canParse(String content) => _graphCodec.canParse(content);

  @override
  RdfDecoder<RdfDataset> get decoder =>
      _GraphOnlyDatasetDecoder(_graphCodec.decoder);

  @override
  RdfEncoder<RdfDataset> get encoder =>
      _GraphOnlyDatasetEncoder(_graphCodec.encoder);

  @override
  String get primaryMimeType => _graphCodec.primaryMimeType;

  @override
  Set<String> get supportedMimeTypes => _graphCodec.supportedMimeTypes;

  @override
  RdfCodec<RdfDataset> withOptions(
          {RdfGraphEncoderOptions? encoder, RdfGraphDecoderOptions? decoder}) =>
      GraphOnlyDatasetCodec(
        _graphCodec.withOptions(
          encoder: encoder,
          decoder: decoder,
        ),
      );
}
