// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'locorda_ui_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class LocordaUILocalizationsEn extends LocordaUILocalizations {
  LocordaUILocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String errorConnecting(String error) {
    return 'Error connecting: $error';
  }

  @override
  String get connected => 'Connected';

  @override
  String get notConnected => 'Not connected';

  @override
  String get syncError => 'Sync error';

  @override
  String get syncing => 'Syncing...';

  @override
  String get upToDate => 'Up to date';

  @override
  String get signOut => 'Sign Out';

  @override
  String get syncNow => 'Sync Now';

  @override
  String get retrySync => 'Retry Sync';

  @override
  String get storageBackends => 'Storage Backends';

  @override
  String get connect => 'Connect';

  @override
  String get disconnect => 'Disconnect';

  @override
  String errorDisconnecting(String error) {
    return 'Error disconnecting: $error';
  }
}
