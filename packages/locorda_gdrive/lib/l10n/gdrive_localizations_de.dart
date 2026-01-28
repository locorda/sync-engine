// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'gdrive_localizations.dart';

// ignore_for_file: type=lint

/// The translations for German (`de`).
class GDriveLocalizationsDe extends GDriveLocalizations {
  GDriveLocalizationsDe([String locale = 'de']) : super(locale);

  @override
  String get connectToGoogleDrive => 'Mit Google Drive verbinden';

  @override
  String get syncAcrossDevices => 'Geräteübergreifend synchronisieren';

  @override
  String get signInWithGoogle => 'Mit Google anmelden';

  @override
  String get connect => 'Verbinden';

  @override
  String get cancel => 'Abbrechen';

  @override
  String errorConnectingGoogleDrive(String error) {
    return 'Fehler beim Verbinden mit Google Drive: $error';
  }

  @override
  String get noAccount => 'Noch kein Google-Konto?';

  @override
  String get createAccount => 'Konto erstellen';
}
