/// Builder that generates lib/locorda_config.g.dart
library;

import 'dart:async';
import 'package:build/build.dart';
import 'package:glob/glob.dart';
import 'package:logging/logging.dart';

import 'annotation_scanner.dart';
import 'config_code_generator.dart';
import 'annotation_data.dart';

final _log = Logger('ConfigBuilder');

/// Builder that generates lib/locorda_config.g.dart
///
/// Scans all .dart files in the consumer package's lib/ directory for
/// @RootResource, @GroupKey, and @IndexItem annotations,
/// then generates a LocordaConfig factory function.
class ConfigBuilder implements Builder {
  final BuilderOptions options;

  ConfigBuilder(this.options);

  @override
  Map<String, List<String>> get buildExtensions => {
        'pubspec.yaml': ['lib/locorda_config.g.dart'],
      };

  @override
  Future<void> build(BuildStep buildStep) async {
    _log.fine('Starting config generation for ${buildStep.inputId.package}');

    // 1. Find all .dart files in lib/
    final dartFiles = await buildStep
        .findAssets(Glob('lib/**.dart'))
        .where((id) => !id.path.endsWith('.g.dart'))
        .toList();

    _log.fine('Found ${dartFiles.length} Dart files to scan');

    // 2. Aggregate scan results
    final allRootResources = <RootResourceData>[];
    final allGroupKeys = <GroupKeyData>[];
    final allIndexItems = <IndexItemData>[];

    for (final assetId in dartFiles) {
      try {
        // Resolve library for annotation analysis
        final library = await buildStep.resolver.libraryFor(assetId);

        // Determine import URI
        final importUri = assetId.uri.toString();

        // Scan the library
        final scanner = AnnotationScanner();
        final result = scanner.scanLibrary(library, importUri);

        allRootResources.addAll(result.rootResources);
        allGroupKeys.addAll(result.groupKeys);
        allIndexItems.addAll(result.indexItems);
      } catch (e, stackTrace) {
        _log.warning('Error scanning $assetId: $e', e, stackTrace);
      }
    }

    _log.fine(
      'Scanned: ${allRootResources.length} root resources, ${allGroupKeys.length} group keys, ${allIndexItems.length} index items',
    );

    // 3. Generate config code
    final generator = ConfigCodeGenerator(
      rootResources: allRootResources,
      groupKeys: allGroupKeys,
      indexItems: allIndexItems,
    );

    final output = generator.generate();

    // 4. Write output
    final outputId = AssetId(
      buildStep.inputId.package,
      'lib/locorda_config.g.dart',
    );
    await buildStep.writeAsString(outputId, output);

    _log.fine('Generated locorda_config.g.dart');
  }
}

Builder configBuilder(BuilderOptions options) => ConfigBuilder(options);
