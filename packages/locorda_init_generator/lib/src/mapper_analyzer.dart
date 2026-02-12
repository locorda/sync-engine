import 'package:analyzer/dart/element/element.dart';
import 'package:build/build.dart';
import 'package:logging/logging.dart';

import 'parameter_info.dart';
import 'parameter_parser.dart';

final _log = Logger('MapperAnalyzer');

/// Analyzes initRdfMapper signature to extract custom parameters.
class MapperAnalyzer {
  final BuildStep buildStep;
  final String packageName;

  MapperAnalyzer(this.buildStep, this.packageName);

  /// Analyze initRdfMapper function and extract custom parameters.
  Future<MapperAnalysisResult> analyzeInitRdfMapper() async {
    final assetId = AssetId(packageName, 'lib/init_rdf_mapper.g.dart');

    if (!await buildStep.canRead(assetId)) {
      _log.fine('init_rdf_mapper.g.dart not found, returning empty result');
      return const MapperAnalysisResult(
        customParams: [],
        frameworkParams: {},
      );
    }

    try {
      final library = await buildStep.resolver.libraryFor(assetId);
      return _analyzeLibrary(library);
    } catch (e) {
      _log.warning('Failed to parse init_rdf_mapper.g.dart: $e');
      return const MapperAnalysisResult(
        customParams: [],
        frameworkParams: {},
      );
    }
  }

  MapperAnalysisResult _analyzeLibrary(LibraryElement library) {
    final function = library.topLevelFunctions
        .where((element) => element.displayName == 'initRdfMapper')
        .firstOrNull;

    if (function == null) {
      _log.warning(
          'initRdfMapper function not found in init_rdf_mapper.g.dart');
      return const MapperAnalysisResult(
        customParams: [],
        frameworkParams: {},
      );
    }

    final customParams = <ParameterInfo>[];
    final frameworkParams = <String>{};

    final parsedParams = parseParameterElements(function.formalParameters);
    for (final param in parsedParams) {
      if (param.name == 'rdfMapper' || param.name.startsWith(r'$')) {
        if (param.name.startsWith(r'$')) {
          frameworkParams.add(param.name);
        }
        continue;
      }
      customParams.add(param);
    }

    return MapperAnalysisResult(
      customParams: customParams,
      frameworkParams: frameworkParams,
    );
  }
}

extension on Iterable<TopLevelFunctionElement> {
  TopLevelFunctionElement? get firstOrNull => isEmpty ? null : first;
}
