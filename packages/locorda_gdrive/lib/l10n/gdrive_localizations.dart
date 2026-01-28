import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'gdrive_localizations_de.dart';
import 'gdrive_localizations_en.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of GDriveLocalizations
/// returned by `GDriveLocalizations.of(context)`.
///
/// Applications need to include `GDriveLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/gdrive_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: GDriveLocalizations.localizationsDelegates,
///   supportedLocales: GDriveLocalizations.supportedLocales,
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
/// be consistent with the languages listed in the GDriveLocalizations.supportedLocales
/// property.
abstract class GDriveLocalizations {
  GDriveLocalizations(String locale)
      : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static GDriveLocalizations? of(BuildContext context) {
    return Localizations.of<GDriveLocalizations>(context, GDriveLocalizations);
  }

  static const LocalizationsDelegate<GDriveLocalizations> delegate =
      _GDriveLocalizationsDelegate();

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

  /// Title for the Google Drive login screen
  ///
  /// In en, this message translates to:
  /// **'Connect to Google Drive'**
  String get connectToGoogleDrive;

  /// Subtitle explaining the purpose
  ///
  /// In en, this message translates to:
  /// **'Sync Across Devices'**
  String get syncAcrossDevices;

  /// Button text to sign in
  ///
  /// In en, this message translates to:
  /// **'Sign in with Google'**
  String get signInWithGoogle;

  /// Button text to initiate connection
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get connect;

  /// Button text to cancel
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// Error message when connection fails
  ///
  /// In en, this message translates to:
  /// **'Error connecting to Google Drive: {error}'**
  String errorConnectingGoogleDrive(String error);

  /// Text asking if user doesn't have account
  ///
  /// In en, this message translates to:
  /// **'Don\'t have a Google Account?'**
  String get noAccount;

  /// Button text to create account
  ///
  /// In en, this message translates to:
  /// **'Create Account'**
  String get createAccount;
}

class _GDriveLocalizationsDelegate
    extends LocalizationsDelegate<GDriveLocalizations> {
  const _GDriveLocalizationsDelegate();

  @override
  Future<GDriveLocalizations> load(Locale locale) {
    return SynchronousFuture<GDriveLocalizations>(
        lookupGDriveLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['de', 'en'].contains(locale.languageCode);

  @override
  bool shouldReload(_GDriveLocalizationsDelegate old) => false;
}

GDriveLocalizations lookupGDriveLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'de':
      return GDriveLocalizationsDe();
    case 'en':
      return GDriveLocalizationsEn();
  }

  throw FlutterError(
      'GDriveLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
      'an issue with the localizations generation tool. Please file an issue '
      'on GitHub with a reproducible sample app and the gen-l10n configuration '
      'that was used.');
}
