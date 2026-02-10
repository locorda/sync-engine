import 'dart:convert';

import 'package:build/build.dart';
import 'package:glob/glob.dart';

Builder mappingBootstrapBuilder(BuilderOptions options) =>
    MappingBootstrapBuilder(mappingRoots: _parseMappingRoots(options));

class MappingBootstrapBuilder implements Builder {
  static const _outputPath = 'lib/src/generated/mapping_bootstrap.g.dart';
  static const _defaultMappingRoots = [
    'assets/contracts/mappings',
  ];

  final List<Glob> _mappingGlobs;

  MappingBootstrapBuilder({List<String>? mappingRoots})
      : _mappingGlobs = _buildGlobs(mappingRoots ?? _defaultMappingRoots);

  @override
  Map<String, List<String>> get buildExtensions => const {
        'pubspec.yaml': [_outputPath],
      };

  @override
  Future<void> build(BuildStep buildStep) async {
    final mappingAssets = <AssetId>{};
    for (final glob in _mappingGlobs) {
      await for (final asset in buildStep.findAssets(glob)) {
        mappingAssets.add(asset);
      }
    }
    final contents = <String>[];
    final sortedAssets = mappingAssets.toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final asset in sortedAssets) {
      final content = await buildStep.readAsString(asset);
      contents.add(content);
    }

    final output = _renderOutput(contents);
    final outputId = AssetId(buildStep.inputId.package, _outputPath);
    await buildStep.writeAsString(outputId, output);
  }

  String _renderOutput(List<String> contents) {
    final buffer = StringBuffer();
    buffer.writeln('// GENERATED CODE - DO NOT MODIFY BY HAND');
    buffer.writeln('// ignore_for_file: prefer_single_quotes');
    buffer.writeln();
    buffer.writeln('const List<String> bootstrapMappings = [');

    for (final content in contents) {
      buffer.writeln('  ${jsonEncode(content)},');
    }
    buffer.writeln('];');
    return buffer.toString();
  }

  static List<Glob> _buildGlobs(List<String> roots) {
    return roots.map((root) {
      final normalized = root.replaceAll(RegExp(r'/+$'), '');
      final pattern =
          _looksLikePattern(normalized) ? normalized : '$normalized/**.ttl';
      return Glob(pattern);
    }).toList();
  }

  static bool _looksLikePattern(String value) {
    return value.contains('*') || value.contains('?') || value.endsWith('.ttl');
  }
}

List<String>? _parseMappingRoots(BuilderOptions options) {
  final roots = options.config['mapping_roots'];
  if (roots is List) {
    final parsed = roots.whereType<String>().toList();
    return parsed.isEmpty ? null : parsed;
  }
  return null;
}
