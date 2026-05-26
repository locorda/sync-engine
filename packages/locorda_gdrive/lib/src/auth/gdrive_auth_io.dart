import 'dart:io';

import '../gdrive_auth.dart';
import 'desktop_gdrive_auth.dart';
import 'gdrive_auth_shared.dart';

/// IO-specific factory implementation for creating [GDriveAuth].
///
/// On Windows and Linux, returns [DesktopGDriveAuth] (loopback OAuth2 flow).
/// On other native platforms (Android, iOS, macOS), returns [GoogleSignInGDriveAuth].
///
/// **Tree-shaking note**: Dart's conditional imports only support `dart.library.*`
/// conditions, so the Windows/Linux split cannot be done at compile time via imports.
/// By default both auth backends are included and the choice is made at runtime via
/// [Platform.isWindows]/[Platform.isLinux], which prevents dead-code elimination.
///
/// **Opt-in tree shaking**: pass `--dart-define=LOCORDA_GDRIVE_LOOPBACK_AUTH=true`
/// (loopback only, tree-shakes Google Sign-In) or `=false` (Google Sign-In only,
/// tree-shakes loopback) at build time. When the flag is not set the runtime
/// detection is used and both backends are retained (safe default).

// Compile-time opt-in for tree shaking. See doc comment above.
const bool _loopbackAuthDefined =
    bool.hasEnvironment('LOCORDA_GDRIVE_LOOPBACK_AUTH');
const bool _loopbackAuthValue =
    bool.fromEnvironment('LOCORDA_GDRIVE_LOOPBACK_AUTH');

Future<GDriveAuth> createGDriveAuth({
  String? clientId,
  String? clientKey,
  required List<String> scopes,
}) async {
  if (_loopbackAuthValue ||
      (!_loopbackAuthDefined && (Platform.isWindows || Platform.isLinux))) {
    return DesktopGDriveAuth.create(
      clientId: clientId,
      clientKey: clientKey,
      scopes: scopes,
    );
  } else {
    return GoogleSignInGDriveAuth.create(
      clientId: clientId,
      scopes: scopes,
    );
  }
}
