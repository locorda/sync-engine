import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'locorda_ui_localizations_de.dart';
import 'locorda_ui_localizations_en.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of LocordaUILocalizations
/// returned by `LocordaUILocalizations.of(context)`.
///
/// Applications need to include `LocordaUILocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/locorda_ui_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: LocordaUILocalizations.localizationsDelegates,
///   supportedLocales: LocordaUILocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the LocordaUILocalizations.supportedLocales
/// property.
abstract class LocordaUILocalizations {
  LocordaUILocalizations(String locale)
      : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static LocordaUILocalizations? of(BuildContext context) {
    return Localizations.of<LocordaUILocalizations>(
        context, LocordaUILocalizations);
  }

  static const LocalizationsDelegate<LocordaUILocalizations> delegate =
      _LocordaUILocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('de'),
    Locale('en')
  ];

  /// Error message when connection fails
  ///
  /// In en, this message translates to:
  /// **'Error connecting: {error}'**
  String errorConnecting(String error);

  /// Status message when connected
  ///
  /// In en, this message translates to:
  /// **'Connected'**
  String get connected;

  /// Status message when not connected
  ///
  /// In en, this message translates to:
  /// **'Not connected'**
  String get notConnected;

  /// Generic sync error message
  ///
  /// In en, this message translates to:
  /// **'Sync error'**
  String get syncError;

  /// Status message when syncing
  ///
  /// In en, this message translates to:
  /// **'Syncing...'**
  String get syncing;

  /// Status message when sync is complete
  ///
  /// In en, this message translates to:
  /// **'Up to date'**
  String get upToDate;

  /// Button text to sign out
  ///
  /// In en, this message translates to:
  /// **'Sign Out'**
  String get signOut;

  /// Button text to trigger manual sync
  ///
  /// In en, this message translates to:
  /// **'Sync Now'**
  String get syncNow;

  /// Button text to retry failed sync
  ///
  /// In en, this message translates to:
  /// **'Retry Sync'**
  String get retrySync;

  /// Title for storage backend selection
  ///
  /// In en, this message translates to:
  /// **'Storage Backends'**
  String get storageBackends;

  /// Button text to connect to a backend
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get connect;

  /// Button text to disconnect from a backend
  ///
  /// In en, this message translates to:
  /// **'Disconnect'**
  String get disconnect;

  /// Error message when disconnection fails
  ///
  /// In en, this message translates to:
  /// **'Error disconnecting: {error}'**
  String errorDisconnecting(String error);
}

class _LocordaUILocalizationsDelegate
    extends LocalizationsDelegate<LocordaUILocalizations> {
  const _LocordaUILocalizationsDelegate();

  @override
  Future<LocordaUILocalizations> load(Locale locale) {
    return SynchronousFuture<LocordaUILocalizations>(
        lookupLocordaUILocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['de', 'en'].contains(locale.languageCode);

  @override
  bool shouldReload(_LocordaUILocalizationsDelegate old) => false;
}

LocordaUILocalizations lookupLocordaUILocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'de':
      return LocordaUILocalizationsDe();
    case 'en':
      return LocordaUILocalizationsEn();
  }

  throw FlutterError(
      'LocordaUILocalizations.delegate failed to load unsupported locale "$locale". This is likely '
      'an issue with the localizations generation tool. Please file an issue '
      'on GitHub with a reproducible sample app and the gen-l10n configuration '
      'that was used.');
}
