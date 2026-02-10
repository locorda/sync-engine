import 'package:build/build.dart';

/// Triggers all Locorda builders through `applies_builders`.
///
/// This builder intentionally writes a tiny cache artifact so it can run on
/// any dependent package without touching source files.
class LocordaDevBuilder implements Builder {
  @override
  Map<String, List<String>> get buildExtensions => const {
        'pubspec.yaml': ['.locorda_dev'],
      };

  @override
  Future<void> build(BuildStep buildStep) async {
    final outputId = AssetId(buildStep.inputId.package, '.locorda_dev');
    await buildStep.writeAsString(outputId, 'locorda_dev');
  }
}

/// Builder factory for build_runner integration.
Builder locordaDevBuilder(BuilderOptions options) => LocordaDevBuilder();
