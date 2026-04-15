import 'package:locorda_core/locorda_core.dart';

/// Configuration for Solid backend synchronization behavior.
///
/// This config is shared between main and worker isolates and is transferred
/// as JSON during worker initialization.
class SolidConfig {
  /// Storage layout determining how resources are organized on the Solid Pod.
  ///
  /// Defaults to [FilePerResource] (one Turtle file per resource), which aligns
  /// with Solid's linked-data philosophy of distinct IRIs per resource.
  final RemoteStorageLayout layout;

  const SolidConfig({
    this.layout = const FilePerResource(),
  });

  /// Encode config to JSON.
  Map<String, dynamic> toJson() => {
        'layout': layout.toJson(),
      };

  /// Decode config from JSON, defaulting to [FilePerResource] if missing.
  factory SolidConfig.fromJson(Map<String, dynamic> json) {
    final layoutJson = json['layout'] as Map<String, dynamic>? ??
        const {'type': 'filePerResource'};
    return SolidConfig(
      layout: RemoteStorageLayout.fromJson(layoutJson),
    );
  }

  SolidConfig copyWith({RemoteStorageLayout? layout}) {
    return SolidConfig(
      layout: layout ?? this.layout,
    );
  }

  @override
  String toString() => 'SolidConfig(layout: $layout)';
}
