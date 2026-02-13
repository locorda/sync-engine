import 'package:build/build.dart';
import 'package:glob/glob.dart';

Builder mappingBootstrapBuilder(BuilderOptions options) =>
    MappingBootstrapBuilder(mappingRoots: _parseMappingRoots(options));

class MappingBootstrapBuilder implements Builder {
  static const _outputPath = 'lib/src/generated/mapping_bootstrap.g.dart';
  static const _defaultMappingRoots = ['assets/contracts/mappings'];

  final List<Glob> _mappingRootGlobs;

  MappingBootstrapBuilder({List<String>? mappingRoots})
      : _mappingRootGlobs =
            _buildAssetGlobs(mappingRoots ?? _defaultMappingRoots);

  @override
  Map<String, List<String>> get buildExtensions => const {
        'pubspec.yaml': [_outputPath],
      };

  @override
  Future<void> build(BuildStep buildStep) async {
    final generatedCacheAssets = <AssetId>{
      ...await _findAssets(buildStep, Glob('lib/**.crdt.cache.trig')),
      ...await _findAssets(buildStep, Glob('lib/**/*.crdt.cache.trig')),
    };
    final configuredAssets = await _findConfiguredAssets(buildStep);
    final allAssets = <AssetId>{...generatedCacheAssets, ...configuredAssets}
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    final contents = <String>[];
    for (final asset in allAssets) {
      contents.add(await buildStep.readAsString(asset));
    }

    final outputId = AssetId(buildStep.inputId.package, _outputPath);
    await buildStep.writeAsString(outputId, _renderOutput(contents));
  }

  Future<Set<AssetId>> _findConfiguredAssets(BuildStep buildStep) async {
    final assets = <AssetId>{};
    for (final glob in _mappingRootGlobs) {
      assets.addAll(await _findAssets(buildStep, glob));
    }
    return assets;
  }

  Future<Set<AssetId>> _findAssets(BuildStep buildStep, Glob glob) async {
    final assets = <AssetId>{};
    await for (final asset in buildStep.findAssets(glob)) {
      assets.add(asset);
    }
    return assets;
  }

  String _renderOutput(List<String> contents) {
    final buffer = StringBuffer();
    buffer.writeln('// GENERATED CODE - DO NOT MODIFY BY HAND');
    buffer.writeln('// ignore_for_file: prefer_single_quotes');
    buffer.writeln();
    buffer.writeln('const List<String> bootstrapMappings = [');

    for (final content in contents) {
      buffer.writeln(_toRawMultilineLiteral(content));
    }

    buffer.writeln('];');
    return buffer.toString();
  }

  String _toRawMultilineLiteral(String content) {
    final normalized = content.replaceAll('\r\n', '\n').trim();
    if (normalized.contains('"""')) {
      final escaped = normalized
          .replaceAll(r'\', r'\\')
          .replaceAll("'", r"\'")
          .replaceAll('\n', r'\n');
      return "  '$escaped',";
    }

    final buffer = StringBuffer();
    buffer.writeln('  r"""');
    buffer.writeln(normalized);
    buffer.writeln('""",');
    return buffer.toString();
  }

  static List<Glob> _buildAssetGlobs(List<String> roots) {
    final globs = <Glob>[];
    for (final root in roots) {
      final normalized = root.replaceAll(RegExp(r'/+$'), '');
      if (_looksLikePattern(normalized)) {
        globs.add(Glob(normalized));
        continue;
      }
      globs
        ..add(Glob('$normalized/**.ttl'))
        ..add(Glob('$normalized/**/*.ttl'))
        ..add(Glob('$normalized/**.trig'))
        ..add(Glob('$normalized/**/*.trig'))
        ..add(Glob('$normalized/**.jsonld'))
        ..add(Glob('$normalized/**/*.jsonld'));
    }
    return globs;
  }

  static bool _looksLikePattern(String value) {
    return value.contains('*') || value.contains('?');
  }
}

List<String>? _parseMappingRoots(BuilderOptions options) {
  final roots = options.config['mapping_roots'];
  if (roots is! List) {
    return null;
  }

  final parsed = roots.whereType<String>().toList();
  return parsed.isEmpty ? null : parsed;
}
