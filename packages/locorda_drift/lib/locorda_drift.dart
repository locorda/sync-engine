/// Drift (SQLite) storage implementation for locorda.
///
/// This library provides a concrete implementation of the storage interfaces
/// from locorda_core using Drift for cross-platform SQLite support.
///
/// Supports all Flutter platforms: iOS, Android, Web, Windows, macOS, Linux.
library locorda_drift;

export 'src/drift_options.dart'
    show LocordaDriftNativeOptions, LocordaDriftWebOptions;
export 'src/drift_storage.dart' show DriftStorage;
export 'src/main/drift_main_handler.dart' show DriftMainHandler;
