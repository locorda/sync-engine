import '../gdrive_auth.dart';
import 'gdrive_auth_shared.dart';

/// Web-specific factory implementation for creating [GDriveAuth].
///
/// Always returns [GoogleSignInGDriveAuth] on Web platforms.
Future<GDriveAuth> createGDriveAuth({
  String? clientId,
  String? clientKey,
  required List<String> scopes,
}) async {
  return GoogleSignInGDriveAuth.create(
    clientId: clientId,
    scopes: scopes,
  );
}
