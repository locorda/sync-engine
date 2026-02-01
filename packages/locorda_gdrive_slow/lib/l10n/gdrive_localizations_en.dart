// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'gdrive_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class GDriveLocalizationsEn extends GDriveLocalizations {
  GDriveLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get connectToGoogleDrive => 'Connect to Google Drive';

  @override
  String get syncAcrossDevices => 'Sync Across Devices';

  @override
  String get signInWithGoogle => 'Sign in with Google';

  @override
  String get connect => 'Connect';

  @override
  String get cancel => 'Cancel';

  @override
  String errorConnectingGoogleDrive(String error) {
    return 'Error connecting to Google Drive: $error';
  }

  @override
  String get noAccount => 'Don\'t have a Google Account?';

  @override
  String get createAccount => 'Create Account';

  @override
  String get dataPrivacyNotice =>
      'Your data will be transferred to and stored on Google servers. The data is stored unencrypted in your Google Drive. We do not have control over what Google does with your data.';
}
